# shellcheck shell=bash
# CMake helper for target code built with a toolchain's <triple>-clang and toolchain file.

CMAKE_BIN="${CMAKE_BIN:-cmake}"

toolchain_file() { printf '%s/share/elide-toolchain/cmake/%s.cmake\n' "$TOOLCHAIN_ROOT" "$1"; }

cmake_launcher_args() {
  if is_yes "${USE_SCCACHE:-no}" && command -v sccache >/dev/null 2>&1; then
    printf '%s\n' -DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache
  fi
  return 0
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
