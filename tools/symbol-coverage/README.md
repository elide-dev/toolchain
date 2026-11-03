# Symbol coverage evidence

Stage 90 inventories final main and sanitizer add-on archives after stripping. The wrapper retains upstream component revisions and available effective CMake flag/cache evidence.

Output: `<bundle>.symbol-coverage.json` beside the final archives, retained by existing dist/* artifact handling.

No claim is inferred from CMAKE_BUILD_TYPE=Release. Missing DWARF/identities and static-input downstream links remain explicit. Debug generation and stripping policy are unchanged.

The collector requires Python 3.11+ and only the standard library. It records exact distributed hashes and supported platform identities; it never uploads symbols or certifies completeness. PDB pairing, universal Mach-O slices, source decoding and guest/JIT capture remain unsupported or uncollected. Missing and unverified evidence must not be treated as a successful coverage gate.

The contract and tests are canonical in [elide-dev/debuginfo.dev](https://github.com/elide-dev/debuginfo.dev/tree/main/tools/symbol-coverage). `UPSTREAM.json` pins the source revision and hashes. Keep collect.py and manifest-v1.schema.json byte-identical to that revision; update the pin with them. The shared Docker helper, where present, is pinned too. Run the canonical collector tests and repository packaging checks after updating.
