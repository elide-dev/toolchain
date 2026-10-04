# shellcheck shell=bash
# hiredis with TLS. Its install target also links the shared library, so use the
# non-static link flags even for musl.
build_hiredis() {
  local t="$1" prefix="$2" src
  src="$(stage_source hiredis "$t")"
  (
    cd "$src" || exit 1
    target_env "$t" "$prefix"
    LDFLAGS="$(target_ldflags "$t")"
    make -j"$JOBS" USE_SSL=1 CC="$CC" AR="$AR" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
      PREFIX="$prefix" OPTIMIZATION=-O3 static pkgconfig install
  )
}
