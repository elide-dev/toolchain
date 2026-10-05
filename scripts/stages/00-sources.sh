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
  if [ "$HOST_OS" = linux ] && is_yes "${BUILD_PROPELLER:-yes}"; then fetch_propeller_deps; fi
}

check_submodules() {
  local missing
  missing="$(git -C "$ROOT_DIR" submodule status | awk '/^-/{print $2}' | xargs)"
  [ -z "$missing" ] || die "uninitialized submodules: $missing (run: git submodule update --init --depth=1 --recursive)"
  # Our own src/patches series are applied in place by later stages (glibc: 20; llvm: 10/30/40;
  # llvm-propeller: 45); take them back out first so only foreign modifications count as dirty.
  local c
  for c in glibc llvm llvm-propeller; do
    if [ -d "$ROOT_DIR/$c" ]; then unapply_patches "$c" "$ROOT_DIR/$c"; fi
  done
  # Component sources are copied from the submodule work trees, so modified or deleted tracked
  # files (e.g. leftovers of an old in-tree build) would leak into the bundle.
  local dirty
  # shellcheck disable=SC2016 # $sm_path is expanded by `git submodule foreach`, not this shell
  dirty="$(git -C "$ROOT_DIR" submodule foreach --quiet \
    'git diff --quiet --ignore-submodules HEAD -- . || echo "$sm_path"' | xargs)"
  [ -z "$dirty" ] || die "submodules with modified or deleted tracked files: $dirty (inspect, then: git -C <path> checkout -- .)"
  "$ROOT_DIR/scripts/check-versions.sh"
}

# fetch_pinned URL SHA256 DEST — download URL to DEST (once), verifying SHA256; a cached file
# with the wrong checksum is re-downloaded.
fetch_pinned() {
  local url="$1" sha="$2" dest="$3" actual
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && [ "$(sha256_of "$dest")" != "$sha" ]; then
    warn "cached $dest has wrong sha256; removing and re-downloading"
    rm -f "$dest"
  fi
  if [ ! -f "$dest" ]; then
    log "downloading $(basename "$dest")"
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
    actual="$(sha256_of "$dest")"
    [ "$actual" = "$sha" ] || die "sha256 mismatch for $dest: expected $sha, got $actual"
  fi
}

fetch_kernel() {
  local v="$LINUX_HEADERS_VERSION" tarball
  tarball="$CACHE_DIR/linux-$v.tar.xz"
  fetch_pinned "https://cdn.kernel.org/pub/linux/kernel/v${v%%.*}.x/linux-$v.tar.xz" \
    "$LINUX_HEADERS_SHA256" "$tarball"
  printf '%s\n' "$tarball"
}

# Third-party archives llvm-propeller fetches at configure time; stage 45 builds offline from
# this cache (src/patches/llvm-propeller/0003-offline-deps.patch).
fetch_propeller_deps() {
  local d="$CACHE_DIR/propeller-deps"
  fetch_pinned "https://github.com/abseil/abseil-cpp/archive/refs/tags/$PROPELLER_ABSL_VERSION.zip" \
    "$PROPELLER_ABSL_SHA256" "$d/abseil-cpp-$PROPELLER_ABSL_VERSION.zip"
  fetch_pinned "https://github.com/protocolbuffers/protobuf/releases/download/v$PROPELLER_PROTOBUF_VERSION/protobuf-$PROPELLER_PROTOBUF_VERSION.tar.gz" \
    "$PROPELLER_PROTOBUF_SHA256" "$d/protobuf-$PROPELLER_PROTOBUF_VERSION.tar.gz"
  fetch_pinned "https://github.com/google/googletest/archive/refs/tags/v$PROPELLER_GTEST_VERSION.zip" \
    "$PROPELLER_GTEST_SHA256" "$d/googletest-$PROPELLER_GTEST_VERSION.zip"
  fetch_pinned "https://github.com/google/perf_data_converter/archive/$PROPELLER_QUIPPER_REV.tar.gz" \
    "$PROPELLER_QUIPPER_SHA256" "$d/perf_data_converter-$PROPELLER_QUIPPER_REV.tar.gz"
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
