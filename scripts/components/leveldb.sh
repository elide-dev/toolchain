# shellcheck shell=bash
# LevelDB (static).
build_leveldb() {
  local t="$1" prefix="$2" src
  src="$(stage_source leveldb "$t")"
  cmake_target "$t" "$src" "$(component_build_dir leveldb "$t")" "$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DLEVELDB_BUILD_TESTS=OFF -DLEVELDB_BUILD_BENCHMARKS=OFF -DLEVELDB_INSTALL=ON
}
