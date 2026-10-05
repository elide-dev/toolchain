# shellcheck shell=bash
# Stage 45: llvm-propeller's generate_propeller_profiles (Propeller layout profiles and DeduBB
# directives), linked against the stage-2 LLVM build tree's static libraries with the stage-1
# gnu cfg compiler (glibc 2.34 sysroot, static libc++), so it meets the glibc floor like the
# rest of bin/. Third-party deps come from the stage-00 cache; no network. Linux only (Propeller
# and BB address maps are ELF-only).

stage_applies() { [ "$HOST_OS" = linux ] && is_yes "${BUILD_PROPELLER:-yes}"; }

stage_main() {
  local t s="$STAGE1_DIR/bin" b="$BUILD_DIR/propeller" deps="$OUT_DIR/llvm-deps" launcher=()
  t="$(bundle_triple_for_libc gnu)"
  require_cmd patch
  [ -f "$BUILD_DIR/llvm-stage2/lib/cmake/llvm/LLVMConfig.cmake" ] || die "stage-2 LLVM build tree missing; run 40-llvm-stage2"
  [ -d "$CACHE_DIR/propeller-deps" ] || die "propeller deps missing in $CACHE_DIR/propeller-deps; run 00-sources"
  [ -x "$s/$t-clang++" ] || die "stage-1 front-ends missing; run 30-runtimes"
  apply_patches llvm-propeller "$ROOT_DIR/llvm-propeller"
  # Not an LLVM build (LLVM_PARALLEL_LINK_JOBS is ignored): cap links with a Ninja job pool.
  mapfile -t launcher < <(cmake_launcher_args; cmake_link_pool_args)
  fresh_dir "$b"
  cmake -S "$ROOT_DIR/llvm-propeller" -B "$b" -G Ninja "${launcher[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$s/$t-clang" -DCMAKE_CXX_COMPILER="$s/$t-clang++" \
    -DCMAKE_AR="$s/llvm-ar" -DCMAKE_RANLIB="$s/llvm-ranlib" -DCMAKE_NM="$s/llvm-nm" \
    -DCMAKE_C_FLAGS="$(arch_flags "$t")" -DCMAKE_CXX_FLAGS="$(arch_flags "$t")" \
    -DCMAKE_EXE_LINKER_FLAGS="$deps/lib/libzstd.a $deps/lib/libz.a" \
    -DCMAKE_PREFIX_PATH="$deps" \
    -DLLVM_DIR="$BUILD_DIR/llvm-stage2/lib/cmake/llvm" \
    -DPROPELLER_DEPS_DIR="$CACHE_DIR/propeller-deps" \
    -DPROPELLER_QUIPPER_PATCHES="$ROOT_DIR/src/patches/llvm-propeller/quipper" \
    -DBUILD_TESTING=OFF \
    -Wno-dev
  cmake --build "$b" -j "$JOBS" --target generate_propeller_profiles
  install -m 0755 "$b/propeller/generate_propeller_profiles" "$BUNDLE_DIR/bin/generate_propeller_profiles"
}
