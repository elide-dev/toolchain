#!/usr/bin/env python3
"""Verify the packaged Mach-O linker retains nameless compilation units."""
import argparse
from pathlib import Path
import struct
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bin", type=Path)
    parser.add_argument("fixture", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="macho-compilation-units-") as temporary:
        obj = Path(temporary) / "nameless.o"
        output = Path(temporary) / "nameless.dylib"
        subprocess.run([str(args.bin / "clang"), "--target=arm64-apple-darwin", "-c",
                        str(args.fixture), "-o", str(obj)], check=True)
        subprocess.run([str(args.bin / "llvm-dwarfdump"), "--verify", str(obj)], check=True)
        subprocess.run([str(args.bin / "lld"), "-flavor", "darwin", "-arch", "arm64", "-dylib",
                        "-platform_version", "macos", "14", "14", str(obj), "-o", str(output)], check=True)
        data = output.read_bytes()
        assert struct.unpack_from("<I", data)[0] == 0xfeedfacf
        command_offset = 32
        records = []
        for _ in range(struct.unpack_from("<I", data, 16)[0]):
            command, size = struct.unpack_from("<II", data, command_offset)
            if command == 2:  # LC_SYMTAB
                symoff, count, stroff, strsize = struct.unpack_from("<IIII", data, command_offset + 8)
                strings = data[stroff:stroff + strsize]
                for i in range(count):
                    index, kind = struct.unpack_from("<IB", data, symoff + i * 16)
                    name = strings[index:strings.index(b"\0", index)].decode()
                    records.append((kind, name))
            command_offset += size
        assert (0x64, str(obj)) in records, ("Missing N_SO object fallback", records)
        assert (0x66, str(obj)) in records, ("Missing N_OSO object reference", records)
    print("Packaged Mach-O linker retains valid nameless compilation units and their object references")


if __name__ == "__main__":
    main()
