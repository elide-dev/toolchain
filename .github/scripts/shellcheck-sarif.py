# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Run ShellCheck over first-party shell sources and emit GitHub code-scanning SARIF."""
import json
from pathlib import Path
import subprocess
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[2]


def report(comments, version):
    rules = sorted({c['code'] for c in comments})
    return {
        '$schema': 'https://json.schemastore.org/sarif-2.1.0.json',
        'version': '2.1.0',
        'runs': [{
            'tool': {'driver': {
                'name': 'ShellCheck', 'version': version,
                'informationUri': 'https://www.shellcheck.net/',
                'rules': [{'id': f'SC{code}', 'helpUri': f'https://www.shellcheck.net/wiki/SC{code}'}
                          for code in rules],
            }},
            'results': [{
                'ruleId': f"SC{c['code']}",
                'level': {'error': 'error', 'warning': 'warning', 'info': 'note', 'style': 'note'}[c['level']],
                'message': {'text': c['message']},
                'locations': [{'physicalLocation': {
                    'artifactLocation': {'uri': quote(c['file']), 'uriBaseId': '%SRCROOT%'},
                    'region': {'startLine': c['line'], 'startColumn': c['column']},
                }}],
            } for c in comments],
        }],
    }


def main():
    files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    bash = [f for f in files if f.endswith('.sh') and f.startswith(('scripts/', 'tests/'))]
    groups = [(['-x'], ['build.sh', *bash]), (['-s', 'sh'], ['src/elide-toolchain', 'src/shims/musl-gcc'])]
    comments = []
    failed = False
    for flags, paths in groups:
        result = subprocess.run(['shellcheck', '--format=json', *flags, *paths], cwd=ROOT,
                                capture_output=True, text=True, check=False)
        if result.returncode not in (0, 1):
            raise RuntimeError(f'ShellCheck failed ({result.returncode}): {result.stderr}')
        comments.extend(json.loads(result.stdout))
        failed |= result.returncode != 0
    version = subprocess.check_output(['shellcheck', '--version'], text=True).split('version: ')[1].splitlines()[0]
    output = ROOT / 'dist/shellcheck.sarif'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report(comments, version), indent=2) + '\n')
    print(f'{len(comments)} ShellCheck findings; report: {output}')
    raise SystemExit(int(failed))


if __name__ == '__main__':
    main()
