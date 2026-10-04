# shellcheck shell=bash
# hiredis with TLS. Its install target also links the shared library, so use the
# non-static link flags even for musl. USE_WERROR=0: our clang flags newer warnings the
# project would otherwise fail on.
build_hiredis() {
  local t="$1" prefix="$2" src
  src="$(stage_source hiredis "$t")"
  (
    cd "$src" || exit 1
    target_env "$t" "$prefix"
    LDFLAGS="$(target_ldflags "$t")"
    CFLAGS="${CFLAGS//-fPIE/}" # install also links shared libs; -fPIE breaks them
    make -j"$JOBS" USE_SSL=1 USE_WERROR=0 CC="$CC" AR="$AR" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
      PREFIX="$prefix" OPTIMIZATION=-O3 static pkgconfig install
  )
}
