# shellcheck shell=bash
# libsqlite3elide: SQLite with the sqlite-jni shim (sqlite_* entry points behind Elide's Rust JNI
# layer, elide-tools/sqlite-jni) compiled into the amalgamation; the drop-in for sqlite-jni's
# release archives (lib/libsqlite3elide.a + include/{sqlite3.h,sqlite3ext.h,sqlite3jni.h}).
# Configure options follow sqlite-jni. Its SQLITE_* list never reached the compiler there (bare
# NAME=VALUE configure arguments; its shipped archive reports the defaults); here it goes in as
# -D, matching the compile options of upstream sqlite-jdbc's native library.
sqlite3elide_defines() {
  printf -- '-DSQLITE_%s\n' CORE=1 DEFAULT_FILE_PERMISSIONS=0666 DEFAULT_MEMSTATUS=0 \
    DISABLE_PAGECACHE_OVERFLOW_STATS=1 ENABLE_API_ARMOR=1 ENABLE_COLUMN_METADATA=1 \
    ENABLE_DBSTAT_VTAB=1 ENABLE_FTS3=1 ENABLE_FTS3_PARENTHESIS=1 ENABLE_FTS5=1 \
    ENABLE_LOAD_EXTENSION=1 ENABLE_RTREE=1 ENABLE_STAT4=1 HAVE_ISNAN=1 MAX_ATTACHED=25 \
    MAX_COLUMN=32767 MAX_FUNCTION_ARG=127 MAX_LENGTH=2147483647 MAX_MMAP_SIZE=1099511627776 \
    MAX_PAGE_COUNT=4294967294 MAX_SQL_LENGTH=1073741824 MAX_VARIABLE_NUMBER=250000 THREADSAFE=1 \
    GVM_STATIC=1
}

# fetch_sqlite3elide_inputs DIR — the pinned shim sources and JNI headers, copied into DIR.
fetch_sqlite3elide_inputs() {
  local dir="$1" c="$CACHE_DIR/sqlite3elide" jni="https://raw.githubusercontent.com/elide-tools/sqlite-jni/$SQLITE_JNI_REV/jni"
  local jdk="https://raw.githubusercontent.com/openjdk/jdk/$JNI_HEADERS_TAG/src/java.base"
  fetch_pinned "$jni/sqlite3jni.c" "$SQLITE_JNI_C_SHA256" "$c/$SQLITE_JNI_REV/sqlite3jni.c"
  fetch_pinned "$jni/sqlite3jni.h" "$SQLITE_JNI_H_SHA256" "$c/$SQLITE_JNI_REV/sqlite3jni.h"
  fetch_pinned "$jdk/share/native/include/jni.h" "$JNI_H_SHA256" "$c/$JNI_HEADERS_TAG/jni.h"
  fetch_pinned "$jdk/unix/native/include/jni_md.h" "$JNI_MD_H_SHA256" "$c/$JNI_HEADERS_TAG/jni_md.h"
  cp "$c/$SQLITE_JNI_REV/sqlite3jni.c" "$c/$SQLITE_JNI_REV/sqlite3jni.h" \
    "$c/$JNI_HEADERS_TAG/jni.h" "$c/$JNI_HEADERS_TAG/jni_md.h" "$dir/"
}

build_sqlite3elide() {
  local t="$1" prefix="$2" src defs=()
  src="$(stage_source sqlite "$t")"
  fetch_sqlite3elide_inputs "$src"
  mapfile -t defs < <(sqlite3elide_defines)
  (
    cd "$src" || exit 1
    target_env "$t" "$prefix"
    # -w as upstream: SQLite and the shim are not built for this profile's warning set.
    CFLAGS="$CFLAGS -w -I$src ${defs[*]}"
    export CFLAGS
    ./configure --prefix="$prefix" --enable-all --disable-debug --enable-static --disable-shared \
      --column-metadata --geopoly --memsys5 --scanstatus --update-limit --with-tempstore=yes \
      --amalgamation-extra-src=sqlite3jni.c --disable-math --disable-tcl
    make -j"$JOBS" libsqlite3.a
  )
  mkdir -p "$prefix/lib/pkgconfig" "$prefix/include"
  cp "$src/libsqlite3.a" "$prefix/lib/libsqlite3elide.a"
  cp "$src/sqlite3.h" "$src/sqlite3ext.h" "$src/sqlite3jni.h" "$prefix/include/"
  cat > "$prefix/lib/pkgconfig/sqlite3elide.pc" <<PC
prefix=$prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: sqlite3elide
Description: SQLite $SQLITE_VERSION with the sqlite-jni shim (Elide)
Version: $SQLITE_VERSION
Libs: -L\${libdir} -lsqlite3elide -lm
Cflags: -I\${includedir}
PC
}
