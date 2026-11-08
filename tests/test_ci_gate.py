# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Execute each workflow's actual gate with failure, skip, and cancellation inputs."""
import json
import os
from pathlib import Path
import subprocess
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GateTest(unittest.TestCase):
    def test_workflow_gates(self):
        success = {name: {'result': 'success'} for name in ('changes', 'unit', 'build', 'e2e')}
        docs = {**success, 'build': {'result': 'skipped'}, 'e2e': {'result': 'skipped'}}
        cases = [('true', 'false', success, True), ('false', 'false', docs, True),
                 ('false', 'true', docs, True), ('true', 'true', docs, False),
                 ('true', 'false', docs, False), ('false', 'false', success, False)]
        for full, results in (('true', success), ('false', docs)):
            for job in results:
                for state in ('failure', 'cancelled'):
                    cases.append((full, 'false', {**results, job: {'result': state}}, False))
        for workflow in ('on.pr.yml', 'on.push.yml', 'on.queue.yml'):
            text = (ROOT / '.github/workflows' / workflow).read_text()
            gate = text.split('  gate:\n', 1)[1]
            script = textwrap.dedent(gate.split('        run: |\n', 1)[1])
            for full, fork, results, expected in cases:
                with self.subTest(workflow=workflow, full=full, fork=fork, results=results):
                    result = subprocess.run(
                        ['bash', '-e', '-c', script], capture_output=True,
                        env={**os.environ, 'FULL': full, 'FORK': fork, 'RESULTS': json.dumps(results)},
                    )
                    self.assertEqual(result.returncode == 0, expected, result.stderr.decode())


if __name__ == '__main__':
    unittest.main()
