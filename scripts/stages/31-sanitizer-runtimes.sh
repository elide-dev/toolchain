# shellcheck shell=bash
# Stage 31: compiler-rt sanitizer runtimes (and libFuzzer) for each Linux triple, per the matrix in
# versions.env (spec 2026-10-05 §3, §6.2). Runs after stage 30 because libFuzzer and the *_cxx
# runtimes compile and link against our libc++. Installed into both the stage-1 prefix and the
# bundle, like stage 30, together with include/sanitizer/*.h and share/*_ignorelist.txt. The
# runtimes stay native code (base spec §3.3a exemption for compiler-rt). darwin builds its
# sanitizer dylibs in stage 10.

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t
  [ -f "$STAGE1_DIR/lib/$(bundle_triple_for_libc gnu)/libc++.a" ] || die "libc++ missing; run 30-runtimes"
  apply_patches llvm "$ROOT_DIR/llvm"   # same patched compiler-rt tree as stage 30 (idempotent)
  for t in $ALL_TARGETS; do
    if [ -z "$(triple_sanitizers "$t")" ]; then log "sanitizers disabled for $t"; continue; fi
    build_sanitizer_runtimes "$t"
  done
}

build_sanitizer_runtimes() {
  local t="$1" b="$BUILD_DIR/runtimes/$1/sanitizers" args=() af lf fuzzer=OFF prefix
  mapfile -t args < <(san_runtimes_base_args "$t")
  af="--no-default-config $(arch_flags "$t")"
  lf="-rtlib=compiler-rt -unwindlib=libunwind -stdlib=libc++ -fuse-ld=lld"
  if triple_has_libfuzzer "$t"; then fuzzer=ON; fi
  fresh_dir "$b"
  # Only sanitizers and libFuzzer: every other compiler-rt part (builtins, crt, profile, memprof,
  # xray, …) belongs to stage 30 and must not be reinstalled from here.
  cmake -S "$ROOT_DIR/llvm/runtimes" -B "$b" "${args[@]}" \
    -DCMAKE_CXX_FLAGS="$af -stdlib=libc++" \
    -DCMAKE_EXE_LINKER_FLAGS="$lf" -DCMAKE_SHARED_LINKER_FLAGS="$lf" -DCMAKE_MODULE_LINKER_FLAGS="$lf" \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DCOMPILER_RT_BUILD_BUILTINS=OFF -DCOMPILER_RT_BUILD_CRT=OFF -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_ORC=OFF \
    -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
    -DCOMPILER_RT_BUILD_SANITIZERS=ON \
    -DCOMPILER_RT_SANITIZERS_TO_BUILD="$(crt_sanitizers_to_build "$t")" \
    -DCOMPILER_RT_BUILD_LIBFUZZER="$fuzzer" \
    -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
    -DSANITIZER_CXX_ABI=libc++ -DSANITIZER_TEST_CXX=libc++ \
    -DCOMPILER_RT_INCLUDE_TESTS=OFF
  cmake --build "$b" -j "$JOBS"
  for prefix in "$STAGE1_DIR" "$BUNDLE_DIR"; do
    cmake --install "$b" --prefix "$prefix"
    prune_sanitizer_runtimes "$prefix" "$t"
  done
}
