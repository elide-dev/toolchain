# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
import importlib.util
import io
from pathlib import Path
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("member", Path(__file__).with_name("fetch-artifact-member.py"))
member = importlib.util.module_from_spec(spec)
spec.loader.exec_module(member)


class RangeZipTests(unittest.TestCase):
    def test_selective_zip_reads_cross_block_boundaries_and_reject_truncation(self):
        output = io.BytesIO()
        wanted = b"qualified debug data" * 10000
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("unrelated/other.debug", b"not selected" * 10000)
            archive.writestr("exact/owned.debug", wanted)
        data = output.getvalue()
        reader = member.Artifact.__new__(member.Artifact)
        reader.position, reader.length, reader.cache, reader.block_size = 0, len(data), {}, 64
        requests = []
        def fetch(start, end):
            requests.append((start, end))
            return data[start:end + 1], {}
        reader.range = fetch
        with zipfile.ZipFile(reader) as archive:
            with archive.open("exact/owned.debug") as stream:
                self.assertEqual(stream.read(), wanted)
        self.assertTrue(requests)
        self.assertTrue(all(end - start < 64 for start, end in requests))
        reader.cache.clear()
        reader.position = 0
        reader.range = lambda start, end: (b"", {})
        with self.assertRaisesRegex(ValueError, "Truncated"):
            reader.read(1)


if __name__ == "__main__":
    unittest.main()
