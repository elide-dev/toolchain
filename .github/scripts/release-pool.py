# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Supply disposable guests only while the explicitly selected Actions runs need them."""
import argparse
import json
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
PLATFORMS = ('linux-amd64', 'linux-arm64', 'darwin-arm64')


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True, timeout=45))


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
            for run_id in args.run_id:
                run_info = api(f'repos/{repo}/actions/runs/{run_id}')
                if run_info['status'] == 'completed':
                    conclusions[run_id] = run_info['conclusion']
                    continue
                complete = False
                # Refuse arbitrary PR/manual workflows even if they request a matching label.
                trusted = (run_info['event'] == 'workflow_dispatch' and
                           run_info['path'] == '.github/workflows/release-runner-qualification.yml' and
                           run_info['head_branch'] == 'main') or (
                               run_info['event'] == 'push' and run_info['path'] == '.github/workflows/on.release.yml'
                               and run_info['head_branch'] == config['release'])
                if not trusted:
                    raise ValueError(f'Run {run_id} is not an approved release or qualification run')
                jobs = api(f'repos/{repo}/actions/runs/{run_id}/jobs?per_page=100')['jobs']
                for job in jobs:
                    if job['status'] == 'queued':
                        for platform in PLATFORMS:
                            if platform + '-toolchain-release' in job['labels']:
                                wanted.add(platform)
            for platform in sorted(wanted - workers.keys()):
                log_path = args.logs / f'{platform}-{time.time_ns()}.log'
                log = log_path.open('w')
                process = subprocess.Popen(worker_command(config, platform), stdout=log, stderr=subprocess.STDOUT)
                workers[platform] = process, log
                print(f'{platform}: started controller {process.pid}; {log_path}', flush=True)
            if complete and not workers:
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
    parser.add_argument('--run-id', action='append', type=int, required=True)
    parser.add_argument('--config', type=Path, default=ROOT / '.github/release-runners/pool.json')
    parser.add_argument('--logs', type=Path, required=True)
    signal.signal(signal.SIGTERM, interrupted)
    run(parser.parse_args())
