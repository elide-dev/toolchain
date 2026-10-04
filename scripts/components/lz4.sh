# shellcheck shell=bash
# LZ4 (static library, headers, pkg-config).
build_lz4() {
  local t="$1" prefix="$2" src
  src="$(stage_source lz4 "$t")"
  (
    cd "$src" || exit 1
    target_env "$t" "$prefix"
    make -C lib -j"$JOBS" BUILD_SHARED=no PREFIX="$prefix" \
      CC="$CC" AR="$AR" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" install
  )
}
