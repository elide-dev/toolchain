# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Run one job in a disposable macOS VM, controlled through SSH and guest-agent stdin."""
import argparse
import json
import re
import shlex
import signal
import subprocess
import time
import uuid

TART = '/opt/toolchain-release/bin/tart'
PATH = '/opt/toolchain-release/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'
ALLOW = 'out proto udp @host port 53,out proto tcp @host port 53'
BLOCK = 'out @host,out @peers,out 10.0.0.0/8,out 172.16.0.0/12,out 192.168.0.0/16,out 100.64.0.0/10,in 0.0.0.0/0'


def remote(host, args, **kwargs):
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', host,
                           shlex.join(['env', 'PATH=' + PATH, *args])], text=True, check=True, **kwargs)


def run(args):
    if not re.fullmatch(r'[A-Za-z0-9_.@-]+', args.host) or not re.fullmatch(r'[A-Za-z0-9_-]+', args.image):
        raise ValueError('Invalid host or local image name')
    name = f'toolchain-release-job-{int(time.time())}-{uuid.uuid4().hex[:12]}'
    start = [TART, 'run', name, '--no-graphics', '--no-audio', '--no-usb-accessories', '--no-clipboard',
             '--net-softnet', '--net-softnet-allow=' + ALLOW, '--net-softnet-block=' + BLOCK]
    registration = {'name': name, 'runner_group_id': args.runner_group_id,
                    'labels': ['self-hosted', 'macOS', 'ARM64', 'darwin-arm64-toolchain-release'],
                    'work_folder': '_work'}
    if not args.execute:
        print(json.dumps({'host': args.host, 'clone': [TART, 'clone', args.image, name],
                          'start': start, 'registration': registration, 'delete': [TART, 'delete', name]}, indent=2))
        return
    runner_id = None
    remote(args.host, ['/bin/launchctl', 'print', 'system/dev.elide.toolchain-release-watchdog'],
           timeout=30, stdout=subprocess.DEVNULL)
    try:
        remote(args.host, [TART, 'clone', args.image, name], timeout=180)
        # No host mounts, clipboard, USB or network listeners are exposed to the guest.
        shell = 'mkdir -p "$HOME/.local/state/toolchain-release"; nohup ' + shlex.join(start)
        shell += f' > "$HOME/.local/state/toolchain-release/{name}.log" 2>&1 < /dev/null &'
        remote(args.host, ['/bin/bash', '-c', shell], timeout=30)
        for attempt in range(40):
            try:
                remote(args.host, [TART, 'exec', name, '/usr/bin/true'], timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                break
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                if attempt == 39:
                    raise RuntimeError('macOS guest agent did not become ready') from None
                time.sleep(5)
        response = subprocess.run(['gh', 'api', '-X', 'POST',
                                   'orgs/elide-dev/actions/runners/generate-jitconfig', '--input', '-'],
                                  input=json.dumps(registration), text=True, capture_output=True, check=True, timeout=30)
        config = json.loads(response.stdout)
        runner_id = config['runner']['id']
        script = 'cd "$HOME/actions-runner" && read -r jit && exec ./run.sh --jitconfig "$jit"'
        remote(args.host, [TART, 'exec', '-i', name, '/bin/bash', '-c', script],
               input=config['encoded_jit_config'] + '\n', timeout=12 * 3600 + 1800)
    finally:
        # Independent host watchdog deletes this namespace after 13 hours, even if
        # the controller disappears. Always try deletion after a stop failure.
        try:
            remote(args.host, [TART, 'stop', name], timeout=30)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
        try:
            remote(args.host, [TART, 'delete', name], timeout=60)
        finally:
            if runner_id is not None:
                subprocess.run(['gh', 'api', '-X', 'DELETE', f'orgs/elide-dev/actions/runners/{runner_id}'],
                               capture_output=True, text=True, timeout=30, check=False)


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='elide@10.5.0.15')
    parser.add_argument('--image', required=True)
    parser.add_argument('--runner-group-id', type=int, default=18)
    parser.add_argument('--execute', action='store_true')
    signal.signal(signal.SIGTERM, interrupted)
    run(parser.parse_args())
