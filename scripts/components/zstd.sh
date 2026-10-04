# shellcheck shell=bash
# Zstandard (static library only).
build_zstd() {
  local t="$1" prefix="$2" src
  src="$(stage_source zstd "$t")"
  cmake_target "$t" "$src/build/cmake" "$(component_build_dir zstd "$t")" "$prefix" \
    -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF -DZSTD_MULTITHREAD_SUPPORT=ON
}
