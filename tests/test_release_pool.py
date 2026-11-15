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
                                      logs=Path(directory), run_id=[123], watch=False)
            data = {'id': 123, 'status': 'in_progress', 'event': 'pull_request',
                    'path': '.github/workflows/on.pr.yml', 'head_branch': 'feature'}
            with patch.object(POOL, 'api', return_value=data), patch.object(POOL.subprocess, 'Popen') as spawn:
                with self.assertRaises(ValueError):
                    POOL.run(args)
                spawn.assert_not_called()

    def release(self, tag='v2026.12.123'):
        repo = 'elide-dev/toolchain'
        sha = 'a' * 40
        return {'id': 123, 'status': 'queued', 'event': 'push',
                'repository': {'full_name': repo}, 'path': '.github/workflows/on.release.yml',
                'head_branch': tag, 'head_sha': sha,
                'referenced_workflows': [
                    {'path': f'{repo}/.github/workflows/{workflow}@{sha}', 'sha': sha,
                     'ref': f'refs/tags/{tag}'} for workflow in POOL.NATIVE_WORKFLOWS]}

    def test_future_releases_need_no_version_configuration(self):
        config = json.loads((ROOT / '.github/release-runners/pool.json').read_text())
        for tag in ('v2026.11.7', 'v2027.1.0', 'v2030.12.123-rc.1'):
            with self.subTest(tag=tag), patch.object(POOL, 'api', side_effect=[
                    {}, {'sha': 'a' * 40}, {'status': 'behind'}]):
                refs = POOL.authorize(config, self.release(tag))
                self.assertEqual(refs, {f'elide-dev/toolchain/.github/workflows/{workflow}@refs/tags/{tag}'
                                        for workflow in POOL.NATIVE_WORKFLOWS})

    def test_rejects_unintegrated_moved_or_forged_tags(self):
        config = json.loads((ROOT / '.github/release-runners/pool.json').read_text())
        for responses in ([{}, {'sha': 'b' * 40}],
                          [{}, {'sha': 'a' * 40}, {'status': 'ahead'}],
                          [{}, {'sha': 'a' * 40}, {'status': 'diverged'}]):
            with patch.object(POOL, 'api', side_effect=responses), self.assertRaises(ValueError):
                POOL.authorize(config, self.release())
        info = self.release()
        info['referenced_workflows'][0]['sha'] = 'b' * 40
        with patch.object(POOL, 'api', side_effect=[{}, {'sha': 'a' * 40}, {'status': 'identical'}]), \
                self.assertRaises(ValueError):
            POOL.authorize(config, info)
        for field, value in (('event', 'pull_request'), ('head_branch', 'feature'),
                             ('path', '.github/workflows/on.push.yml'),
                             ('repository', {'full_name': 'attacker/toolchain'})):
            info = self.release()
            info[field] = value
            with patch.object(POOL, 'api') as api, self.assertRaises(ValueError):
                POOL.authorize(config, info)
            api.assert_not_called()

    def test_missing_tag_does_not_fall_back_to_same_named_branch(self):
        config = json.loads((ROOT / '.github/release-runners/pool.json').read_text())
        with patch.object(POOL, 'api', side_effect=subprocess.CalledProcessError(1, 'gh')), \
                self.assertRaises(subprocess.CalledProcessError):
            POOL.authorize(config, self.release())

    def test_workflow_access_updates_keep_restrictions_and_are_idempotent(self):
        config = json.loads((ROOT / '.github/release-runners/pool.json').read_text())
        group = {'visibility': 'selected', 'restricted_to_workflows': True,
                 'selected_workflows': ['qualification@refs/heads/main']}
        repos = {'repositories': [{'full_name': config['repository']}]}
        refs = {'build@refs/tags/v2027.1.0'}
        with patch.object(POOL, 'api', side_effect=[group, repos]), \
                patch.object(POOL.subprocess, 'run') as update:
            POOL.reconcile_access(config, refs)
            self.assertEqual(json.loads(update.call_args.kwargs['input']),
                             {'selected_workflows': sorted(refs | set(group['selected_workflows']))})
        group['selected_workflows'] += list(refs)
        with patch.object(POOL, 'api', side_effect=[group, repos]), \
                patch.object(POOL.subprocess, 'run') as update:
            POOL.reconcile_access(config, refs)
            update.assert_not_called()
        group['restricted_to_workflows'] = False
        with patch.object(POOL, 'api', return_value=group), \
                patch.object(POOL.subprocess, 'run') as update, self.assertRaises(ValueError):
            POOL.reconcile_access(config, refs)
        update.assert_not_called()

    def test_discovery_includes_later_pages_and_only_release_pushes(self):
        def response(path):
            self.assertIn('/workflows/on.release.yml/runs?event=push&status=', path)
            if 'status=queued&' in path:
                return {'workflow_runs': [self.release()] * 100 if path.endswith('&page=1') else
                        [{**self.release(), 'id': 456}]}
            return {'workflow_runs': []}
        with patch.object(POOL, 'api', side_effect=response):
            self.assertEqual({run['id'] for run in POOL.discover({'repository': 'elide-dev/toolchain'})},
                             {123, 456})

    def test_watch_retires_finished_tag_grants_but_preserves_main(self):
        config = json.loads((ROOT / '.github/release-runners/pool.json').read_text())
        main = 'elide-dev/toolchain/.github/workflows/job.build.yml@refs/heads/main'
        old = 'elide-dev/toolchain/.github/workflows/job.build.yml@refs/tags/v2026.11.6'
        new = 'elide-dev/toolchain/.github/workflows/job.build.yml@refs/tags/v2027.1.0'
        group = {'visibility': 'selected', 'restricted_to_workflows': True,
                 'selected_workflows': [main, old]}
        with patch.object(POOL, 'api', side_effect=[group, {'repositories': [
                {'full_name': config['repository']}]}]), patch.object(POOL.subprocess, 'run') as update:
            POOL.reconcile_access(config, {new}, prune=True)
            self.assertEqual(json.loads(update.call_args.kwargs['input'])['selected_workflows'],
                             sorted([main, new]))

    def test_watch_provisions_successive_release_versions_without_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(config=ROOT / '.github/release-runners/pool.json',
                                      logs=Path(directory), run_id=None, watch=True)
            runs = [[self.release('v2026.11.7')], [], [self.release('v2027.1.0')]]
            jobs = {'jobs': [{'status': 'queued', 'labels': ['linux-amd64-toolchain-release']}]}
            with patch.object(POOL, 'discover', side_effect=runs), \
                    patch.object(POOL, 'authorize', return_value={'approved-ref'}), \
                    patch.object(POOL, 'reconcile_access') as access, \
                    patch.object(POOL, 'api', return_value=jobs), \
                    patch.object(POOL.subprocess, 'Popen') as spawn, \
                    patch.object(POOL.time, 'sleep', side_effect=[None, None, KeyboardInterrupt]):
                spawn.return_value.poll.return_value = 0
                spawn.return_value.returncode = 0
                with self.assertRaises(KeyboardInterrupt):
                    POOL.run(args)
                self.assertEqual(spawn.call_count, 2)
                self.assertEqual(access.call_count, 3)

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
