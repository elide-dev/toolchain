# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# shellcheck shell=bash
# Stage 55: install the pinned official Rust toolchain under rust/ (rustc and cargo for the host,
# std for every bundle target), unmodified apart from dropping docs and shell completions. Rust
# links through the bundle's <triple>-clang (`elide-toolchain env`), never a host compiler.

stage_main() {
  local dest="$BUNDLE_DIR/rust" host t vv
  [ "$RUST_TOOLCHAIN" = "$(cat "$ROOT_DIR/rustversion")" ] \
    || die "versions.env RUST_TOOLCHAIN ($RUST_TOOLCHAIN) differs from rustversion ($(cat "$ROOT_DIR/rustversion"))"
  host="$(rust_host_triple "$HOST_OS" "$HOST_ARCH")"
  fresh_dir "$dest"
  fresh_dir "$BUNDLE_DIR/share/elide-toolchain/licenses/rust"
  install_rust_component rustc "$host"
  install_rust_component cargo "$host"
  for t in $ALL_TARGETS; do install_rust_component rust-std "$(rust_triple "$t")"; done
  vv="$("$dest/bin/rustc" -vV)"
  [ "$(sed -n 's/^release: //p' <<< "$vv")" = "$RUST_VERSION" ] || die "bundled rustc is not $RUST_VERSION: $vv"
  [ "$(sed -n 's/^commit-hash: //p' <<< "$vv")" = "$RUST_REV" ] || die "bundled rustc is not at $RUST_REV: $vv"
}

# install_rust_component COMPONENT RUST_TRIPLE — fetch the pinned archive and merge its payload
# (each directory named in its `components` file) into rust/; its license texts go to share/.
install_rust_component() {
  local component="$1" triple="$2" name sha tarball src part f licenses
  name="$component-${RUST_TOOLCHAIN%%-*}-$triple"
  sha="$(rust_pin "$component" "$triple" sha256)"
  [ -n "$sha" ] || die "no versions.env pin for Rust $component $triple"
  tarball="$CACHE_DIR/rust/$RUST_TOOLCHAIN/$name.tar.xz"
  fetch_pinned "$(rust_pin "$component" "$triple" url)" "$sha" "$tarball"
  fresh_dir "$BUILD_DIR/rust"
  tar -C "$BUILD_DIR/rust" -xJf "$tarball"
  src="$BUILD_DIR/rust/$name"
  while IFS= read -r part; do
    rsync -a --exclude=/manifest.in --exclude=/share --exclude=/etc "$src/$part/" "$BUNDLE_DIR/rust/"
  done < "$src/components"
  if [ "$component" != rust-std ]; then
    licenses="$BUNDLE_DIR/share/elide-toolchain/licenses/rust/$component"
    mkdir -p "$licenses"
    for f in COPYRIGHT LICENSE-APACHE LICENSE-MIT LICENSE-THIRD-PARTY; do
      [ ! -f "$src/$f" ] || install -m 0644 "$src/$f" "$licenses/$f"
    done
  fi
  rm -rf "$BUILD_DIR/rust"
}
