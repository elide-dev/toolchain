#!/usr/bin/env python3
"""Read one hashed member of this repository's GitHub artifact using HTTP ranges.

GitHub authorization is sent only to api.github.com. The temporary storage URL is
used without that header and is never printed. No symbol-service authentication
is implemented here; the workflow uses the existing shared action afterward.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import urllib.error
import urllib.request
import zipfile


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


class Artifact(io.RawIOBase):
    block_size = 8 * 1024 * 1024

    def __init__(self, repository, artifact_id):
        self.endpoint = f"https://api.github.com/repos/{repository}/actions/artifacts/{artifact_id}/zip"
        self.position = 0
        self.cache = {}
        self.refresh()
        data, headers = self.range(0, 0)
        if len(data) != 1:
            raise ValueError("Artifact storage did not support bounded HTTP ranges")
        self.length = int(headers["Content-Range"].rsplit("/", 1)[1])

    def refresh(self):
        request = urllib.request.Request(self.endpoint, headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"],
            "User-Agent": "debuginfo-symbol-artifact-reader/1", "Accept": "application/vnd.github+json"})
        try:
            urllib.request.build_opener(NoRedirect).open(request, timeout=60)
        except urllib.error.HTTPError as response:
            if response.code != 302:
                raise RuntimeError(f"GitHub artifact authorization returned HTTP {response.code}") from None
            self.url = response.headers["Location"]
            if not self.url.startswith("https://"):
                raise ValueError("Artifact download must use HTTPS")
            return
        raise ValueError("Expected a bounded GitHub artifact download redirect")

    def range(self, start, end):
        for attempt in range(2):
            request = urllib.request.Request(self.url, headers={"Range": f"bytes={start}-{end}",
                "User-Agent": "debuginfo-symbol-artifact-reader/1"})
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    if response.status != 206:
                        raise ValueError("Artifact storage ignored the bounded range request")
                    return response.read(end - start + 1), response.headers
            except urllib.error.HTTPError as response:
                if response.code == 403 and attempt == 0:
                    self.refresh()
                    continue
                raise RuntimeError(f"Artifact range read returned HTTP {response.code}") from None

    def seek(self, offset, whence=0):
        self.position = offset if whence == 0 else self.position + offset if whence == 1 else self.length + offset
        if self.position < 0:
            raise ValueError("Invalid ZIP seek")
        return self.position

    def tell(self):
        return self.position

    def read(self, count=-1):
        count = self.length - self.position if count < 0 else min(count, self.length - self.position)
        if count > 64 * 1024 * 1024:
            raise ValueError("Oversized artifact ZIP header/read request")
        result = bytearray()
        while count > 0:
            block = self.position // self.block_size
            if block not in self.cache:
                start = block * self.block_size
                data, _ = self.range(start, min(self.length - 1, start + self.block_size - 1))
                if len(self.cache) >= 2:
                    self.cache.pop(next(iter(self.cache)))
                self.cache[block] = data
            offset = self.position % self.block_size
            chunk = self.cache[block][offset:offset + count]
            if not chunk:
                raise ValueError("Truncated artifact range")
            result.extend(chunk)
            self.position += len(chunk)
            count -= len(chunk)
        return bytes(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=int, required=True)
    parser.add_argument("--member-suffix", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    source = Artifact(os.environ["GITHUB_REPOSITORY"], args.artifact)
    with zipfile.ZipFile(source) as archive:
        matches = [name for name in archive.namelist() if name.endswith(args.member_suffix)]
        if len(matches) != 1:
            raise ValueError("Expected one exact qualified native debug peer")
        checksum = hashlib.sha256()
        with archive.open(matches[0]) as original, args.out.open("wb") as output:
            while chunk := original.read(1024 * 1024):
                checksum.update(chunk)
                output.write(chunk)
        if checksum.hexdigest() != args.sha256:
            raise ValueError("Downloaded artifact member SHA-256 did not match qualification evidence")
    print(json.dumps({"artifactId": args.artifact, "member": matches[0], "sha256": args.sha256,
                      "bytes": args.out.stat().st_size}))


if __name__ == "__main__":
    main()
