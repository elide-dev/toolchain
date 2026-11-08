# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Check repository documentation, licensing metadata, and immutable action pins."""
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    'LICENSE', 'LICENSE-APACHE', 'LICENSE-MIT', 'THIRD_PARTY.md', 'README.md',
    'CONTRIBUTING.md', 'CONTRIBUTOR_AGREEMENT.md', 'DCO', 'AGENTS.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md',
    '.github/CODEOWNERS', 'docs/ci.md', 'docs/releases.md', 'docs/openssf.md',
)


def check():
    errors = []
    for name in REQUIRED:
        if not (ROOT / name).is_file():
            errors.append(f'missing required file: {name}')
    package = json.loads((ROOT / 'action/package.json').read_text())
    if package.get('license') != 'Apache-2.0 OR MIT':
        errors.append('action/package.json: declare Apache-2.0 OR MIT')
    # Include new files during local development, never descend into submodules.
    paths = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
        cwd=ROOT,
    ).decode().split('\0')
    for name in sorted(set(paths)):
        path = ROOT / name
        if not path.is_file():
            continue
        if name.endswith('.md'):
            text = re.sub(r'```.*?```', '', path.read_text(), flags=re.S)
            for link in re.findall(r'\[[^\]]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)', text):
                link = link.strip('<>')
                parsed = urlsplit(link)
                if parsed.scheme or parsed.netloc or not parsed.path:
                    continue
                target = unquote(parsed.path)
                resolved = ROOT / target.lstrip('/') if target.startswith('/') else path.parent / target
                if not resolved.exists():
                    errors.append(f'{name}: missing local link {link}')
        if name.startswith('.github/workflows/') and name.endswith(('.yml', '.yaml')):
            text = path.read_text()
            for action in re.findall(r'^\s*(?:-\s*)?uses:\s*([^\s#]+)', text, re.M):
                if not action.startswith('./') and not re.fullmatch(r'[\w.-]+/[\w./-]+@[0-9a-f]{40}', action):
                    errors.append(f'{name}: action is not SHA-pinned: {action}')
            if re.search(r'persist-credentials:\s*true', text):
                errors.append(f'{name}: checkout must not persist credentials')
    notices = subprocess.run([sys.executable, str(ROOT / 'scripts/source-notices.py')],
                             cwd=ROOT, capture_output=True, text=True)
    if notices.returncode:
        errors.append(notices.stderr.strip() or notices.stdout.strip())
    # Validate the reviewed badge proposals without generating or submitting them.
    proposal = subprocess.run([sys.executable, str(ROOT / 'scripts/best-practices.py'),
                               '--check'], cwd=ROOT, capture_output=True, text=True)
    if proposal.returncode:
        errors.append('OpenSSF evidence: ' + proposal.stderr.strip())
    return errors


if __name__ == '__main__':
    failures = check()
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        sys.exit(1)
    print('Repository hygiene OK')
