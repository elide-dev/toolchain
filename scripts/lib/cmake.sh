# shellcheck shell=bash
# CMake helper for target code built with a toolchain's <triple>-clang and toolchain file.

CMAKE_BIN="${CMAKE_BIN:-cmake}"

toolchain_file() { printf '%s/share/elide-toolchain/cmake/%s.cmake\n' "$TOOLCHAIN_ROOT" "$1"; }

# ccache_enabled — USE_CCACHE=yes|no|auto (default auto: on when ccache is on PATH). ccache must
# be on PATH either way; build.sh refuses USE_CCACHE=yes without it.
ccache_enabled() {
  case "${USE_CCACHE:-auto}" in
    auto) ;;
    *) is_yes "${USE_CCACHE}" || return 1 ;;
  esac
  command -v ccache >/dev/null 2>&1
}

# compiler_launcher — ccache, sccache (USE_SCCACHE=yes) or nothing; ccache wins when both are on.
compiler_launcher() {
  if ccache_enabled; then echo ccache
  elif is_yes "${USE_SCCACHE:-no}" && command -v sccache >/dev/null 2>&1; then echo sccache
  fi
  return 0
}

cmake_launcher_args() {
  local l
  l="$(compiler_launcher)"
  if [ -n "$l" ]; then
    printf '%s\n' "-DCMAKE_C_COMPILER_LAUNCHER=$l" "-DCMAKE_CXX_COMPILER_LAUNCHER=$l"
  fi
  return 0
}

# ccache_defaults — ccache settings for this build unless the caller set them. Paths under
# ROOT_DIR hash relative (BASEDIR, NOHASHDIR), compilers hash by content (stage-1 clang is rebuilt
# or re-extracted, so its mtime changes every build), and the generators of the clang cfg files
# that <triple>-clang auto-loads are hashed too, since ccache cannot see those cfg files.
ccache_defaults() {
  export CCACHE_BASEDIR="${CCACHE_BASEDIR:-$ROOT_DIR}"
  export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
  export CCACHE_NOHASHDIR="${CCACHE_NOHASHDIR:-1}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-50G}"
  export CCACHE_EXTRAFILES="${CCACHE_EXTRAFILES:-$ROOT_DIR/scripts/lib/frontends.sh:$ROOT_DIR/scripts/lib/sanitizers.sh}"
}

# llvm_link_jobs_args — cap concurrent links in an LLVM (or LLVM runtimes) CMake build.
llvm_link_jobs_args() { printf '%s\n' "-DLLVM_PARALLEL_LINK_JOBS=${LINK_JOBS:-2}"; }

# cmake_link_pool_args — the same cap for any other Ninja-generated CMake project.
cmake_link_pool_args() {
  printf '%s\n' "-DCMAKE_JOB_POOLS=link=${LINK_JOBS:-2}" -DCMAKE_JOB_POOL_LINK=link
}

# cmake_target TRIPLE SRC BUILD PREFIX [ARGS...] — configure, build and install.
cmake_target() {
  local t="$1" src="$2" build="$3" prefix="$4"
  shift 4
  local cflags ldflags exe_ldflags line
  cflags="$(target_cflags "$t")"
  ldflags="$(target_ldflags "$t")"
  exe_ldflags="$(target_exe_ldflags "$t")"
  local args=(
    -S "$src" -B "$build" -G Ninja
    -DCMAKE_TOOLCHAIN_FILE="$(toolchain_file "$t")"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_C_FLAGS="$cflags"
    -DCMAKE_CXX_FLAGS="$cflags"
    -DCMAKE_EXE_LINKER_FLAGS="$exe_ldflags"
    -DCMAKE_SHARED_LINKER_FLAGS="$ldflags"
    -DCMAKE_MODULE_LINKER_FLAGS="$ldflags"
  )
  if [ "$(triple_os "$t")" = darwin ]; then args+=(-DCMAKE_PREFIX_PATH="$prefix"); fi
  while IFS= read -r line; do
    if [ -n "$line" ]; then args+=("$line"); fi
  done < <(cmake_launcher_args)
  "$CMAKE_BIN" "${args[@]}" "$@"
  "$CMAKE_BIN" --build "$build" -j "$JOBS"
  "$CMAKE_BIN" --install "$build"
}
