# shellcheck shell=bash
# Load libraries and configuration; compute build directories. Sourced by build.sh
# (and by tests/stages/*.check.sh). Requires ROOT_DIR.
: "${ROOT_DIR:?ROOT_DIR must be set}"

# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/platform.sh
source "$ROOT_DIR/scripts/lib/platform.sh"
# shellcheck source=scripts/lib/flags.sh
source "$ROOT_DIR/scripts/lib/flags.sh"
# shellcheck source=scripts/lib/cmake.sh
source "$ROOT_DIR/scripts/lib/cmake.sh"
# shellcheck source=scripts/lib/frontends.sh
source "$ROOT_DIR/scripts/lib/frontends.sh"

_caller_toolchain_version="${TOOLCHAIN_VERSION:-}"
# shellcheck source=versions.env
source "$ROOT_DIR/versions.env"
if [ -n "$_caller_toolchain_version" ]; then TOOLCHAIN_VERSION="$_caller_toolchain_version"; fi
unset _caller_toolchain_version
if [ -f "$ROOT_DIR/vars.sh" ]; then
  # shellcheck source=vars.sh
  source "$ROOT_DIR/vars.sh"
fi

HOST_OS="${ELIDE_HOST_OS:-$(detect_host_os)}"
HOST_ARCH="${ELIDE_HOST_ARCH:-$(detect_host_arch)}"
OUT_DIR="${ELIDE_OUT_DIR:-$ROOT_DIR/out/$HOST_OS-$HOST_ARCH}"
BUNDLE_DIR="$OUT_DIR/$TOOLCHAIN_NAME"
STAGE1_DIR="$OUT_DIR/stage1"
BUILD_DIR="$OUT_DIR/build"
STAMPS_DIR="$OUT_DIR/stamps"
CACHE_DIR="${ELIDE_CACHE_DIR:-$ROOT_DIR/out/cache}"
DIST_DIR="${ELIDE_DIST_DIR:-$ROOT_DIR/dist}"
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-$BUNDLE_DIR}"
ALL_TARGETS="$(bundle_triples "$HOST_OS" "$HOST_ARCH")"
TARGETS="${TARGETS:-$ALL_TARGETS}"
JOBS="${JOBS:-$(cpu_count)}"
LLVM_MAJOR="${LLVM_VERSION%%.*}"
export ROOT_DIR HOST_OS HOST_ARCH OUT_DIR BUNDLE_DIR STAGE1_DIR BUILD_DIR STAMPS_DIR CACHE_DIR \
  DIST_DIR TOOLCHAIN_ROOT ALL_TARGETS TARGETS JOBS LLVM_MAJOR TOOLCHAIN_VERSION

if [ "$HOST_OS" = darwin ] && [ -z "${SDKROOT:-}" ] && command -v xcrun >/dev/null 2>&1; then
  SDKROOT="$(xcrun --show-sdk-path)"
  export SDKROOT
fi
