# shellcheck shell=bash
# SQLite (static, all features).
build_sqlite() {
  local t="$1" prefix="$2" src
  src="$(stage_source sqlite "$t")"
  (
    cd "$src" || exit 1
    target_env "$t" "$prefix"
    ./configure --prefix="$prefix" --enable-all --enable-static --disable-shared \
      --enable-fts5 --enable-threadsafe --with-tempstore=yes --disable-tcl
    make -j"$JOBS"
    make install
  )
}
