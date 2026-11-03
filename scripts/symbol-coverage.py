#!/usr/bin/env python3
"""Inventory the final main bundle AND sanitizer add-ons after stage 90."""

import importlib.util
import json
import os
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "symbol_coverage", root / "tools/symbol-coverage/collect.py"
)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)

archives = [str(Path(arg).resolve()) for arg in sys.argv[1:]]
if not archives:
    raise ValueError("require final archives")
bundle = Path(os.environ["BUNDLE_DIR"]) / "share/elide-toolchain/manifest.json"
component_configs = []
for cache in sorted(
    (Path(os.environ["BUNDLE_DIR"]).parent / "build").rglob("CMakeCache.txt")
):
    values = {}
    for line in cache.read_text(errors="replace").splitlines():
        if line.startswith("CMAKE_") and ":" in line and "=" in line:
            key = line.split(":", 1)[0]
            if key == "CMAKE_BUILD_TYPE" or any(
                key.startswith(prefix)
                for prefix in (
                    "CMAKE_C_FLAGS",
                    "CMAKE_CXX_FLAGS",
                    "CMAKE_ASM_FLAGS",
                    "CMAKE_EXE_LINKER_FLAGS",
                    "CMAKE_SHARED_LINKER_FLAGS",
                )
            ):
                values[key] = line.split("=", 1)[1]
    component_configs.append(
        {**collector.artifact(cache, str(cache)), "effectiveCMakeFlags": values}
    )
metadata = dict(
    release=os.environ["TOOLCHAIN_VERSION"],
    platform=os.environ["HOST_OS"],
    architecture=os.environ["HOST_ARCH"],
    configuration={
        "stage": "90-package",
        "componentFlags": "see hashed versions.env and bundle manifest; not inferred from Release",
        "cmakeCaches": component_configs,
    },
)
coverage = collector.collect(
    root, archives, [], "elide-dev/toolchain", metadata, ["versions.env", str(bundle)]
)
out = Path(archives[0]).with_suffix("").with_suffix(".symbol-coverage.json")
out.write_text(json.dumps(coverage, indent=2, sort_keys=True) + "\n")
print(f"Symbol coverage: {out}")
