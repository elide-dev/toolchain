# shellcheck shell=bash
# Snappy (static).
build_snappy() {
  local t="$1" prefix="$2" src
  src="$(stage_source snappy "$t")"
  cmake_target "$t" "$src" "$(component_build_dir snappy "$t")" "$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF -DSNAPPY_INSTALL=ON
}
