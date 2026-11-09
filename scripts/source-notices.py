# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Check first-party notices; --fix inserts headers while preserving shebangs.

Submodules, upstream patches, generated bundles and lockfiles retain their bytes.
Existing different SPDX expressions require review and are never overwritten.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LICENSE = 'SPDX-License-Identifier: Apache-2.0 OR MIT'
COPYRIGHT = 'Copyright the Elide Toolchain contributors.'
CODE = {'.c', '.h', '.cc', '.cpp', '.hpp', '.rs', '.ts', '.mjs'}
HASH = {'.sh', '.py', '.cmake'}


def comment_for(name):
    path = Path(name)
    if name.startswith(('action/dist/', 'src/patches/')):
        return None
    if path.suffix in CODE:
        return '//'
    if path.suffix in HASH or path.name in {'CMakeLists.txt', 'elide-toolchain', 'musl-gcc'}:
        return '#'
    return None


def add_notice(text, comment):
    header = f'{comment} {COPYRIGHT}\n{comment} {LICENSE}\n'
    if text.startswith('#!'):
        first, _, rest = text.partition('\n')
        return first + '\n' + header + rest
    return header + text


def check(fix=False):
    names = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT,
    ).decode().split('\0')
    # Exempt only hash-verified canonical snapshots, not first-party helpers in
    # the same directory. A changed snapshot must update its provenance record.
    vendored = set()
    canonical = ROOT / 'tools/symbol-coverage'
    for manifest in canonical.glob('*UPSTREAM.json'):
        for name, digest in json.loads(manifest.read_text())['files'].items():
            if Path(name).name != name:
                raise SystemExit(f'Invalid canonical source path: {name}')
            source = canonical / name
            if hashlib.sha256(source.read_bytes()).hexdigest() != digest:
                raise SystemExit(f'Canonical source hash mismatch: {source}')
            vendored.add(source.relative_to(ROOT).as_posix())
    failures = []
    count = 0
    for name in sorted(set(filter(None, names))):
        comment = comment_for(name)
        path = ROOT / name
        if name in vendored or not comment or not path.is_file():
            continue
        text = path.read_text()
        header = text[:1024]
        if LICENSE not in header or 'Copyright' not in header:
            if fix and 'SPDX-License-Identifier:' not in header:
                path.write_text(add_notice(text, comment))
            else:
                failures.append(name)
        count += 1
    if failures:
        raise SystemExit('Missing or conflicting source notices:\n' + '\n'.join(failures))
    print(f'Dual-license notices verified for {count} first-party sources')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fix', action='store_true')
    check(parser.parse_args().fix)
