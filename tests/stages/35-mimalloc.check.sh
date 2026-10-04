#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"

nm="$STAGE1_DIR/bin/llvm-nm"; [ -x "$nm" ] || nm="$BUNDLE_DIR/bin/llvm-nm"
for t in $ALL_TARGETS; do
  p="$(target_prefix "$t")"
  assert_file "$p/include/mimalloc.h"
  case "$(triple_libc "$t")" in
    musl)
      assert_file "$p/lib/libc.so"
      ld="$(sysroot_of "$t")/$(musl_loader "$(triple_cpu "$t")")"
      assert_eq "$(readlink "$ld")" "../usr/lib/libc.so" "relative musl loader link"
      if is_yes "$MUSL_USE_MIMALLOC"; then
        assert_contains "$("$nm" "$p/lib/libc.a" 2>/dev/null | grep ' T mi_malloc$' || true)" "mi_malloc" "mimalloc inside libc.a"
      fi
      if is_yes "$MUSL_USE_LTO"; then
        tmp="$(mktemp -d)"
        member="$("$STAGE1_DIR/bin/llvm-ar" t "$p/lib/libc.a" | grep -m1 '^printf\.')"
        (cd "$tmp" && "$STAGE1_DIR/bin/llvm-ar" x "$p/lib/libc.a" "$member")
        sections="$("$STAGE1_DIR/bin/llvm-readelf" -S "$tmp/$member")"
        assert_contains "$sections" ".llvm.lto" "bitcode present (LTO)"
        assert_contains "$sections" ".text" "native code present (fat object)"
        rm -rf "$tmp"
      fi
      tmp="$(mktemp -d)"
      assert_ok "$STAGE1_DIR/bin/$t-clang" -static "$ROOT_DIR/tests/fixtures/malloc.c" -o "$tmp/h"
      if is_yes "$MUSL_USE_MIMALLOC"; then
        assert_contains "$(MIMALLOC_SHOW_STATS=1 "$tmp/h" 2>&1)" "heap waits" "binary uses mimalloc"
      fi
      rm -rf "$tmp"
      ;;
    gnu|darwin)
      assert_file "$p/lib/libmimalloc.a"
      ;;
  esac
done
finish
