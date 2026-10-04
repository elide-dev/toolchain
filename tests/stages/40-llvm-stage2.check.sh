#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }
b="$BUNDLE_DIR/bin"
for f in clang clang++ ld.lld llvm-ar llvm-nm llvm-ranlib llvm-objcopy llvm-strip llvm-readelf \
         llvm-bolt perf2bolt merge-fdata llvm-profgen llvm-profdata llvm-dwarfdump llvm-dwp; do
  assert_file "$b/$f"
done
assert_fails test -e "$b/lldb"
assert_contains "$("$b/clang" --version)" "clang version $LLVM_VERSION"
for f in "$b/clang" "$b/ld.lld" "$b/llvm-bolt"; do
  assert_eq "$(glibc_floor_violations "$(readlink -f "$f")")" "" "$f within glibc floor"
  libs="$(needed_libs "$(readlink -f "$f")")"
  assert_not_contains "$libs" "libstdc++" "$f has no libstdc++"
  assert_not_contains "$libs" "libgcc_s" "$f has no libgcc_s"
  assert_not_contains "$libs" "libLLVM" "$f does not need libLLVM.so"
done
tmp="$(mktemp -d)"
t="$(bundle_triple_for_libc gnu)"
assert_ok "$b/$t-clang" -g -Wl,--compress-debug-sections=zstd "$ROOT_DIR/tests/fixtures/hello.c" -o "$tmp/z"
for t in $ALL_TARGETS; do
  static=""; [ "$(triple_libc "$t")" = musl ] && static=-static
  # shellcheck disable=SC2086
  assert_ok "$b/$t-clang++" $static "$ROOT_DIR/tests/fixtures/hello.cpp" -o "$tmp/cxx-$t"
  assert_eq "$("$tmp/cxx-$t")" "hello from elide-toolchain"
done
rm -rf "$tmp"
finish
