# shellcheck shell=bash
# Cloudflare's accelerated zlib fork (alternative to zlib-ng; mutually exclusive).
build_zlib() {
  local t="$1" prefix="$2" src extra=()
  src="$(stage_source zlib "$t")"
  if [ "$(triple_cpu "$t")" = x86_64 ]; then extra=(--64); fi
  (
    cd "$src" || exit 1
    target_env "$t" "$prefix"
    ./configure --prefix="$prefix" --const --static "${extra[@]}"
    make -j"$JOBS" CC="$CC" AR="$AR"
    make install
  )
}
