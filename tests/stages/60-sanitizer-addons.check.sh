#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }
[ -n "$(all_variants)" ] || { echo "skip: BUILD_SANITIZER_VARIANTS is not yes"; exit 0; }

for t in $ALL_TARGETS; do
  for s in $(triple_variants "$t"); do
    d="$BUNDLE_DIR/lib/$t/$s" farm="$BUNDLE_DIR/sysroot/$t+$s" sym="$(san_symbol "$s")"
    for f in libc++.a libc++abi.a libc++experimental.a; do assert_file "$d/$f"; done
    assert_fails test -e "$d/libunwind.a"
    assert_contains "$("$BUNDLE_DIR/bin/llvm-nm" "$d/libc++.a" 2>/dev/null)" "$sym" "$t $s libc++ instrumented"
    assert_file "$BUNDLE_DIR/share/elide-toolchain/sanitizers/$t-$s.addon.cfg"
    for f in libz.a libzstd.a libmimalloc.a libelidealloc-shim.a; do
      [ -e "$(sysroot_of "$t")/usr/lib/$f" ] || continue
      assert_ok test -f "$farm/usr/lib/$f"
      assert_fails test -L "$farm/usr/lib/$f"
    done
    while IFS= read -r f; do
      assert_contains "$("$BUNDLE_DIR/bin/llvm-nm" "$f" 2>/dev/null)" "$sym" "$t $s ${f##*/} instrumented"
      assert_fails test -e "${f%.a}.so"
    done < <(find "$farm/usr/lib" -maxdepth 1 -name '*.a' -type f)
    assert_eq "$(find "$farm" -type l -lname '/*' | head -1)" "" "$t $s farm symlinks are relative"
    assert_eq "$(find -L "$farm" -maxdepth 3 -type l | head -1)" "" "$t $s farm symlinks resolve"
    assert_ok test -L "$farm/usr/include"
    if [ "$s" = asan ]; then
      assert_contains "$(cat "$BUNDLE_DIR/include/$t/asan/c++/v1/__config_site")" "_LIBCPP_INSTRUMENTED_WITH_ASAN 1"
    fi
  done
done
finish
