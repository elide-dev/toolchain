# shellcheck shell=bash
# AWS-LC (libcrypto/libssl). Static (PIC) everywhere; shared libraries as well on Linux.
build_aws_lc() {
  local t="$1" prefix="$2" src shared
  local common=(-DBUILD_LIBSSL=ON -DBUILD_TOOL=OFF -DBUILD_TESTING=OFF -DDISABLE_GO=ON -DDISABLE_PERL=ON)
  src="$(stage_source aws-lc "$t")"
  cmake_target "$t" "$src" "$(component_build_dir aws-lc "$t")" "$prefix" "${common[@]}" \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  if [ "$(triple_os "$t")" = linux ]; then
    shared="$BUILD_DIR/components/$t/aws-lc/build-shared"
    fresh_dir "$shared"
    cmake_target "$t" "$src" "$shared" "$prefix" "${common[@]}" -DBUILD_SHARED_LIBS=ON
  fi
}
