# shellcheck shell=bash
# Stage 10. Linux: stage-1 clang/lld built with the host compiler (not shipped).
# macOS: the shipped LLVM (single stage), deployment target MACOS_MIN, with compiler-rt
# builtins + profile (mainline clang always links its own libclang_rt.osx.a).

host_cc()  { command -v clang   || command -v gcc; }
host_cxx() { command -v clang++ || command -v g++; }

llvm_common_args() {
  printf '%s\n' \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF -DCLANG_INCLUDE_TESTS=OFF -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_CURL=OFF -DLLVM_ENABLE_HTTPLIB=OFF -DLLVM_ENABLE_FFI=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_FORCE_VC_REPOSITORY=https://github.com/llvm/llvm-project.git
  llvm_link_jobs_args
  cmake_launcher_args
}

stage_main() {
  apply_patches llvm "$ROOT_DIR/llvm"
  if [ "$HOST_OS" = linux ]; then llvm_stage1_linux; else llvm_darwin; fi
}

llvm_stage1_linux() {
  local b="$BUILD_DIR/llvm-stage1" args=() lld=()
  mapfile -t args < <(llvm_common_args)
  if command -v ld.lld >/dev/null 2>&1; then lld=(-DLLVM_ENABLE_LLD=ON); fi
  fresh_dir "$b"
  rm -rf "$STAGE1_DIR"
  cmake -S "$ROOT_DIR/llvm/llvm" -B "$b" "${args[@]}" "${lld[@]}" \
    -DCMAKE_INSTALL_PREFIX="$STAGE1_DIR" \
    -DCMAKE_C_COMPILER="$(host_cc)" -DCMAKE_CXX_COMPILER="$(host_cxx)" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_ENABLE_ZLIB=OFF
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
  mkdir -p "$BUNDLE_DIR/sysroot"
  ln -sfn "$BUNDLE_DIR/sysroot" "$STAGE1_DIR/sysroot"
}

llvm_darwin() {
  local t cpu b="$BUILD_DIR/llvm" args=() san=OFF fuzz=OFF
  t="$ALL_TARGETS"
  # Sanitizer dylibs + libFuzzer (spec 2026-10-05 §6.3); matrix in versions.env.
  if [ -n "$(triple_sanitizers "$t")" ]; then san=ON; fi
  if triple_has_libfuzzer "$t"; then fuzz=ON; fi
  cpu="$(triple_cpu "$t")"
  mapfile -t args < <(llvm_common_args)
  fresh_dir "$b"
  cmake -S "$ROOT_DIR/llvm/llvm" -B "$b" "${args[@]}" \
    -DCMAKE_INSTALL_PREFIX="$BUNDLE_DIR" \
    -DCMAKE_C_COMPILER="$(xcrun -f clang)" -DCMAKE_CXX_COMPILER="$(xcrun -f clang++)" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_OSX_SYSROOT="$SDKROOT" \
    -DCMAKE_OSX_ARCHITECTURES="$cpu" \
    -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS_DARWIN" \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$t" \
    -DLLVM_ENABLE_ZLIB=ON \
    -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_PROFILE=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS="$san" -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_LIBFUZZER="$fuzz" \
    -DCOMPILER_RT_SANITIZERS_TO_BUILD="$(crt_sanitizers_to_build "$t")" \
    -DSANITIZER_MIN_OSX_VERSION="$MACOS_MIN" \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
    -DCOMPILER_RT_ENABLE_IOS=OFF -DCOMPILER_RT_ENABLE_WATCHOS=OFF -DCOMPILER_RT_ENABLE_TVOS=OFF \
    -DCOMPILER_RT_ENABLE_XROS=OFF \
    -DDARWIN_osx_ARCHS="$cpu" -DDARWIN_osx_BUILTIN_ARCHS="$cpu"
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
  install_frontends "$BUNDLE_DIR"
}
