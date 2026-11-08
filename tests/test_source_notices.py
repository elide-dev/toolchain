# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('notices', Path(__file__).resolve().parents[1] / 'scripts/source-notices.py')
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)


class SourceNoticesTest(unittest.TestCase):
    def test_shebang_is_preserved(self):
        text = notices.add_notice('#!/bin/sh\necho ok\n', '#')
        self.assertTrue(text.startswith('#!/bin/sh\n# Copyright'))
        self.assertTrue(text.endswith('echo ok\n'))

    def test_scope(self):
        for name in ('src/patches/upstream/change.patch', 'action/dist/main.js', 'action/bun.lock'):
            self.assertIsNone(notices.comment_for(name))
        self.assertEqual(notices.comment_for('src/elide-toolchain'), '#')
        self.assertEqual(notices.comment_for('src/elidealloc-shim/core.cc'), '//')
        self.assertEqual(notices.comment_for('action/main.ts'), '//')


if __name__ == '__main__':
    unittest.main()
