#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"

[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }
tmp="$(mktemp -d)"
for t in $ALL_TARGETS; do
  for prefix in "$STAGE1_DIR" "$BUNDLE_DIR"; do
    rd="$prefix/lib/clang/$LLVM_MAJOR/lib/$t"
    for f in libclang_rt.builtins.a clang_rt.crtbegin.o clang_rt.crtend.o libclang_rt.profile.a; do assert_file "$rd/$f"; done
    for f in libc++.a libc++abi.a libunwind.a; do assert_file "$prefix/lib/$t/$f"; done
    assert_file "$prefix/include/$t/c++/v1/__config_site"
    assert_file "$prefix/include/c++/v1/vector"
  done
  rd="$BUNDLE_DIR/lib/clang/$LLVM_MAJOR/lib/$t"
  if memprof_supported "$t"; then
    for f in libclang_rt.memprof.a libclang_rt.memprof_cxx.a libclang_rt.memprof-preinit.a libclang_rt.memprof.so; do assert_file "$rd/$f"; done
  else
    assert_eq "$(find "$rd" -name 'libclang_rt.memprof*' | wc -l | tr -d ' ')" "0" "no memprof runtime for $t"
  fi
  site="$(cat "$STAGE1_DIR/include/$t/c++/v1/__config_site")"
  if [ "$(triple_libc "$t")" = musl ]; then
    assert_contains "$site" "_LIBCPP_HAS_MUSL_LIBC 1"; static=-static
  else
    assert_contains "$site" "_LIBCPP_HAS_MUSL_LIBC 0"; static=""
  fi
  # shellcheck disable=SC2086
  assert_ok "$STAGE1_DIR/bin/$t-clang" $static "$ROOT_DIR/tests/fixtures/hello.c" -o "$tmp/c-$t"
  assert_eq "$("$tmp/c-$t")" "hello from elide-toolchain" "C runs ($t)"
  # shellcheck disable=SC2086
  assert_ok "$STAGE1_DIR/bin/$t-clang++" $static "$ROOT_DIR/tests/fixtures/hello.cpp" -o "$tmp/cxx-$t"
  assert_eq "$("$tmp/cxx-$t")" "hello from elide-toolchain" "C++ exceptions+threads run ($t)"
done
rm -rf "$tmp"
finish
