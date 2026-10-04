# shellcheck shell=bash
# OpenSSL (static). OPENSSLDIR points at the conventional system location, not the build tree.
openssl_target() {
  case "$1" in
    x86_64-unknown-linux-*) echo linux-x86_64 ;;
    aarch64-unknown-linux-*) echo linux-aarch64 ;;
    arm64-apple-darwin) echo darwin64-arm64-cc ;;
    x86_64-apple-darwin) echo darwin64-x86_64-cc ;;
    *) die "no OpenSSL target for $1" ;;
  esac
}

build_openssl() {
  local t="$1" prefix="$2" src
  src="$(stage_source openssl "$t")"
  (
    cd "$src" || exit 1
    target_env "$t" "$prefix"
    ./Configure "$(openssl_target "$t")" \
      no-shared no-tests no-docs no-comp no-afalgeng enable-ec_nistp_64_gcc_128 enable-tls1_3 threads \
      --prefix="$prefix" --libdir=lib --openssldir=/etc/ssl \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="$CFLAGS -fPIC" LDFLAGS="$LDFLAGS"
    make -j"$JOBS"
    make install_sw
  )
}
