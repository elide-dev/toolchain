# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Supply disposable guests for release tags, or explicitly selected qualification runs."""
import argparse
import json
import fcntl
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]
PLATFORMS = ('linux-amd64', 'linux-arm64', 'darwin-arm64')
RELEASE_TAG = re.compile(r'v[0-9]{4}\.[1-9][0-9]?\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?')
NATIVE_WORKFLOWS = ('job.build.yml', 'job.action-e2e.yml')


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True, timeout=45))


def pages(path, key):
    result = []
    for page in range(1, 1000):
        items = api(f'{path}&per_page=100&page={page}')[key]
        result.extend(items)
        if len(items) < 100:
            return result
    raise RuntimeError('Actions pagination limit reached')


def discover(config):
    """Only discover tag-push releases; manual qualification remains explicitly selected."""
    result = {}
    for status in ('queued', 'in_progress', 'waiting', 'pending', 'requested'):
        for info in pages(f'repos/{config["repository"]}/actions/workflows/on.release.yml/runs'
                          f'?event=push&status={status}', 'workflow_runs'):
            result[info['id']] = info
    return list(result.values())


def authorize(config, info):
    """Verify a real tag at the run's commit, integrated into the trusted branch."""
    repo = config['repository']
    if info.get('repository', {}).get('full_name') != repo:
        raise ValueError('Run belongs to another repository')
    if (info['event'] == 'workflow_dispatch' and
            info['path'] == '.github/workflows/release-runner-qualification.yml' and
            info['head_branch'] == config['trusted_branch']):
        return set()
    tag = info['head_branch']
    if (info['event'] != 'push' or info['path'] != '.github/workflows/on.release.yml'
            or not RELEASE_TAG.fullmatch(tag)):
        raise ValueError(f'Run {info["id"]} is not an approved release or qualification run')
    # The refs endpoint rejects a branch whose name happens to resemble a release tag.
    api(f'repos/{repo}/git/ref/tags/{quote(tag, safe="")}')
    commit = api(f'repos/{repo}/commits/{quote("refs/tags/" + tag, safe="")}')['sha']
    if commit != info['head_sha']:
        raise ValueError(f'Tag {tag} no longer matches the release commit')
    comparison = api(f'repos/{repo}/compare/{quote(config["trusted_branch"], safe="")}...{commit}')
    if comparison['status'] not in ('identical', 'behind'):
        raise ValueError(f'Tag {tag} is not integrated into {config["trusted_branch"]}')
    refs = set()
    for workflow in NATIVE_WORKFLOWS:
        path = f'{repo}/.github/workflows/{workflow}'
        if not any(item['path'] == f'{path}@{commit}' and item['sha'] == commit
                   and item.get('ref') == f'refs/tags/{tag}'
                   for item in info.get('referenced_workflows', [])):
            raise ValueError(f'Run does not use {workflow} from the release tag')
        refs.add(f'{path}@refs/tags/{tag}')
    return refs


def reconcile_access(config, refs, prune=False):
    """Keep repository/workflow restrictions and add only verified exact release refs."""
    path = f'orgs/{config["organization"]}/actions/runner-groups/{config["runner_group_id"]}'
    group = api(path)
    if group['visibility'] != 'selected' or not group['restricted_to_workflows']:
        raise ValueError('Release group must restrict both repositories and workflows')
    repositories = pages(path + '/repositories?', 'repositories')
    if {repo['full_name'] for repo in repositories} != {config['repository']}:
        raise ValueError('Release group must be exclusive to the toolchain repository')
    existing = set(group['selected_workflows'])
    retained = existing
    if prune:
        # Discovery covers every active release. Retire completed tag grants rather
        # than growing the GitHub allowlist indefinitely; preserve non-release refs.
        prefixes = tuple(f'{config["repository"]}/.github/workflows/{workflow}@refs/tags/'
                         for workflow in NATIVE_WORKFLOWS)
        retained = {ref for ref in existing if not ref.startswith(prefixes)}
    desired = retained | refs
    if desired != existing:
        payload = {'selected_workflows': sorted(desired)}
        subprocess.run(['gh', 'api', '--method', 'PATCH', path, '--input', '-'],
                       input=json.dumps(payload), text=True, check=True, timeout=45,
                       stdout=subprocess.DEVNULL)
        print(f'Updated release access: added={sorted(desired - existing)}, '
              f'removed={sorted(existing - desired)}', flush=True)


