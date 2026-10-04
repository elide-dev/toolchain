# shellcheck shell=bash
# SQLCipher (static), installed under <prefix>/sqlcipher so it never shadows SQLite.
build_sqlcipher() {
  local t="$1" prefix="$2" src
  src="$(stage_source sqlcipher "$t")"
  (
    cd "$src" || exit 1
    target_env "$t" "$prefix"
    CFLAGS="$CFLAGS -DSQLITE_HAS_CODEC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown"
    LDFLAGS="$LDFLAGS -lcrypto"
    export CFLAGS LDFLAGS
    ./configure --prefix="$prefix/sqlcipher" --enable-all --enable-static --disable-shared \
      --enable-fts5 --enable-threadsafe --with-tempstore=yes --disable-tcl
    make -j"$JOBS"
    make install
  )
}
