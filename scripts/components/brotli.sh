# shellcheck shell=bash
# Brotli (static libraries; no CLI).
build_brotli() {
  local t="$1" prefix="$2" src
  src="$(stage_source brotli "$t")"
  cmake_target "$t" "$src" "$(component_build_dir brotli "$t")" "$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DBROTLI_DISABLE_TESTS=ON -DBROTLI_BUILD_TOOLS=OFF
}
