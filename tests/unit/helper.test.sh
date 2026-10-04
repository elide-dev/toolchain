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

rm -rf "$T"
finish
