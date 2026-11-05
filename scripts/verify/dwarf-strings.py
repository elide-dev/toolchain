#!/usr/bin/env python3
"""Check the packaged verifier accepts string suffixes and rejects corruption."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bin", type=Path)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--clang", type=Path)
    args = parser.parse_args()
    clang = args.clang or args.bin / "clang"
    dump = args.bin / "llvm-dwarfdump"
    cases = [(None, None), ("BAD_OFFSET", "beyond the bounds"),
             ("UNTERMINATED", "string is not null-terminated"),
             ("UNTERMINATED_ZERO", "string is not null-terminated"),
             ("EMPTY_STR", "beyond the bounds")]
    with tempfile.TemporaryDirectory(prefix="dwarf-strings-") as temporary:
        for define, error in cases:
            obj = Path(temporary) / ((define or "suffixes") + ".o")
            command = [str(clang), "--target=x86_64-unknown-linux-gnu", "-c",
                       str(args.fixture), "-o", str(obj)]
            if define:
                command.append("-Wa,--defsym," + define + "=1")
            subprocess.run(command, check=True)
            result = subprocess.run([str(dump), "--verify", str(obj)],
                                    text=True, capture_output=True)
            output = result.stdout + result.stderr
            if error:
                if result.returncode == 0 or error not in output:
                    raise RuntimeError(f"{define}: corrupt string table accepted: {output}")
            else:
                if result.returncode != 0:
                    raise RuntimeError("Valid suffix-merged strings rejected: " + output)
                info = subprocess.check_output([str(dump), "--debug-info", str(obj)], text=True)
                if 'DW_AT_name\t("int")' not in info:
                    raise RuntimeError("The indexed suffix did not resolve to int: " + info)
    print("Packaged DWARF verifier accepts suffix merging and rejects bounds/termination errors")


if __name__ == "__main__":
    main()