def worker_command(config, platform):
    group = ['--runner-group-id', str(config['runner_group_id']), '--execute']
    if platform == 'darwin-arm64':
        mac = config['macos']
        return [sys.executable, str(ROOT / '.github/scripts/release-macos-runner.py'),
                '--host', mac['host'], '--image', mac['image'], *group]
    cloud = config['gcp']
    arch = platform.removeprefix('linux-')
    return [sys.executable, str(ROOT / '.github/scripts/release-runner.py'),
            '--project', cloud['project'], '--zone', cloud['zone'], '--subnet', cloud['subnet'],
            '--arch', arch, '--image', cloud['images'][arch], '--machine-type', cloud['machine_types'][arch],
            '--organization', config['organization'], '--repository', config['repository'], *group]


def run(args):
    config = json.loads(args.config.read_text())
    repo = config['repository']
    args.logs.mkdir(parents=True, exist_ok=True)
    workers = {}
    failures = {platform: 0 for platform in PLATFORMS}
    try:
        while True:
            for platform, (process, log) in list(workers.items()):
                if process.poll() is not None:
                    log.close()
                    if process.returncode:
                        failures[platform] += 1
                    del workers[platform]
            if any(count >= 3 for count in failures.values()):
                raise RuntimeError('Three worker failures on one platform; inspect logs before retrying')
            wanted = set()
            complete = True
            conclusions = {}
            runs = (discover(config) if args.watch else
                    [api(f'repos/{repo}/actions/runs/{run_id}') for run_id in args.run_id])
            refs = set()
            for run_info in runs:
                run_id = run_info['id']
                if run_info['status'] == 'completed':
                    conclusions[run_id] = run_info['conclusion']
                    continue
                complete = False
                try:
                    refs.update(authorize(config, run_info))
                except ValueError as error:
                    if not args.watch:
                        raise
                    print(f'Refusing run {run_id}: {error}', file=sys.stderr, flush=True)
                    continue
                jobs = pages(f'repos/{repo}/actions/runs/{run_id}/jobs?', 'jobs')
                for job in jobs:
                    if job['status'] == 'queued':
                        for platform in PLATFORMS:
                            if platform + '-toolchain-release' in job['labels']:
                                wanted.add(platform)
            if refs or args.watch:
                reconcile_access(config, refs, prune=args.watch)
            for platform in sorted(wanted - workers.keys()):
                log_path = args.logs / f'{platform}-{time.time_ns()}.log'
                log = log_path.open('w')
                process = subprocess.Popen(worker_command(config, platform), stdout=log, stderr=subprocess.STDOUT)
                workers[platform] = process, log
                print(f'{platform}: started controller {process.pid}; {log_path}', flush=True)
            if complete and not workers and not args.watch:
                if any(value != 'success' for value in conclusions.values()):
                    raise RuntimeError(f'Actions runs did not all succeed: {conclusions}')
                break
            time.sleep(15)
    finally:
        for process, _ in workers.values():
            if process.poll() is None:
                process.terminate()
        for process, log in workers.values():
            try:
                process.wait(timeout=240)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                print('Controller cleanup timed out; platform lifetime cap remains active', file=sys.stderr)
            log.close()


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--run-id', action='append', type=int)
    selection.add_argument('--watch', action='store_true', help='Continuously discover tag-push releases')
    parser.add_argument('--config', type=Path, default=ROOT / '.github/release-runners/pool.json')
    parser.add_argument('--logs', type=Path, required=True)
    signal.signal(signal.SIGTERM, interrupted)
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    # One supervisor per controller; a second invocation must not allocate duplicate guests.
    with (args.logs / 'supervisor.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run(args)
