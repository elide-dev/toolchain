# shellcheck shell=bash
# Stage 95: verify the packaged archive (not the build tree): checksum, then every check in
# scripts/verify/checks.sh against a fresh extraction.

# shellcheck source=scripts/verify/checks.sh
source "$ROOT_DIR/scripts/verify/checks.sh"

stage_main() {
  local name archive
  name="$TOOLCHAIN_NAME-$TOOLCHAIN_VERSION-$HOST_OS-$HOST_ARCH"
  archive="$DIST_DIR/$name.tar.xz"
  [ -f "$archive" ] || die "missing $archive; run 90-package"
  [ "$(awk '{print $1}' "$archive.sha256")" = "$(sha256_of "$archive")" ] || die "checksum mismatch for $archive"
  export VERIFY_DIR="$OUT_DIR/verify"
  fresh_dir "$VERIFY_DIR"
  tar -C "$VERIFY_DIR" -xJf "$archive"
  run_all_checks "$VERIFY_DIR/$TOOLCHAIN_NAME"
}
