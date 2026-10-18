#!/usr/bin/env python3
"""Extract an RPM's payload (gzip or xz cpio newc) into DEST. Stdlib only.

Usage: rpm-extract.py RPM DEST
Only regular files, directories and symlinks are written; paths are confined to DEST.
"""

import gzip
import lzma
import os
import struct
import sys


def skip_header(f, pad):
    magic = f.read(8)
    if magic[:3] != b"\x8e\xad\xe8":
        sys.exit("rpm-extract: bad header magic")
    nindex, hsize = struct.unpack(">II", f.read(8))
    size = nindex * 16 + hsize
    if pad:
        size += (8 - size % 8) % 8
    f.seek(size, 1)


def payload(f):
    head = f.read(6)
    f.seek(-6, 1)
    if head.startswith(b"\x1f\x8b"):
        return gzip.GzipFile(fileobj=f)
    if head.startswith(b"\xfd7zXZ"):
        return lzma.LZMAFile(f)
    sys.exit("rpm-extract: unsupported payload compression")


def main(rpm, dest):
    dest = os.path.realpath(dest)
    with open(rpm, "rb") as f:
        if f.read(4) != b"\xed\xab\xee\xdb":
            sys.exit("rpm-extract: not an RPM")
        f.seek(96)
        skip_header(f, pad=True)
        skip_header(f, pad=False)
        cpio = payload(f)
        while True:
            hdr = cpio.read(110)
            if hdr[:6] != b"070701":
                sys.exit("rpm-extract: bad cpio header")
            fields = [int(hdr[6 + i * 8:14 + i * 8], 16) for i in range(13)]
            mode, filesize, namesize = fields[1], fields[6], fields[11]
            name = cpio.read(namesize)[:-1].decode()
            cpio.read((4 - (110 + namesize) % 4) % 4)
            data = cpio.read(filesize)
            cpio.read((4 - filesize % 4) % 4)
            if name == "TRAILER!!!":
                break
            rel = name[2:] if name.startswith("./") else name.lstrip("/")
            out = os.path.join(os.path.realpath(os.path.join(dest, os.path.dirname(rel))), os.path.basename(rel))
            if not out.startswith(dest + os.sep):
                sys.exit(f"rpm-extract: path escapes destination: {name}")
            kind = mode & 0o170000
            if kind == 0o040000:
                os.makedirs(out, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            if os.path.lexists(out):
                os.unlink(out)
            if kind == 0o120000:
                os.symlink(data.decode(), out)
            elif kind == 0o100000:
                with open(out, "wb") as o:
                    o.write(data)
                os.chmod(out, mode & 0o755)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
