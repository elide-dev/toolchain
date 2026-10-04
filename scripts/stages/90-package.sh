# shellcheck shell=bash
# Stage 90: finalize the bundle (front-ends, helper, metadata, relocatable sysroots, stripped
# tools) and write the archive, checksum and SBOM to $DIST_DIR.

stage_main() {
  local name archive meta="$BUNDLE_DIR/share/elide-toolchain" t
  install_frontends "$BUNDLE_DIR"
  install -m 0755 "$ROOT_DIR/src/elide-toolchain" "$BUNDLE_DIR/bin/elide-toolchain"
  mkdir -p "$meta"
  printf '%s\n' "$TOOLCHAIN_VERSION" > "$meta/VERSION"
  for t in $ALL_TARGETS; do relocate_prefix "$t"; done
  ENABLED_COMPONENTS="$(enabled_components | xargs)" python3 "$ROOT_DIR/scripts/gen-manifest.py" manifest > "$meta/manifest.json"
  ENABLED_COMPONENTS="$(enabled_components | xargs)" python3 "$ROOT_DIR/scripts/gen-manifest.py" sbom > "$meta/sbom.cdx.json"
  strip_tools

  name="$TOOLCHAIN_NAME-$TOOLCHAIN_VERSION-$HOST_OS-$HOST_ARCH"
  archive="$DIST_DIR/$name.tar.xz"
  mkdir -p "$DIST_DIR"
  rm -f "$archive" "$archive.sha256"
  XZ_OPT="-T0 -9" tar -C "$OUT_DIR" -cJf "$archive" "$TOOLCHAIN_NAME"
  printf '%s  %s\n' "$(sha256_of "$archive")" "$name.tar.xz" > "$archive.sha256"
  cp "$meta/sbom.cdx.json" "$DIST_DIR/$name.sbom.cdx.json"
  log "wrote $archive"
}

# relocate_prefix TRIPLE — make a sysroot's metadata location-independent: .pc files use
# prefix=/usr (Linux, with PKG_CONFIG_SYSROOT_DIR) or ${pcfiledir} (macOS overlay); CMake
# package files use CMAKE_CURRENT_LIST_DIR; libtool .la files are removed.
relocate_prefix() {
  local t="$1" sysroot usr stage1_usr f up
  sysroot="$(sysroot_of "$t")"
  usr="$sysroot/usr"
  stage1_usr="$STAGE1_DIR/sysroot/$t/usr"
  find "$sysroot" -name '*.la' -delete
  while IFS= read -r f; do
    if [ "$(triple_os "$t")" = linux ]; then
      sed -i.bak -e "s#$usr#/usr#g" -e "s#$stage1_usr#/usr#g" "$f"
    else
      sed -i.bak -e "s#$usr#\${pcfiledir}/../..#g" "$f"
    fi
    rm -f "$f.bak"
  done < <(find "$sysroot" -name '*.pc')
  while IFS= read -r f; do
    up="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[2], os.path.dirname(sys.argv[1])))' "$f" "$usr")"
    sed -i.bak -e "s#$usr#\${CMAKE_CURRENT_LIST_DIR}/$up#g" -e "s#$stage1_usr#\${CMAKE_CURRENT_LIST_DIR}/$up#g" "$f"
    rm -f "$f.bak"
  done < <(grep -rlF -e "$usr" -e "$stage1_usr" --include='*.cmake' "$sysroot" || true)
  return 0
}

strip_tools() {
  local f s="$BUNDLE_DIR/bin/llvm-strip"
  for f in "$BUNDLE_DIR"/bin/*; do
    if [ ! -f "$f" ] || [ -L "$f" ]; then continue; fi
    if [ "$HOST_OS" = linux ]; then
      if is_elf "$f"; then "$s" --strip-unneeded "$f"; fi
    else
      "$s" -x "$f" 2>/dev/null || true
    fi
  done
  return 0
}
