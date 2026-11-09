# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Select native builds from the complete diff; fast gates always run."""
import json
import os
from pathlib import Path
import subprocess

FAST_FILES = {
    'LICENSE', 'LICENSE-APACHE', 'LICENSE-MIT', 'DCO', '.bestpractices.json',
    '.editorconfig', '.gitignore', 'mise.toml', 'mise.lock', 'tests/run.sh',
    'scripts/best-practices.py', 'scripts/check-dco.py', 'scripts/check-hygiene.py',
    'scripts/source-notices.py', 'scripts/ci-changes.py',
    '.clusterfuzzlite/Dockerfile', '.clusterfuzzlite/build.sh',
    '.clusterfuzzlite/project.yaml', '.clusterfuzzlite/allocator-fuzz.cc',
}
FAST_PREFIXES = ('.github/', 'action/', 'tests/unit/', 'tools/best-practices')


def fast_path(path):
    return (path.lower().endswith('.md') or path in FAST_FILES
            or path.startswith(FAST_PREFIXES)
            or (path.startswith('tests/test_') and path.endswith('.py'))
            or path == 'tests/best-practices.test.ts')


def requires_full(paths):
    """Path-only conservative classifier, before exact-content checks."""
    return not paths or any(not fast_path(path) for path in paths)


def git(*args):
    return subprocess.check_output(['git', *args])


def entry(revision, path):
    raw = git('ls-tree', '-z', revision, '--', path)
    if not raw:
        return None
    metadata, _ = raw.split(b'\t', 1)
    mode, kind, oid = metadata.decode().split()
    return mode, kind, oid


def without_notice(content):
    lines = content.splitlines(keepends=True)
    start = 1 if content.startswith(b'#!') else 0
    for prefix in (b'# ', b'// '):
        notice = [prefix + b'Copyright the Elide Toolchain contributors.\n',
                  prefix + b'SPDX-License-Identifier: Apache-2.0 OR MIT\n']
        if lines[start:start + 2] == notice:
            del lines[start:start + 2]
            break
    return b''.join(lines)


def classify(base, head):
    paths = [p for p in git('diff', '--name-only', '--no-renames', '-z', base, head).decode().split('\0') if p]
    if not paths:
        return True
    # Exact reviewed packaging-only changes are recorded by old/new blob IDs.
    # They cannot exempt another revision of either file or any native code change.
    manifest = Path(__file__).resolve().parents[1] / '.github/native-build-exemptions.json'
    exemptions = json.loads(manifest.read_text()) if manifest.exists() else []
    native = []
    for path in paths:
        if fast_path(path):
            continue
        old, new = entry(base, path), entry(head, path)
        if old and new and old[0] == new[0] and old[0] in {'100644', '100755'}:
            before, after = git('cat-file', 'blob', old[2]), git('cat-file', 'blob', new[2])
            if without_notice(before) == without_notice(after):
                continue
            if any(e['path'] == path and e['before'] == old[2] and e['after'] == new[2]
                   for e in exemptions):
                continue
        native.append(path)
    if native:
        print('Native inputs changed: ' + ', '.join(native))
    return bool(native)


def main():
    base, head = os.environ.get('DIFF_BASE', ''), os.environ.get('DIFF_HEAD', '')
    full = True
    if base and head and set(base) != {'0'}:
        full = classify(base, head)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'full={str(full).lower()}\n')
    print('Full native validation required' if full else 'Maintenance-only change: fast tests, hygiene and Gate remain active')


if __name__ == '__main__':
    main()
