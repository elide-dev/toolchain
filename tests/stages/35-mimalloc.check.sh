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

  # libelidealloc-shim: files, frozen v1 ABI, backend, and the behaviour test.
  assert_file "$p/lib/libelidealloc-shim.a"
  assert_file "$p/include/elidealloc-shim.h"
  assert_file "$p/lib/pkgconfig/elidealloc-shim.pc"
  backend="$(sed -n 's/^backend=//p' "$p/lib/pkgconfig/elidealloc-shim.pc")"
  assert_eq "$backend" "$(elidealloc_backend "$t")" "shim backend ($t)"
  re="$STAGE1_DIR/bin/llvm-readelf"; [ -x "$re" ] || re="$BUNDLE_DIR/bin/llvm-readelf"
  tmp="$(mktemp -d)"
  ar="$STAGE1_DIR/bin/llvm-ar"; [ -x "$ar" ] || ar="$BUNDLE_DIR/bin/llvm-ar"
  (cd "$tmp" && "$ar" x "$p/lib/libelidealloc-shim.a")
  syms="$(for o in "$tmp"/*.o; do "$re" -sW "$o"; done \
    | awk '$5 == "GLOBAL" && $6 == "DEFAULT" && $7 != "UND" { print $8 }' | LC_ALL=C sort -u)"
  assert_eq "$syms" "$(cat "$ROOT_DIR/src/elidealloc-shim/abi-v1.symbols")" "shim exports exactly the frozen v1 ABI ($t)"
  if [ "$(triple_libc "$t")" = musl ]; then
    [ -e "$p/lib/libmimalloc.a" ] && _fail "musl sysroot must not carry a second mimalloc (libmimalloc.a)"
  fi
  if [ "$(triple_os "$t")" = linux ] || [ "$HOST_OS" = darwin ]; then
    cxx="$TOOLCHAIN_ROOT/bin/$t-clang++"; [ -x "$cxx" ] || cxx="$STAGE1_DIR/bin/$t-clang++"
    [ -x "$cxx" ] || cxx="$BUNDLE_DIR/bin/$t-clang++"
    extra=(); case "$(triple_libc "$t")" in gnu) extra=(-lmimalloc) ;; musl) extra=(-static) ;; esac
    if "$cxx" -O2 -I"$p/include" "$ROOT_DIR/tests/fixtures/elidealloc-shim-test.cc" -lelidealloc-shim "${extra[@]}" \
         -o "$tmp/shim-test" 2>"$tmp/err"; then
      assert_ok "$tmp/shim-test"
      assert_ok env ELIDEALLOC_DISABLE=1 "$tmp/shim-test" disabled
      assert_ok env ELIDEALLOC_HOT_MIN=200 "$tmp/shim-test" hotmin200
    else
      _fail "shim test build ($t): $(head -3 "$tmp/err")"
    fi
  fi
  rm -rf "$tmp"
done
finish
