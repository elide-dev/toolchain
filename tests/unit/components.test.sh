#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
T="$(mktemp -d)"
ELIDE_HOST_OS=linux ELIDE_HOST_ARCH=amd64 ELIDE_OUT_DIR="$ROOT_DIR/out/test-tmp/out"
export ELIDE_HOST_OS ELIDE_HOST_ARCH ELIDE_OUT_DIR
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"

assert_eq "$(component_var zlib-ng)" BUILD_ZLIB_NG
assert_eq "$(component_fn aws-lc)" build_aws_lc
BUILD_ZSTD=yes; assert_ok component_enabled zstd
BUILD_ZSTD=no;  assert_fails component_enabled zstd
BUILD_ZLIB=yes BUILD_ZLIB_NG=yes assert_fails check_component_conflicts
BUILD_ZLIB=no BUILD_ZLIB_NG=yes BUILD_OPENSSL=yes BUILD_AWS_LC=yes assert_fails check_component_conflicts
BUILD_ZLIB=no BUILD_ZLIB_NG=yes BUILD_OPENSSL=no BUILD_AWS_LC=yes BUILD_SQLCIPHER=no assert_ok check_component_conflicts
for c in "${COMPONENTS[@]}"; do
  assert_ok test -n "$(component_artifact "$c")"
done
assert_eq "$(component_link zstd)" "HAVE_ZSTD|-lzstd"
assert_eq "$(target_prefix x86_64-unknown-linux-gnu)" "$BUNDLE_DIR/sysroot/x86_64-unknown-linux-gnu/usr"

# stage_source: copy without .git, apply patches, never touch the original
mkdir -p "$T/src/demo" "$T/patches/demo"
printf 'v1\n' > "$T/src/demo/file.txt"
printf 'junk.o\n' > "$T/src/demo/.gitignore"
printf 'x\n' > "$T/src/demo/junk.o"
git -C "$T/src/demo" init -q
git -C "$T/src/demo" add file.txt .gitignore
git -C "$T/src/demo" -c user.name=t -c user.email=t@t commit -q -m init
cat > "$T/patches/demo/0001.patch" <<'EOP'
--- a/file.txt
+++ b/file.txt
@@ -1 +1 @@
-v1
+v2
EOP
d="$(COMPONENT_SRC_ROOT="$T/src" PATCHES_DIR="$T/patches" stage_source demo x86_64-unknown-linux-gnu)"
assert_eq "$(cat "$d/file.txt")" "v2"
assert_fails test -e "$d/.git"
assert_fails test -e "$d/junk.o"
assert_eq "$(cat "$T/src/demo/file.txt")" "v1" "original untouched"

# target_env
(
  TOOLCHAIN_ROOT=/tc
  target_env x86_64-unknown-linux-musl /p
  assert_eq "$CC" /tc/bin/x86_64-unknown-linux-musl-clang
  assert_eq "$AR" /tc/bin/llvm-ar
  assert_contains "$LDFLAGS" "-static"
  assert_eq "$PKG_CONFIG_LIBDIR" "/p/lib/pkgconfig:/p/share/pkgconfig"
  finish
) || FAILURES=$((FAILURES + 1))

assert_ok declare -F build_zlib_ng
assert_ok declare -F build_zstd

rm -rf "$T" "$ROOT_DIR/out/test-tmp"
finish
