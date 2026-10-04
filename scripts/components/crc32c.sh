# shellcheck shell=bash
# Google CRC32C (static; no tests/benchmarks/glog, so no nested submodules are needed).
build_crc32c() {
  local t="$1" prefix="$2" src
  src="$(stage_source crc32c "$t")"
  cmake_target "$t" "$src" "$(component_build_dir crc32c "$t")" "$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DCRC32C_BUILD_TESTS=OFF -DCRC32C_BUILD_BENCHMARKS=OFF \
    -DCRC32C_USE_GLOG=OFF -DCRC32C_INSTALL=ON
}
