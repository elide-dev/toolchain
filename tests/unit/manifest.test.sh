#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
T="$(mktemp -d)"
ELIDE_HOST_OS=linux ELIDE_HOST_ARCH=amd64 ELIDE_OUT_DIR="$T/out"
export ELIDE_HOST_OS ELIDE_HOST_ARCH ELIDE_OUT_DIR
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
export ENABLED_COMPONENTS="zlib-ng zstd aws-lc"

m="$(python3 "$ROOT_DIR/scripts/gen-manifest.py" manifest)"
q() { printf '%s' "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
assert_eq "$(q 'd["name"]')" "elide-toolchain"
assert_eq "$(q 'd["version"]')" "$TOOLCHAIN_VERSION"
assert_eq "$(q 'd["host"]["glibcFloor"]')" "$GLIBC_FLOOR"
assert_eq "$(q 'd["llvmMajor"]')" "$LLVM_MAJOR"
assert_eq "$(q '" ".join(t["triple"] for t in d["targets"])')" "x86_64-unknown-linux-musl x86_64-unknown-linux-gnu"
assert_eq "$(q '[t["libcVersion"] for t in d["targets"] if t["libc"]=="glibc"][0]')" "$GLIBC_FLOOR"
assert_eq "$(q '" ".join(d["enabledComponents"])')" "zlib-ng zstd aws-lc"
assert_eq "$(q 'd["components"]["llvm"]["version"]')" "$LLVM_VERSION"
assert_eq "$(q 'd["features"]["memprof"]["runtimeTargets"]')" "['x86_64-unknown-linux-gnu']"
assert_eq "$(q 'd["features"]["elideallocShim"]["backends"]["x86_64-unknown-linux-gnu"]')" "mimalloc"
assert_eq "$(q 'd["features"]["elideallocShim"]["abi"]')" "1"
assert_eq "$(q 'd["features"]["propeller"]["tool"]')" "bin/generate_propeller_profiles"
assert_eq "$(q 'd["features"]["dedubb"]["codegen"]')" "True"
assert_eq "$(q 'd["features"]["fatLto"]["driverDefault"], d["features"]["fatLto"]["linkFlag"]')" "True -Wl,--fat-lto-objects"
assert_eq "$(q 'all("-linux-" in t for t in d["features"]["fatLto"]["targets"])')" "True"
assert_eq "$(BUILD_PROPELLER=no LLVM_DEDUBB=no MUSL_USE_MIMALLOC=no python3 "$ROOT_DIR/scripts/gen-manifest.py" manifest | python3 -c 'import json,sys; f=json.load(sys.stdin)["features"]; print("propeller" in f, "dedubb" in f, f["elideallocShim"]["backends"]["x86_64-unknown-linux-musl"])')" "False False forward"

s="$(python3 "$ROOT_DIR/scripts/gen-manifest.py" sbom)"
names="$(printf '%s' "$s" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["bomFormat"]=="CycloneDX" and d["specVersion"]=="1.6"; print(" ".join(sorted(c["name"] for c in d["components"])))')"
assert_eq "$names" "aws-lc clangd glibc llvm mimalloc musl zlib-ng zstd"
assert_eq "$(printf '%s' "$s" | python3 -c 'import json,sys; c=next(c for c in json.load(sys.stdin)["components"] if c["name"]=="clangd"); print(c["version"], c["licenses"][0]["expression"])')" "$LLVM_VERSION Apache-2.0 WITH LLVM-exception"

ELIDE_HOST_OS=darwin ELIDE_HOST_ARCH=arm64 ALL_TARGETS=arm64-apple-darwin HOST_OS=darwin HOST_ARCH=arm64 \
  python3 "$ROOT_DIR/scripts/gen-manifest.py" sbom | python3 -c 'import json,sys; n={c["name"] for c in json.load(sys.stdin)["components"]}; assert "glibc" not in n and "musl" not in n' \
  && ASSERTIONS=$((ASSERTIONS+1))
# shellcheck disable=SC2181
[ $? -eq 0 ] || _fail "darwin sbom excludes libcs"

rm -rf "$T"
finish
