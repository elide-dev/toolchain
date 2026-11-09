# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Run one GitHub job on a fresh GCE VM; keep controller credentials off the VM."""
import argparse
import json
import re
import shlex
import signal
import subprocess
import sys
import time
import uuid


def command(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--project', required=True)
    p.add_argument('--zone', required=True)
    p.add_argument('--image', required=True, help='projects/PROJECT/global/images/NAME; never an image family')
    p.add_argument('--arch', choices=('amd64', 'arm64'), required=True)
    p.add_argument('--machine-type', required=True)
    p.add_argument('--subnet', required=True)
    p.add_argument('--repository', default='elide-dev/toolchain')
    p.add_argument('--disk-size', default='300GB')
    p.add_argument('--runner-group-id', type=int, default=1)
    p.add_argument('--execute', action='store_true', help='Create a billable VM; default only prints the plan')
    return p


def plan(args, name):
    if not re.fullmatch(r'projects/[a-z0-9-]+/global/images/[a-z0-9-]+', args.image):
        raise ValueError('Use a specific approved image, not a family or URL')
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', args.repository):
        raise ValueError('Invalid repository')
    for value in (args.project, args.zone, args.machine_type, args.subnet, args.disk_size):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9./_-]*', value):
            raise ValueError('Invalid infrastructure identifier')
    location = [f'--project={args.project}', f'--zone={args.zone}', '--quiet']
    create = ['gcloud', 'compute', 'instances', 'create', name, *location,
              f'--image={args.image}', f'--machine-type={args.machine_type}',
              f'--subnet={args.subnet}', f'--boot-disk-size={args.disk_size}',
              '--boot-disk-type=hyperdisk-balanced',
              '--boot-disk-auto-delete', '--no-service-account', '--no-scopes',
              '--no-address', '--shielded-secure-boot', '--no-restart-on-failure',
              '--max-run-duration=13h', '--instance-termination-action=DELETE',
              '--metadata=enable-oslogin=TRUE,block-project-ssh-keys=TRUE',
              '--labels=app=toolchain-release,lifecycle=single-job']
    ssh = ['gcloud', 'compute', 'ssh', name, *location, '--tunnel-through-iap',
           '--ssh-flag=-oConnectTimeout=10', '--ssh-flag=-oBatchMode=yes']
    delete = ['gcloud', 'compute', 'instances', 'delete', name, *location]
    jit = {'name': name, 'runner_group_id': args.runner_group_id,
           'labels': ['self-hosted', 'Linux', 'X64' if args.arch == 'amd64' else 'ARM64',
                      f'linux-{args.arch}-toolchain-release'], 'work_folder': '_work'}
    return create, ssh, delete, jit


def run(args):
    name = f'toolchain-release-{args.arch}-{uuid.uuid4().hex[:12]}'
    create, ssh, delete, jit = plan(args, name)
    if not args.execute:
        print(json.dumps({'create': create, 'registration': jit, 'delete': delete}, indent=2))
        return
    runner_id = None
    # Even a create timeout may leave a VM behind. Delete this unique name in finally;
    # GCE's independent maximum lifetime also covers controller loss/SIGKILL.
    try:
        command(create, timeout=300)
        for attempt in range(30):
            try:
                command([*ssh, '--command=true'], timeout=30, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL)
                break
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                if attempt == 29:
                    raise RuntimeError('Release guest did not become reachable through IAP') from None
                time.sleep(10)
        # The image contains a pinned runner under /opt/actions-runner, owned by
        # ci-agent. Never copy a PAT, GitHub App key, or gcloud credentials there.
        response = command(['gh', 'api', '--method', 'POST',
                            f'repos/{args.repository}/actions/runners/generate-jitconfig',
                            '--input', '-'], input=json.dumps(jit), capture_output=True, timeout=30)
        config = json.loads(response.stdout)
        runner_id = config['runner']['id']
        # JIT material is sent over stdin, never in metadata, local argv or logs.
        script = 'cd /opt/actions-runner && read -r jit && exec ./run.sh --jitconfig "$jit"'
        remote = 'sudo -u ci-agent bash -c ' + shlex.quote(script)
        command([*ssh, '--command=' + remote], input=config['encoded_jit_config'] + '\n',
                timeout=12 * 3600 + 1800)
    finally:
        # Try both cleanups even if one fails. JIT runners normally unregister
        # themselves; an already removed registration is safe to ignore.
        cleanup_error = False
        try:
            cleanup = subprocess.run(delete, text=True, timeout=180, check=False)
            cleanup_error = cleanup.returncode != 0
        except (subprocess.TimeoutExpired, OSError):
            cleanup_error = True
        finally:
            if runner_id is not None:
                try:
                    subprocess.run(['gh', 'api', '--method', 'DELETE',
                                    f'repos/{args.repository}/actions/runners/{runner_id}'],
                                   text=True, timeout=30, check=False, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
                except (subprocess.TimeoutExpired, OSError):
                    print('Runner deregistration failed; reconcile it in GitHub.', file=sys.stderr)
        if cleanup_error:
            print(f'VM cleanup failed for {name}; GCE lifetime limit remains active.', file=sys.stderr)
            raise RuntimeError('Release VM cleanup failed')


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    run(parser().parse_args())
