# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Exercise DCO trailer parsing and commit-range enforcement with real Git commits."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/check-dco.py'
spec = importlib.util.spec_from_file_location('dco', SCRIPT)
dco = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dco)


class DCOTest(unittest.TestCase):
    def test_trailers(self):
        author = 'Contributor <contributor@example.org>'
        committer = 'Maintainer <maintainer@example.org>'
        for identity in (author, committer):
            self.assertTrue(dco.valid_signoff('Change\n\nSigned-off-by: ' + identity, author, committer))
        for message in ('Unsigned', 'Change\n\nSigned-off-by: Stranger <other@example.org>',
                        'Change\n\nSigned-off-by: Contributor <invalid>',
                        'Signed-off-by: ' + author + '\n\nBody after the alleged trailer'):
            self.assertFalse(dco.valid_signoff(message, author, committer))

    def test_dependency_metadata_is_not_a_patch_divider(self):
        author = 'dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>'
        committer = 'Maintainer <maintainer@example.org>'
        body = ('Update dependency\n\n---\nupdated-dependencies:\n'
                '- dependency-name: example\n...\n\n')
        self.assertFalse(dco.valid_signoff(
            body + 'Signed-off-by: dependabot[bot] <support@github.com>', author, committer))
        self.assertTrue(dco.valid_signoff(
            body + 'Signed-off-by: ' + committer, author, committer))
        self.assertFalse(dco.valid_signoff(
            body + 'Signed-off-by: Stranger <other@example.org>', author, committer))

    def test_range(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, 'GIT_AUTHOR_NAME': 'Contributor',
                   'GIT_AUTHOR_EMAIL': 'contributor@example.org',
                   'GIT_COMMITTER_NAME': 'Maintainer', 'GIT_COMMITTER_EMAIL': 'maintainer@example.org'}

            def git(*args):
                return subprocess.check_output(['git', *args], cwd=directory, env=env, text=True).strip()

            def commit(message):
                git('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', message)
                return git('rev-parse', 'HEAD')

            def check(base, head):
                return subprocess.run(['python3', str(SCRIPT), '--base', base, '--head', head],
                                      cwd=directory, env=env, capture_output=True).returncode

            git('init', '-q')
            base = commit('Historical unsigned commit')
            signed = commit('New change\n\nSigned-off-by: Maintainer <maintainer@example.org>')
            self.assertEqual(check(base, signed), 0)
            unsigned = commit('Unsigned new change')
            self.assertNotEqual(check(base, unsigned), 0)
            self.assertEqual(check(signed, signed), 0)
            self.assertNotEqual(check('0' * 40, signed), 0)
            self.assertNotEqual(check('main', signed), 0)
            self.assertNotEqual(check('f' * 40, signed), 0)

    def test_message_file(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, 'GIT_AUTHOR_NAME': 'Contributor',
                   'GIT_AUTHOR_EMAIL': 'contributor@example.org',
                   'GIT_COMMITTER_NAME': 'Maintainer', 'GIT_COMMITTER_EMAIL': 'maintainer@example.org'}
            subprocess.run(['git', 'init', '-q'], cwd=directory, env=env, check=True)
            message_file = Path(directory) / 'COMMIT_EDITMSG'

            def check(message):
                message_file.write_text(message)
                return subprocess.run(['python3', str(SCRIPT), '--message-file', str(message_file)],
                                      cwd=directory, env=env, capture_output=True).returncode

            comments = '\n# Please enter the commit message for your changes.\n# On branch main\n'
            self.assertEqual(check('Change\n\nSigned-off-by: Contributor <contributor@example.org>\n'), 0)
            self.assertEqual(check('Change\n\nSigned-off-by: Maintainer <maintainer@example.org>\n' + comments), 0)
            self.assertNotEqual(check('Change\n' + comments), 0)
            self.assertNotEqual(check('Change\n\nSigned-off-by: Stranger <other@example.org>\n'), 0)
            # `git commit -v`: a sign-off inside the diff below the scissors line does not count.
            verbose = ('Change\n' + comments + '# ------------------------ >8 ------------------------\n'
                       '+Signed-off-by: Contributor <contributor@example.org>\n')
            self.assertNotEqual(check(verbose), 0)
            self.assertEqual(check('Change\n\nSigned-off-by: Contributor <contributor@example.org>\n'
                                   + verbose.partition('\n')[2]), 0)
            # Concluding a merge adds no new work, as in the range check.
            (Path(directory) / '.git/MERGE_HEAD').write_text('0' * 40 + '\n')
            self.assertEqual(check("Merge branch 'topic'\n"), 0)


if __name__ == '__main__':
    unittest.main()
