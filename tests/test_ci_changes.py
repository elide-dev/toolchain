# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Exercise complete diff classification, including rename and failure boundaries."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/ci-changes.py'
SPEC = importlib.util.spec_from_file_location('ci_changes', SCRIPT)
CI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CI)


class ClassificationTest(unittest.TestCase):
    def test_paths(self):
        self.assertFalse(CI.requires_full(['README.md', 'docs/design.MD']))
        self.assertFalse(CI.requires_full(['LICENSE', 'action/main.ts', '.github/workflows/on.push.yml']))
        for paths in ([], ['docs/tool.py'], ['README.md', 'build.sh'],
                      ['src/elide-toolchain'], ['llvm'], ['versions.env']):
            with self.subTest(paths=paths):
                self.assertTrue(CI.requires_full(paths))

    def test_real_git_history(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, text=True).strip()

            def commit():
                git('add', '.')
                git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                    '-c', 'commit.gpgsign=false', 'commit', '-qm', 'test')
                return git('rev-parse', 'HEAD')

            def classify(base, head):
                output = root / '.git' / 'classification-output'
                output.unlink(missing_ok=True)
                result = subprocess.run(
                    ['python3', str(SCRIPT)], cwd=root, capture_output=True,
                    env={**os.environ, 'DIFF_BASE': base, 'DIFF_HEAD': head,
                         'GITHUB_OUTPUT': str(output)},
                )
                return result.returncode, output.read_text() if output.exists() else ''

            git('init', '-q')
            (root / 'code.py').write_text('print("example")\n')
            initial = commit()
            (root / 'code.py').rename(root / 'example.md')
            renamed = commit()
            self.assertEqual(classify(initial, renamed), (0, 'full=true\n'))
            (root / 'a\nfile.md').write_text('documentation\n')
            docs = commit()
            self.assertEqual(classify(renamed, docs), (0, 'full=false\n'))
            self.assertEqual(classify(docs, docs), (0, 'full=true\n'))
            self.assertEqual(classify('0' * 40, docs), (0, 'full=true\n'))
            self.assertEqual(classify('', ''), (0, 'full=true\n'))
            (root / 'native.c').write_text('int main(void) { return 0; }\n')
            native = commit()
            (root / 'native.c').write_text('// Copyright the Elide Toolchain contributors.\n'
                                         '// SPDX-License-Identifier: Apache-2.0 OR MIT\n'
                                         'int main(void) { return 0; }\n')
            notice = commit()
            self.assertEqual(classify(native, notice), (0, 'full=false\n'))
            (root / 'native.c').write_text((root / 'native.c').read_text().replace('return 0', 'return 1'))
            changed = commit()
            self.assertEqual(classify(notice, changed), (0, 'full=true\n'))
            (root / 'native.c').chmod(0o755)
            mode = commit()
            self.assertEqual(classify(changed, mode), (0, 'full=true\n'))
            code, output = classify('missing-revision', docs)
            self.assertNotEqual(code, 0)
            self.assertEqual(output, '')


if __name__ == '__main__':
    unittest.main()
