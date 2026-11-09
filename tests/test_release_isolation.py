# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Exercise release admission, private caches, and single-job VM lifecycle failures."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('release_runner', ROOT / '.github/scripts/release-runner.py')
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


def script(workflow, step):
    source = (ROOT / '.github/workflows' / workflow).read_text().split(step, 1)[1]
    source = source.split('        run: |\n', 1)[1]
    return textwrap.dedent(re.split(r'\n(?=\S|  \w|      - )', source, maxsplit=1)[0])


class ReleaseTest(unittest.TestCase):
    def test_readiness_fails_closed(self):
        shell = script('job.release-build.yml', 'name: Require release infrastructure')
        for ready, ref, event, expected in [('', 'tag', 'push', False), ('false', 'tag', 'push', False),
                                           ('true', 'branch', 'push', False),
                                           ('true', 'tag', 'workflow_dispatch', False),
                                           ('true', 'tag', 'push', True)]:
            with self.subTest(ready=ready, ref=ref, event=event):
                result = subprocess.run(['bash', '-e', '-c', shell], capture_output=True,
                                        env={**os.environ, 'ISOLATION_READY': ready,
                                             'REF_TYPE': ref, 'EVENT_NAME': event})
                self.assertEqual(result.returncode == 0, expected)

    def test_release_caches_are_new_each_time(self):
        shell = script('job.build.yml', 'name: "Setup: Isolated release caches"')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'env'
            env = {**os.environ, 'RUNNER_TEMP': directory, 'GITHUB_ENV': str(output)}
            subprocess.run(['bash', '-e', '-c', shell], env=env, check=True)
            first = dict(line.split('=', 1) for line in output.read_text().splitlines())
            Path(first['CCACHE_DIR'], 'poison').write_text('old job data')
            output.unlink()
            subprocess.run(['bash', '-e', '-c', shell], env=env, check=True)
            second = dict(line.split('=', 1) for line in output.read_text().splitlines())
            self.assertNotEqual(first['CCACHE_DIR'], second['CCACHE_DIR'])
            self.assertEqual(list(Path(second['CCACHE_DIR']).iterdir()), [])
            self.assertEqual(second['USE_SCCACHE'], 'no')
            self.assertEqual(Path(second['CCACHE_CONFIGPATH']).read_text(), 'remote_storage =\n')

    def test_publication_stops_on_invalid_provenance(self):
        shell = script('on.release.yml', 'name: "Verify release provenance"')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'dist').mkdir()
            (root / 'dist/test.tar.xz').write_text('fixture')
            gh = root / 'gh'
            gh.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ARG_LOG"\nexit "$VERIFY_EXIT"\n')
            gh.chmod(0o755)
            env = {**os.environ, 'PATH': directory + os.pathsep + os.environ['PATH'],
                   'GITHUB_REPOSITORY': 'elide-dev/toolchain', 'GITHUB_SHA': 'a' * 40,
                   'GITHUB_REF': 'refs/tags/v2026.11.6', 'ARG_LOG': str(root / 'args')}
            for exit_code in ('0', '1'):
                result = subprocess.run(['bash', '-e', '-c', shell], cwd=directory,
                                        env={**env, 'VERIFY_EXIT': exit_code}, capture_output=True)
                self.assertEqual(result.returncode == 0, exit_code == '0')
            args = (root / 'args').read_text().splitlines()
            for option in ('--source-ref', '--source-digest', '--signer-digest',
                           '--deny-self-hosted-runners', '--signer-workflow', '--bundle'):
                self.assertIn(option, args)

    def arguments(self):
        return RUNNER.parser().parse_args(['--project', 'example-project', '--zone', 'us-east1-b',
                                          '--image', 'projects/example-project/global/images/release-1',
                                          '--arch', 'amd64', '--machine-type', 'c4d-highmem-8',
                                          '--subnet', 'release-builders', '--execute'])

    def test_plan_has_external_lifetime_and_no_cloud_credentials(self):
        create, _, _, jit = RUNNER.plan(self.arguments(), 'fixture')
        for flag in ('--no-service-account', '--no-scopes', '--no-address', '--boot-disk-auto-delete',
                     '--max-run-duration=13h', '--instance-termination-action=DELETE'):
            self.assertIn(flag, create)
        self.assertIn('linux-amd64-toolchain-release', jit['labels'])
        self.assertNotIn('linux-amd64-cipool', jit['labels'])
        args = self.arguments()
        args.image = 'projects/example/global/images/family/ubuntu'
        with self.assertRaises(ValueError):
            RUNNER.plan(args, 'fixture')

    def test_cleanup_after_failed_creation_and_failed_job(self):
        for failed_stage in ('create', 'job', None):
            calls = []

            def fake(args, **kwargs):
                calls.append((args, kwargs))
                if (failed_stage == 'create' and 'create' in args) or (
                        failed_stage == 'job' and any('--command=sudo' in arg for arg in args)):
                    raise subprocess.CalledProcessError(1, args)
                return subprocess.CompletedProcess(args, 0, json.dumps({
                    'runner': {'id': 123}, 'encoded_jit_config': 'sensitive-fixture'}), '')

            with self.subTest(failed_stage=failed_stage), patch.object(RUNNER, 'command', side_effect=fake), \
                    patch.object(RUNNER.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as cleanup:
                if failed_stage:
                    with self.assertRaises(subprocess.CalledProcessError):
                        RUNNER.run(self.arguments())
                else:
                    RUNNER.run(self.arguments())
                self.assertIn('delete', cleanup.call_args_list[0].args[0])
                if failed_stage != 'create':
                    self.assertEqual(cleanup.call_count, 2)
                    self.assertEqual(calls[-1][1]['input'], 'sensitive-fixture\n')
                    self.assertNotIn('sensitive-fixture', ' '.join(calls[-1][0]))


if __name__ == '__main__':
    unittest.main()
