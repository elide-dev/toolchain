# shellcheck shell=bash
# zlib-ng in zlib-compat mode (installs libz.a and zlib.h).
build_zlib_ng() {
  local t="$1" prefix="$2" src
  src="$(stage_source zlib-ng "$t")"
  (
    cd "$src" || exit 1
    target_env "$t" "$prefix"
    ./configure --prefix="$prefix" --static --zlib-compat
    make -j"$JOBS"
    make install
  )
}
