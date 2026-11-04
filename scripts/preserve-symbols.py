#!/usr/bin/env python3
"""Retain final tool/shared-library peers; static inputs keep their DWARF in the bundle."""

import importlib.util
import json
import os
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("preservation", root / "tools/symbol-coverage/preserve.py")
preservation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preservation)
bundle, symbols = Path(os.environ["BUNDLE_DIR"]), Path(os.environ["SYMBOLS_DIR"])
gaps = []
for path in sorted(bundle.rglob("*")):
    if not path.is_file() or path.is_symlink():
        continue
    module = preservation.inventory.native(path)
    if not module or module["kind"] != "module":
        continue
    shipped_tool = path.parent == bundle / "bin"
    if not shipped_tool and not module["dwarf"]:
        gaps.append({"path": str(path.relative_to(bundle)), "reason": "no embedded DWARF; copied/prebuilt provenance requires separate debug producer"})
        continue
    preservation.preserve(path, symbols, strip=shipped_tool,
                          stage="final link; before stage-90 stripping; no address rewrite")
symbols.mkdir(parents=True, exist_ok=True)
(symbols / "preservation-gaps.json").write_text(json.dumps(gaps, indent=2) + "\n")
