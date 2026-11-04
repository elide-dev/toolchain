#!/usr/bin/env python3
"""Qualify packaged BOLT against live range and expression-reference controls."""
import argparse
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bin", type=Path)
    parser.add_argument("fixtures", type=Path)
    parser.add_argument("--clang", type=Path)
    parser.add_argument("--lld", type=Path)
    args = parser.parse_args()
    clang = args.clang or args.bin / "clang"
    lld = args.lld or args.bin / "ld.lld"
    bolt = args.bin / "llvm-bolt"
    dump = args.bin / "llvm-dwarfdump"
    with tempfile.TemporaryDirectory(prefix="bolt-debug-quality-") as temporary:
        directory = Path(temporary)
        for fixture, constant in [("dwarf-high-pc-forms.s", False),
                                  ("dwarf-high-pc-forms.s", True),
                                  ("dwarf-loclist-type-references.s", False)]:
            image = directory / (fixture + str(constant))
            command = [str(clang), "--target=x86_64-unknown-linux-gnu", "-nostdlib", "-no-pie",
                       "-fuse-ld=" + str(lld), str(args.fixtures / fixture), "-Wl,-q", "-o", str(image)]
            if constant:
                command.append("-Wa,--defsym,OFFSET_FORM=1")
            subprocess.run(command, check=True)
            subprocess.run([str(dump), "--verify", str(image)], check=True)
            for skip in [True, False]:
                output = directory / (image.name + str(skip) + ".bolt")
                command = [str(bolt), str(image), "-o", str(output), "--update-debug-sections",
                           "--cu-processing-batch-size=1", "--debug-thread-count=1"]
                command += ["--skip-funcs=main"] if skip else ["--reorder-blocks=ext-tsp", "--split-functions"]
                subprocess.run(command, check=True)
                subprocess.run([str(dump), "--verify", str(output)], check=True)
                if fixture == "dwarf-high-pc-forms.s":
                    info = subprocess.check_output([str(dump), "--debug-info", "--show-form", str(output)], text=True)
                    form = "DW_FORM_data8" if constant else "DW_FORM_addr"
                    if info.count("DW_AT_high_pc [" + form + "]") != 2:
                        raise RuntimeError("BOLT did not retain both subprogram/inline high_pc forms")
        print("Packaged BOLT preserves absolute/constant ranges and standard/GNU location references")


if __name__ == "__main__":
    main()
