#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
name="$TOOLCHAIN_NAME-$TOOLCHAIN_VERSION-$HOST_OS-$HOST_ARCH"
a="$DIST_DIR/$name.tar.xz"
assert_file "$a"
assert_file "$a.sha256"
assert_file "$DIST_DIR/$name.sbom.cdx.json"
assert_eq "$(awk '{print $1}' "$a.sha256")" "$(sha256_of "$a")" "checksum matches"
assert_eq "$(awk '{print $2}' "$a.sha256")" "$name.tar.xz" "checksum names the file"
listing="$(tar -tJf "$a")"
assert_eq "$(printf '%s\n' "$listing" | cut -d/ -f1 | sort -u)" "$TOOLCHAIN_NAME" "single top-level dir"
for f in bin/elide-toolchain share/elide-toolchain/manifest.json share/elide-toolchain/VERSION share/elide-toolchain/sbom.cdx.json; do
  assert_contains "$listing" "$TOOLCHAIN_NAME/$f"
done
for t in $ALL_TARGETS; do
  assert_contains "$listing" "$TOOLCHAIN_NAME/bin/$t.cfg"
  assert_contains "$listing" "$TOOLCHAIN_NAME/share/elide-toolchain/cmake/$t.cmake"
  leaks="$(grep -rlF "$BUNDLE_DIR" --include='*.pc' --include='*.cmake' "$(sysroot_of "$t")" || true)"
  assert_eq "$leaks" "" "no build paths in $t .pc/.cmake files"
  assert_eq "$(find "$(sysroot_of "$t")" -name '*.la' | head -1)" "" "no libtool archives"
done
finish
