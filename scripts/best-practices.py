# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Generate a standalone OpenSSF autofill page without authentication or submission."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
METADATA = {'name', 'description', 'license', 'implementation_languages'}


def load_data():
    data = {
        'answers': json.loads((ROOT / '.bestpractices.json').read_text()),
        'criteria': json.loads((ROOT / 'tools/best-practices-criteria.json').read_text()),
        'evidence': json.loads((ROOT / 'tools/best-practices-evidence.json').read_text()),
    }
    definitions = {}
    for criteria in data['criteria'].values():
        definitions.update(criteria)
    for name, definition in definitions.items():
        status = data['answers'].get(name + '_status')
        if status not in {'Met', 'Unmet', 'N/A', '?'}:
            raise ValueError(f'{name}: missing or invalid status')
        if status == 'N/A' and not definition['na_allowed']:
            raise ValueError(f'{name}: N/A not permitted')
        if not isinstance(data['answers'].get(name + '_justification', ''), str):
            raise ValueError(f'{name}: justification must be text')
        if data['evidence']['phases'].get(name) not in {'public', 'published'}:
            raise ValueError(f'{name}: missing publication phase')
    allowed = METADATA | {name + suffix for name in definitions for suffix in ('_status', '_justification')}
    if data['answers'].keys() - allowed:
        raise ValueError('Unexpected answer fields')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Validate evidence without writing HTML')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/openssf.html')
    args = parser.parse_args()
    data = load_data()
    if args.check:
        return
    # Escape '<' to prevent a future justification containing </script> ending the data block.
    payload = json.dumps(data).replace('<', '\\u003c')
    template = (ROOT / 'tools/best-practices.html').read_text()
    script = (ROOT / 'tools/best-practices.mjs').read_text()
    content = template.replace('__PROPOSAL_DATA__', payload).replace('__PROPOSAL_SCRIPT__', script)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(content)
    print(args.output.resolve())
    for level, definitions in data['criteria'].items():
        statuses = [data['answers'][name + '_status'] for name in definitions]
        print(f'{level}: {statuses.count("Met")} Met proposals, {statuses.count("N/A")} N/A, '
              f'{statuses.count("Unmet")} unmet, {statuses.count("?")} unanswered')


if __name__ == '__main__':
    main()
