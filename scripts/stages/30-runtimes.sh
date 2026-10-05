# shellcheck shell=bash
# Stage 30: LLVM runtimes for each Linux triple, cross-built by stage-1 clang with bare
# --target/--sysroot (NOT the cfg: its -rtlib=compiler-rt would break cmake probes before the
# builtins exist). Installed into both the stage-1 prefix (so stage-1 clang finds them in its
# own resource dir in later stages) and the bundle. --no-default-config keeps a rerun bare too:
# clang >= 16 auto-loads bin/<target>.cfg, and this stage installs those cfgs into stage 1.

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t
  [ -x "$STAGE1_DIR/bin/clang" ] || die "stage-1 clang missing; run 10-llvm-stage1"
  apply_patches llvm "$ROOT_DIR/llvm"
  for t in $ALL_TARGETS; do
    build_builtins "$t"
    build_cxx_runtimes "$t"
  done
  install_frontends "$STAGE1_DIR"
}

runtimes_common_args() {
  local t="$1" s="$STAGE1_DIR/bin" af
  af="--no-default-config $(arch_flags "$t")"
  printf '%s\n' \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$s/clang" -DCMAKE_CXX_COMPILER="$s/clang++" -DCMAKE_ASM_COMPILER="$s/clang" \
    -DCMAKE_C_COMPILER_TARGET="$t" -DCMAKE_CXX_COMPILER_TARGET="$t" -DCMAKE_ASM_COMPILER_TARGET="$t" \
    -DCMAKE_SYSROOT="$(sysroot_of "$t")" \
    -DCMAKE_AR="$s/llvm-ar" -DCMAKE_RANLIB="$s/llvm-ranlib" -DCMAKE_NM="$s/llvm-nm" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$af" -DCMAKE_CXX_FLAGS="$af" -DCMAKE_ASM_FLAGS="$af" \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
    -DCOMPILER_RT_INSTALL_PATH:STRING="lib/clang/$LLVM_MAJOR" \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_GWP_ASAN=OFF
  llvm_link_jobs_args
  cmake_launcher_args
}

install_both() {
  cmake --install "$1" --prefix "$STAGE1_DIR"
  cmake --install "$1" --prefix "$BUNDLE_DIR"
}

build_builtins() {
  local t="$1" b="$BUILD_DIR/runtimes/$1/builtins" args=()
  mapfile -t args < <(runtimes_common_args "$t")
  fresh_dir "$b"
  cmake -S "$ROOT_DIR/llvm/runtimes" -B "$b" "${args[@]}" \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_CRT=ON -DCOMPILER_RT_BUILD_PROFILE=OFF
  cmake --build "$b" -j "$JOBS"
  install_both "$b"
}

build_cxx_runtimes() {
  local t="$1" b="$BUILD_DIR/runtimes/$1/cxx" args=() musl=OFF
  if [ "$(triple_libc "$t")" = musl ]; then musl=ON; fi
  mapfile -t args < <(runtimes_common_args "$t")
  # MemProf runtime (x86_64 gnu only). Later -D options override runtimes_common_args'
  # MEMPROF=OFF. The always-built libclang_rt.memprof.so must link against our sysroot: no
  # libstdc++ (SANITIZER_CXX_ABI=none), and lld + compiler-rt crt instead of the host ld.
  local memprof_args=()
  if memprof_supported "$t"; then
    memprof_args=(-DCOMPILER_RT_BUILD_MEMPROF=ON -DSANITIZER_CXX_ABI=none
      "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld -rtlib=compiler-rt -unwindlib=none")
  fi
  fresh_dir "$b"
  cmake -S "$ROOT_DIR/llvm/runtimes" -B "$b" "${args[@]}" "${memprof_args[@]}" \
    -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx;compiler-rt" \
    -DCOMPILER_RT_BUILD_BUILTINS=OFF -DCOMPILER_RT_BUILD_CRT=OFF -DCOMPILER_RT_BUILD_PROFILE=ON \
    -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
    -DLIBUNWIND_USE_COMPILER_RT=ON -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_STATIC=ON \
    -DLIBCXXABI_USE_COMPILER_RT=ON -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
    -DLIBCXXABI_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_STATIC=ON \
    -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=ON \
    -DLIBCXX_USE_COMPILER_RT=ON -DLIBCXX_HAS_MUSL_LIBC="$musl" \
    -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_ENABLE_STATIC=ON \
    -DLIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY=ON \
    -DLIBCXX_HARDENING_MODE=fast \
    -DLIBUNWIND_ADDITIONAL_COMPILE_FLAGS="-flto=thin;-ffat-lto-objects" \
    -DLIBCXXABI_ADDITIONAL_COMPILE_FLAGS="-flto=thin;-ffat-lto-objects" \
    -DLIBCXX_ADDITIONAL_COMPILE_FLAGS="-flto=thin;-ffat-lto-objects" \
    -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
    -DLIBCXXABI_INCLUDE_TESTS=OFF -DLIBUNWIND_INCLUDE_TESTS=OFF \
    -DLIBCXX_INSTALL_INCLUDE_DIR=include/c++/v1 \
    -DLIBCXX_INSTALL_INCLUDE_TARGET_DIR="include/$t/c++/v1" \
    -DLIBCXX_INSTALL_LIBRARY_DIR="lib/$t" \
    -DLIBCXXABI_INSTALL_LIBRARY_DIR="lib/$t" \
    -DLIBUNWIND_INSTALL_LIBRARY_DIR="lib/$t"
  cmake --build "$b" -j "$JOBS"
  install_both "$b"
}
