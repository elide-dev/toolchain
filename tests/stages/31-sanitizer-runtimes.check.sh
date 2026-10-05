#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }

for t in $ALL_TARGETS; do
  for prefix in "$STAGE1_DIR" "$BUNDLE_DIR"; do
    rd="$prefix/lib/clang/$LLVM_MAJOR/lib/$t"
    for s in $(triple_sanitizers "$t"); do
      for r in $(san_runtimes "$s"); do assert_file "$rd/libclang_rt.$r.a"; done
    done
    if triple_has_libfuzzer "$t"; then
      for r in $(san_runtimes fuzzer); do assert_file "$rd/libclang_rt.$r.a"; done
    fi
    # Stage 31 builds sanitizers only: stage 30's compiler-rt parts survive its install + prune.
    assert_file "$rd/libclang_rt.builtins.a"
    assert_file "$rd/libclang_rt.profile.a"
    if memprof_supported "$t"; then assert_file "$rd/libclang_rt.memprof.a"; assert_file "$rd/libclang_rt.memprof.so"; fi
    for r in stats ubsan_loop_detect dd dyndd; do assert_fails test -e "$rd/libclang_rt.$r.a"; done
    if [ "$(triple_libc "$t")" = musl ]; then
      assert_eq "$(find "$rd" -name 'libclang_rt.*' | grep -cE 'libclang_rt\.(asan|tsan|msan|lsan|hwasan)|\.so$')" "0" "musl: static UBSan only"
    fi
  done
done
for f in include/sanitizer/asan_interface.h include/sanitizer/msan_interface.h share/asan_ignorelist.txt; do
  assert_file "$BUNDLE_DIR/lib/clang/$LLVM_MAJOR/$f"
done
finish
