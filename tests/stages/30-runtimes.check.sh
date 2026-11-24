#!/usr/bin/env bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
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
  # Shared C++ runtimes (gnu, bundle only) sit outside the default search path: the default
  # link stays static, and an explicit -L/-rpath to lib/<t>/shared runs against them.
  for prefix in "$STAGE1_DIR" "$BUNDLE_DIR"; do
    assert_eq "$(find "$prefix/lib/$t" -maxdepth 1 -name '*.so*' | wc -l | tr -d ' ')" "0" "no shared C++ runtime in $prefix/lib/$t"
  done
  assert_not_contains "$(needed_libs "$tmp/cxx-$t" | xargs)" "libc++" "default C++ link is static ($t)"
  if [ "$(triple_libc "$t")" = gnu ]; then
    sd="$BUNDLE_DIR/lib/$t/shared"
    for f in libc++.so libc++.so.1 libc++abi.so.1 libunwind.so.1; do assert_file "$sd/$f"; done
    assert_ok "$STAGE1_DIR/bin/$t-clang++" -L"$sd" -Wl,-rpath,"$sd" "$ROOT_DIR/tests/fixtures/hello.cpp" -o "$tmp/cxx-shared-$t"
    assert_contains "$(needed_libs "$tmp/cxx-shared-$t" | xargs)" "libc++.so.1" "shared C++ link uses libc++.so.1 ($t)"
    assert_eq "$("$tmp/cxx-shared-$t")" "hello from elide-toolchain" "C++ runs against shared runtimes ($t)"
  else
    assert_eq "$(find "$BUNDLE_DIR/lib/$t" -path '*/shared/*' | wc -l | tr -d ' ')" "0" "no shared C++ runtimes for $t"
  fi
done
rm -rf "$tmp"
finish
