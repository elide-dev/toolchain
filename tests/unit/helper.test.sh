#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"

T="$(mktemp -d)"
B="$T/with space/elide-toolchain"
mkdir -p "$B/bin" "$B/share/elide-toolchain/cmake"
cp "$ROOT_DIR/src/elide-toolchain" "$B/bin/elide-toolchain"
chmod +x "$B/bin/elide-toolchain"
touch "$B/bin/x86_64-unknown-linux-gnu.cfg" "$B/bin/x86_64-unknown-linux-musl.cfg"
echo 2026.10.0 > "$B/share/elide-toolchain/VERSION"
H="$B/bin/elide-toolchain"
root="$(cd "$B" && pwd -P)"

assert_eq "$("$H" home)" "$root"
assert_eq "$("$H" version)" "2026.10.0"
assert_eq "$("$H" targets | xargs)" "x86_64-unknown-linux-gnu x86_64-unknown-linux-musl"

mkdir -p "$T/elsewhere"; ln -s "$H" "$T/elsewhere/et"
assert_eq "$("$T/elsewhere/et" home)" "$root" "resolves through symlinks"

sh_out="$("$H" env)"
assert_contains "$sh_out" "export ELIDE_TOOLCHAIN_HOME='$root'"
assert_contains "$sh_out" "export PATH='$root/bin':\"\$PATH\""
assert_not_contains "$sh_out" "CC="

gnu="$("$H" env --target x86_64-unknown-linux-gnu)"
assert_contains "$gnu" "export CC='$root/bin/x86_64-unknown-linux-gnu-clang'"
assert_contains "$gnu" "export CXX='$root/bin/x86_64-unknown-linux-gnu-clang++'"
assert_contains "$gnu" "export PKG_CONFIG_SYSROOT_DIR='$root/sysroot/x86_64-unknown-linux-gnu'"
assert_contains "$gnu" "export CMAKE_TOOLCHAIN_FILE='$root/share/elide-toolchain/cmake/x86_64-unknown-linux-gnu.cmake'"
assert_contains "$gnu" "export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="
# the sh output must be eval-able even with spaces in the path
assert_eq "$(eval "$gnu"; printf '%s' "$CC")" "$root/bin/x86_64-unknown-linux-gnu-clang"

assert_contains "$("$H" env --target x86_64-unknown-linux-musl --static)" "export LDFLAGS='-static'"
assert_fails "$H" env --target x86_64-unknown-linux-gnu --static
assert_contains "$("$H" env --target x86_64-unknown-linux-gnu --static 2>&1 || true)" "only supported for musl"
assert_fails "$H" env --static
assert_fails "$H" env --target aarch64-unknown-linux-gnu
assert_fails "$H" env --format yaml
assert_fails "$H" frobnicate

json="$("$H" env --target x86_64-unknown-linux-musl --format json)"
assert_eq "$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["CC"].endswith("x86_64-unknown-linux-musl-clang"), "PATH" in d)')" "True False"
gh="$("$H" env --target x86_64-unknown-linux-musl --format github)"
assert_contains "$gh" "CC=$root/bin/x86_64-unknown-linux-musl-clang"
assert_not_contains "$gh" "export "

# flags: Propeller, DeduBB and MemProf consumer flags.
touch "$B/bin/arm64-apple-darwin.cfg"
f="$("$H" flags --target x86_64-unknown-linux-gnu memprof-use=/p/app.memprofdata)"
assert_contains "$f" "-fmemory-profile-use=/p/app.memprofdata"
assert_contains "$f" "-Wl,-mllvm,-supports-hot-cold-new"
assert_contains "$f" "-lelidealloc-shim -lmimalloc"
assert_contains "$f" "export ELIDE_RUSTFLAGS='-Clinker-plugin-lto"
assert_contains "$f" "-Clink-arg=-Wl,-mllvm,-supports-hot-cold-new"
assert_not_contains "$f" "export PATH="
assert_eq "$(eval "$f"; printf '%s' "$ELIDE_CFLAGS")" "-flto=thin -gmlt -fdebug-info-for-profiling -fmemory-profile-use=/p/app.memprofdata"
assert_contains "$("$H" flags --target x86_64-unknown-linux-musl memprof-use=/p/a)" "-lelidealloc-shim -static"
assert_contains "$("$H" flags --target x86_64-unknown-linux-gnu memprof-instrument)" "-fmemory-profile -gmlt"
assert_fails "$H" flags --target x86_64-unknown-linux-musl memprof-instrument
assert_contains "$("$H" flags --target x86_64-unknown-linux-musl memprof-instrument 2>&1 || true)" "x86_64-unknown-linux-gnu only"
b="$("$H" flags --target x86_64-unknown-linux-gnu propeller-baseline)"
assert_contains "$b" "-fbasic-block-address-map"
assert_contains "$b" "-Wl,--lto-basic-block-address-map"
u="$("$H" flags --target x86_64-unknown-linux-gnu propeller-use=/c/cc.txt,/c/ld.txt dedubb-apply=/d/x.txt)"
assert_contains "$u" "-Wl,--lto-basic-block-sections=/c/cc.txt"
assert_contains "$u" "-Wl,--symbol-ordering-file=/c/ld.txt"
assert_contains "$u" "-Wl,-mllvm,-dedubb-directives=/d/x.txt"
assert_not_contains "$u" "-fbasic-block-address-map"
d="$("$H" flags --target x86_64-unknown-linux-musl dedubb-apply=/d/x.txt)"
assert_contains "$d" "-Wl,--lto-basic-block-address-map"
assert_contains "$d" "-Wl,-mllvm,-dedubb-directives=/d/x.txt"
assert_fails "$H" flags --target arm64-apple-darwin propeller-baseline
assert_fails "$H" flags --target arm64-apple-darwin dedubb-apply=/d/x.txt
assert_contains "$("$H" flags --target arm64-apple-darwin memprof-use=/p/a)" "-lelidealloc-shim"
assert_fails "$H" flags --target x86_64-unknown-linux-gnu propeller-use=/only-one
assert_fails "$H" flags --target x86_64-unknown-linux-gnu frobnicate
assert_fails "$H" flags memprof-use=/p/a
fj="$("$H" flags --target x86_64-unknown-linux-gnu propeller-baseline --format json)"
assert_eq "$(printf '%s' "$fj" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(d))')" "['ELIDE_CFLAGS', 'ELIDE_CXXFLAGS', 'ELIDE_LDFLAGS', 'ELIDE_RUSTFLAGS']"

rm -rf "$T"
finish
