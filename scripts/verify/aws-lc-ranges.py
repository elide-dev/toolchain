#!/usr/bin/env python3
"""Check live ELF function boundaries in the packaged AWS-LC archive."""
import argparse
import re
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--ar", required=True)
    parser.add_argument("--readelf", required=True)
    args = parser.parse_args()
    members = subprocess.check_output([args.ar, "t", str(args.archive)], text=True).splitlines()
    with tempfile.TemporaryDirectory(prefix="aws-lc-ranges-") as directory:
        for name in ("edwards25519_scalarmuldouble", "edwards25519_scalarmuldouble_alt"):
            matches = [member for member in members if re.search(r"(^|[-/])" + name + r"(?:\.S)?\.o$", member)]
            if len(matches) != 1:
                raise RuntimeError(f"Expected one {name} assembly member: {matches}")
            obj = Path(directory) / (name + ".o")
            obj.write_bytes(subprocess.check_output([args.ar, "p", str(args.archive), matches[0]]))
            rows = subprocess.check_output([args.readelf, "--symbols", "--wide", str(obj)], text=True)
            functions = {}
            for row in rows.splitlines():
                fields = row.split()
                if len(fields) == 8 and fields[3] == "FUNC":
                    functions[fields[7]] = (int(fields[1], 16), int(fields[2], 0))
            outers = [value for symbol, value in functions.items() if symbol.endswith(name) and not symbol.startswith("L")]
            helpers = [value for symbol, value in functions.items() if symbol.startswith("L" + name + "_")]
            if len(outers) != 1 or len(helpers) != 4:
                raise RuntimeError(f"Missing outer/helper functions in {matches[0]}: {functions}")
            start, size = outers[0]
            if size <= 0 or any(length <= 0 or start + size > address for address, length in helpers):
                raise RuntimeError(f"Outer function overlaps its local helpers in {matches[0]}: {functions}")
            print(f"{name}: outer range ends before all four helpers")


if __name__ == "__main__":
    main()
