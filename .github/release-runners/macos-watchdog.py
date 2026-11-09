# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Host-side lifetime cap; never runs inside a build guest."""
import json
import re
import subprocess
import time

TART = '/opt/toolchain-release/bin/tart'


def expired(name, now):
    match = re.fullmatch(r'toolchain-release-job-([0-9]+)-[0-9a-f]{12}', name)
    return bool(match and now - int(match[1]) >= 13 * 3600)


def main():
    entries = json.loads(subprocess.check_output([TART, 'list', '--source', 'local', '--format', 'json'], text=True))
    for entry in entries:
        name = entry['Name']
        if expired(name, time.time()):
            print('Removing expired release VM:', name, flush=True)
            try:
                subprocess.run([TART, 'stop', name], timeout=30, check=False)
            finally:
                subprocess.run([TART, 'delete', name], timeout=60, check=True)


if __name__ == '__main__':
    main()
