# shellcheck shell=bash
# Component registry and helpers shared by scripts/components/*.sh recipes.

# Build order: zlib before capnp; crypto before sqlcipher/capnp/hiredis.
COMPONENTS=(zlib zlib-ng zstd brotli snappy lz4 crc32c openssl aws-lc sqlite sqlcipher capnp hiredis leveldb)

component_var() { local v="${1//-/_}"; printf 'BUILD_%s\n' "${v^^}"; }
component_fn()  { printf 'build_%s\n' "${1//-/_}"; }
component_enabled() { local v; v="$(component_var "$1")"; is_yes "${!v:-no}"; }

enabled_components() {
  local c
  for c in "${COMPONENTS[@]}"; do
    if component_enabled "$c"; then echo "$c"; fi
  done
}

check_component_conflicts() {
  if component_enabled zlib && component_enabled zlib-ng; then
    die "BUILD_ZLIB and BUILD_ZLIB_NG both install libz; enable only one"
  fi
  if component_enabled openssl && component_enabled aws-lc; then
    die "BUILD_OPENSSL and BUILD_AWS_LC both install libcrypto/libssl; enable only one"
  fi
  if component_enabled sqlcipher && ! component_enabled openssl && ! component_enabled aws-lc; then
    die "BUILD_SQLCIPHER needs BUILD_OPENSSL or BUILD_AWS_LC"
  fi
  return 0
}

# component_artifact NAME — library proving NAME is installed, relative to the target prefix
# ('|'-separated alternatives).
component_artifact() {
  case "$1" in
    zlib|zlib-ng) echo lib/libz.a ;;
    zstd) echo lib/libzstd.a ;;
    brotli) echo lib/libbrotlidec.a ;;
    snappy) echo lib/libsnappy.a ;;
    lz4) echo lib/liblz4.a ;;
    crc32c) echo lib/libcrc32c.a ;;
    openssl|aws-lc) echo lib/libcrypto.a ;;
    sqlite) echo lib/libsqlite3.a ;;
    sqlcipher) echo "sqlcipher/lib/libsqlcipher.a|sqlcipher/lib/libsqlite3.a" ;;
    capnp) echo lib/libcapnp.a ;;
    hiredis) echo lib/libhiredis.a ;;
    leveldb) echo lib/libleveldb.a ;;
    *) die "unknown component: $1" ;;
  esac
}

# component_link NAME — "DEFINE|libs" for tests/fixtures/components.c, empty if not covered.
component_link() {
  case "$1" in
    zlib|zlib-ng) echo "HAVE_ZLIB|-lz" ;;
    zstd) echo "HAVE_ZSTD|-lzstd" ;;
    brotli) echo "HAVE_BROTLI|-lbrotlidec -lbrotlicommon" ;;
    snappy) echo "HAVE_SNAPPY|-lsnappy" ;;
    lz4) echo "HAVE_LZ4|-llz4" ;;
    crc32c) echo "HAVE_CRC32C|-lcrc32c" ;;
    openssl|aws-lc) echo "HAVE_CRYPTO|-lssl -lcrypto" ;;
    *) echo "" ;;
  esac
}

target_prefix() { printf '%s/usr\n' "$(sysroot_of "$1")"; }

# stage_source NAME TRIPLE — fresh per-triple copy of a submodule (patches applied), so
# in-tree builds never dirty the submodule and both libcs can build from the same sources.
stage_source() {
  local name="$1" t="$2" dir
  dir="$BUILD_DIR/components/$t/$name/src"
  fresh_dir "$dir"
  rsync -a --delete --exclude .git "${COMPONENT_SRC_ROOT:-$ROOT_DIR}/$name/" "$dir/"
  apply_patches "$name" "$dir" >&2
  printf '%s\n' "$dir"
}

component_build_dir() {
  local dir="$BUILD_DIR/components/$2/$1/build"
  fresh_dir "$dir"
  printf '%s\n' "$dir"
}

# target_env TRIPLE PREFIX — export compiler and flag variables for autotools/make recipes.
target_env() {
  local t="$1" prefix="$2" bin="$TOOLCHAIN_ROOT/bin"
  export CC="$bin/$t-clang" CXX="$bin/$t-clang++"
  export AR="$bin/llvm-ar" RANLIB="$bin/llvm-ranlib" NM="$bin/llvm-nm" STRIP="$bin/llvm-strip"
  CFLAGS="$(target_cflags "$t")"
  CXXFLAGS="$CFLAGS"
  LDFLAGS="$(target_exe_ldflags "$t")"
  export CFLAGS CXXFLAGS LDFLAGS
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
  unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR
  if [ "$(triple_os "$t")" = darwin ]; then export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"; fi
}

for _recipe in "$ROOT_DIR"/scripts/components/*.sh; do
  # shellcheck source=/dev/null
  [ -e "$_recipe" ] && source "$_recipe"
done
unset _recipe
