# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Check code-scanning locations and severity conversion, including clean runs."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'shellcheck_sarif', Path(__file__).resolve().parents[1] / '.github/scripts/shellcheck-sarif.py')
sarif = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sarif)


class SarifTests(unittest.TestCase):
    def test_findings_preserve_source_location_and_severity(self):
        comment = {'code': 2086, 'level': 'info', 'message': 'Double quote to prevent globbing.',
                   'file': 'scripts/file name.sh', 'line': 7, 'column': 4}
        run = sarif.report([comment], '0.11.0')['runs'][0]
        result = run['results'][0]
        self.assertEqual(result['ruleId'], 'SC2086')
        self.assertEqual(result['level'], 'note')
        location = result['locations'][0]['physicalLocation']
        self.assertEqual(location['artifactLocation']['uri'], 'scripts/file%20name.sh')
        self.assertEqual(location['region'], {'startLine': 7, 'startColumn': 4})
        self.assertEqual(run['tool']['driver']['rules'][0]['id'], result['ruleId'])

    def test_clean_run_has_no_findings(self):
        run = sarif.report([], '0.11.0')['runs'][0]
        self.assertEqual(run['results'], [])
        self.assertEqual(run['tool']['driver']['name'], 'ShellCheck')
