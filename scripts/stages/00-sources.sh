# shellcheck shell=bash
# Stage 00: verify host tools and submodule pins; install Linux UAPI headers into each
# Linux sysroot from a pinned kernel tarball (never from the host's /usr/include).

stage_main() {
  if [ "$HOST_OS" = linux ]; then
    require_cmd cmake ninja python3 git curl xz make gcc g++ bison gawk rsync
  else
    require_cmd cmake ninja python3 git curl xcrun rsync
  fi
  check_submodules
  mkdir -p "$BUNDLE_DIR/sysroot"
  if [ "$HOST_OS" = linux ]; then install_kernel_headers; fi
}

check_submodules() {
  local missing
  missing="$(git -C "$ROOT_DIR" submodule status | awk '/^-/{print $2}' | xargs)"
  [ -z "$missing" ] || die "uninitialized submodules: $missing (run: git submodule update --init --depth=1 --recursive)"
  "$ROOT_DIR/scripts/check-versions.sh"
}

fetch_kernel() {
  local v="$LINUX_HEADERS_VERSION" tarball
  tarball="$CACHE_DIR/linux-$v.tar.xz"
  mkdir -p "$CACHE_DIR"
  if [ ! -f "$tarball" ]; then
    log "downloading linux-$v"
    curl -fsSL --retry 3 -o "$tarball.part" "https://cdn.kernel.org/pub/linux/kernel/v${v%%.*}.x/linux-$v.tar.xz"
    mv "$tarball.part" "$tarball"
  fi
  [ "$(sha256_of "$tarball")" = "$LINUX_HEADERS_SHA256" ] || die "sha256 mismatch for $tarball"
  printf '%s\n' "$tarball"
}

install_kernel_headers() {
  local tarball src t sysroot
  tarball="$(fetch_kernel)"
  fresh_dir "$BUILD_DIR/linux"
  tar -C "$BUILD_DIR/linux" -xJf "$tarball"
  src="$BUILD_DIR/linux/linux-$LINUX_HEADERS_VERSION"
  for t in $ALL_TARGETS; do
    sysroot="$(sysroot_of "$t")"
    mkdir -p "$sysroot/usr"
    make -C "$src" ARCH="$(kernel_arch "$(triple_cpu "$t")")" INSTALL_HDR_PATH="$sysroot/usr" headers_install
  done
}
