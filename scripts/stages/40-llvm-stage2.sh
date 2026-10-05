# shellcheck shell=bash
# Stage 40: the shipped LLVM, built by stage-1 clang (via the gnu cfg) against our glibc 2.34
# sysroot, with static libc++/libunwind/compiler-rt and no shared libLLVM/libclang, so the
# tools run on any glibc >= GLIBC_FLOOR host. lld gets zlib + zstd from stage 36.

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t s="$STAGE1_DIR/bin" b="$BUILD_DIR/llvm-stage2" deps="$OUT_DIR/llvm-deps" af launcher=()
  apply_patches llvm "$ROOT_DIR/llvm"
  t="$(bundle_triple_for_libc gnu)"
  af="$(arch_flags "$t")"
  [ -x "$s/$t-clang" ] || die "stage-1 front-ends missing; run 30-runtimes"
  [ -f "$deps/lib/libzstd.a" ] || die "llvm deps missing; run 36-llvm-deps"
  mapfile -t launcher < <(cmake_launcher_args)
  fresh_dir "$b"
  cmake -S "$ROOT_DIR/llvm/llvm" -B "$b" -G Ninja "${launcher[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$BUNDLE_DIR" \
    -DCMAKE_C_COMPILER="$s/$t-clang" -DCMAKE_CXX_COMPILER="$s/$t-clang++" -DCMAKE_ASM_COMPILER="$s/$t-clang" \
    -DCMAKE_AR="$s/llvm-ar" -DCMAKE_RANLIB="$s/llvm-ranlib" -DCMAKE_NM="$s/llvm-nm" \
    -DCMAKE_C_FLAGS="$af" -DCMAKE_CXX_FLAGS="$af" \
    -DCMAKE_PREFIX_PATH="$deps" \
    -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS_LINUX" \
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$t" \
    -DLLVM_ENABLE_LIBCXX=ON -DLLVM_STATIC_LINK_CXX_STDLIB=ON \
    -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF -DCLANG_LINK_CLANG_DYLIB=OFF \
    -DCLANG_TOOL_CLANG_SHLIB_BUILD=OFF \
    -DLLVM_ENABLE_LLD=ON \
    -DLLVM_ENABLE_ZLIB=FORCE_ON -DZLIB_ROOT="$deps" \
    -DLLVM_ENABLE_ZSTD=FORCE_ON -DLLVM_USE_STATIC_ZSTD=ON \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_CURL=OFF -DLLVM_ENABLE_HTTPLIB=OFF -DLLVM_ENABLE_FFI=OFF \
    -DLLVM_ENABLE_RTTI=ON -DLLVM_ENABLE_EH=ON \
    -DBOLT_ENABLE_RUNTIME=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF -DCLANG_INCLUDE_TESTS=OFF -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
    -DLLVM_FORCE_VC_REPOSITORY=https://github.com/llvm/llvm-project.git
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
  install_frontends "$BUNDLE_DIR"
}
