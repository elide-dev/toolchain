# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Check lifetime boundaries and ensure isolated jobs cannot select ordinary pools."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


POOL = module('release_pool', '.github/scripts/release-pool.py')
WATCHDOG = module('watchdog', '.github/release-runners/macos-watchdog.py')
MAC = module('mac_runner', '.github/scripts/release-macos-runner.py')


class PoolTest(unittest.TestCase):
    def test_watchdog_only_expires_job_namespace(self):
        now = 1000000
        old = f'toolchain-release-job-{now - 13 * 3600}-abcdef123456'
        self.assertTrue(WATCHDOG.expired(old, now))
        self.assertFalse(WATCHDOG.expired(old, now - 1))
        for name in ('toolchain-release-macos-image-20261108', 'personal-vm',
                     'toolchain-release-job-0-../anything', 'toolchain-release-job-0-invalid'):
            self.assertFalse(WATCHDOG.expired(name, now))

    def test_pool_never_uses_general_ci_labels(self):
        config = json.loads((ROOT / '.github/release-runners/pool.json').read_text())
        for platform in POOL.PLATFORMS:
            command = POOL.worker_command(config, platform)
            self.assertIn('--execute', command)
            self.assertIn('--runner-group-id', command)
            self.assertNotIn('cipool', ' '.join(command))
            if platform.startswith('linux'):
                self.assertIn('--organization', command)
                self.assertIn(config['gcp']['images'][platform.removeprefix('linux-')], command)

    def test_pool_rejects_pr_runs_before_allocating(self):
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(config=ROOT / '.github/release-runners/pool.json',
                                      logs=Path(directory), run_id=[123])
            data = {'status': 'in_progress', 'event': 'pull_request',
                    'path': '.github/workflows/on.pr.yml', 'head_branch': 'feature'}
            with patch.object(POOL, 'api', return_value=data), patch.object(POOL.subprocess, 'Popen') as spawn:
                with self.assertRaises(ValueError):
                    POOL.run(args)
                spawn.assert_not_called()

    def test_mac_cleanup_runs_after_boot_failure(self):
        args = argparse.Namespace(host='elide@10.5.0.15', image='clean-image', runner_group_id=18, execute=True)
        calls = []

        def remote(_host, command, **_kwargs):
            calls.append(command)
            if 'clone' in command:
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0)

        with patch.object(MAC, 'remote', side_effect=remote):
            with self.assertRaises(subprocess.CalledProcessError):
                MAC.run(args)
        self.assertIn('stop', calls[-2])
        self.assertIn('delete', calls[-1])
        self.assertTrue(calls[-1][-1].startswith('toolchain-release-job-'))
        self.assertNotIn('clean-image', calls[-1])

    def test_mac_network_blocks_host_and_private_networks(self):
        for rule in ('out @host', 'out @peers', 'out 10.0.0.0/8', 'out 192.168.0.0/16', 'in 0.0.0.0/0'):
            self.assertIn(rule, MAC.BLOCK)
        self.assertNotIn('port 22', MAC.ALLOW)
        self.assertIn('port 53', MAC.ALLOW)


if __name__ == '__main__':
    unittest.main()
