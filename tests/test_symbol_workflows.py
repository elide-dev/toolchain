# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Exercise the reusable artifact gate's actual shell body without GitHub access."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SymbolArtifactGateTests(unittest.TestCase):
    def gate(self, pages, required=False, run_id='123', api_error=False):
        workflow = (ROOT / '.github/workflows/job.symbol-artifacts.yml').read_text()
        script = '\n'.join(line[10:] for line in workflow.split('        run: |\n', 1)[1].splitlines())
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            mock = directory / 'gh'
            mock.write_text('#!/usr/bin/env python3\nimport os,sys\n'
                            'sys.exit(1) if os.environ["API_ERROR"] == "true" else None\n'
                            'print(os.environ["ARTIFACT_PAGES"])\n')
            mock.chmod(0o755)
            output = directory / 'output'
            env = {**os.environ, 'PATH': str(directory) + os.pathsep + os.environ['PATH'],
                   'GITHUB_OUTPUT': str(output), 'GITHUB_REPOSITORY': 'elide-dev/toolchain',
                   'PRODUCER_RUN': run_id, 'ARTIFACT_PREFIX': 'native-debug-toolchain-',
                   'REQUIRE_ARTIFACT': str(required).lower(), 'ARTIFACT_PAGES': json.dumps(pages),
                   'API_ERROR': str(api_error).lower()}
            result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script],
                                    env=env, capture_output=True, text=True)
            return result.returncode, output.read_text() if output.exists() else ''

    def test_maintenance_skips_consumers(self):
        self.assertEqual(self.gate([{'artifacts': []}]), (0, 'available=false\n'))

    def test_later_page_can_supply_native_artifacts(self):
        pages = [{'artifacts': []}, {'artifacts': [
            {'name': 'native-debug-toolchain-linux-arm64', 'expired': False}]}]
        self.assertEqual(self.gate(pages), (0, 'available=true\n'))

    def test_expired_and_unrelated_artifacts_do_not_enable_consumers(self):
        pages = [{'artifacts': [
            {'name': 'native-debug-toolchain-linux-arm64', 'expired': True},
            {'name': 'build-logs-linux-arm64', 'expired': False}]}]
        self.assertEqual(self.gate(pages), (0, 'available=false\n'))

    def test_manual_qualification_runs_strict_consumer_even_without_artifacts(self):
        self.assertEqual(self.gate([{'artifacts': []}], required=True), (0, 'available=true\n'))

    def test_api_errors_fail_closed_including_manual_qualification(self):
        status, output = self.gate([], required=True, api_error=True)
        self.assertNotEqual(status, 0)
        self.assertEqual(output, '')

    def test_invalid_run_id_fails_before_api_lookup(self):
        status, output = self.gate([], run_id='123/../456')
        self.assertNotEqual(status, 0)
        self.assertEqual(output, '')


if __name__ == '__main__':
    unittest.main()
