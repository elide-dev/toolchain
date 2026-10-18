# shellcheck shell=bash
# Stage 20: glibc at GLIBC_FLOOR, from CentOS 7's prebuilt glibc RPMs (pinned in versions.env;
# 2.17 does not build with a current GCC or clang). Only libraries, crt objects, linker scripts
# and glibc's own headers are taken (the UAPI headers stay stage 00's), flattened into /usr/lib
# like a slibdir=/usr/lib build, with relative symlinks and /usr/lib linker-script paths.

stage_applies() { [ "$HOST_OS" = linux ]; }

GLIBC_RPMS="glibc glibc-devel glibc-headers glibc-static"

stage_main() {
  local t sysroot cpu raw staging pkg rpm
  t="$(bundle_triple_for_libc gnu)"
  sysroot="$(sysroot_of "$t")"
  cpu="$(triple_cpu "$t")"
  raw="$BUILD_DIR/glibc-rpms"
  staging="$BUILD_DIR/glibc-staging"
  [ -f "$sysroot/usr/include/linux/version.h" ] || die "kernel headers missing in $sysroot; run 00-sources"

  fresh_dir "$raw"
  fresh_dir "$staging"
  for pkg in $GLIBC_RPMS; do
    rpm="$(fetch_glibc_rpm "$pkg" "$cpu")"
    python3 -I "$ROOT_DIR/scripts/rpm-extract.py" "$rpm" "$raw"
  done
  flatten_glibc "$raw" "$staging"
  # The list comes from the staging tree, never the live sysroot: a rerun on a built tree would
  # otherwise list component archives and exempt them from the bitcode/floor checks.
  (cd "$staging" && find . \( -type f -o -type l \) | sed 's#^\./##' | sort) > "$OUT_DIR/glibc-files.txt"
  cp -a "$staging"/. "$sysroot"/
  ensure_loader_link "$sysroot" "$cpu"
  # After the snapshot, so it is checked as ours, not exempted as a glibc file: rustc's gnu std
  # always passes -lgcc_s; there is no libgcc in this toolchain, so redirect it to libunwind.
  printf 'INPUT(-lunwind)\n' > "$sysroot/usr/lib/libgcc_s.so"
}

# fetch_glibc_rpm PKG CPU — download (cached, sha256-checked) one pinned RPM; prints its path.
fetch_glibc_rpm() {
  local pkg="$1" cpu="$2" key base sha name
  key="${cpu^^}"
  base="GLIBC_RPM_BASE_$key"
  sha="GLIBC_RPM_SHA256_${pkg//-/_}"
  sha="${sha^^}_$key"
  if [ -z "${!base:-}" ] || [ -z "${!sha:-}" ]; then die "no glibc RPM pin for $pkg on $cpu"; fi
  name="$pkg-$GLIBC_VERSION-$GLIBC_RPM_RELEASE.$cpu.rpm"
  fetch_pinned "${!base}/$name" "${!sha}" "$CACHE_DIR/glibc-rpms/$name"
  printf '%s\n' "$CACHE_DIR/glibc-rpms/$name"
}

# flatten_glibc RAW STAGING — RAW's /lib, /lib64 and /usr/lib64 top-level entries into
# STAGING/usr/lib (symlinks re-pointed at the sibling basename), /usr/include as is.
flatten_glibc() {
  local raw="$1" staging="$2" d f name target
  mkdir -p "$staging/usr/lib"
  cp -a "$raw/usr/include" "$staging/usr/include"
  for d in lib lib64 usr/lib64; do
    [ -d "$raw/$d" ] || continue
    for f in "$raw/$d"/*; do
      name="$(basename "$f")"
      if [ -L "$f" ]; then
        target="$(basename "$(readlink "$f")")"
        ln -sfn "$target" "$staging/usr/lib/$name"
      elif [ -f "$f" ]; then
        cp -p "$f" "$staging/usr/lib/$name"
      fi
    done
  done
  for f in "$staging/usr/lib"/*; do
    if [ -L "$f" ] && [ ! -e "$f" ]; then die "dangling glibc link $(basename "$f") -> $(readlink "$f")"; fi
    if [ -f "$f" ] && ! is_elf "$f" && head -c 512 "$f" | grep -q 'GNU ld script'; then
      sed -i -E 's#(/usr)?/lib(64)?/#/usr/lib/#g' "$f"
    fi
  done
  # Like glibc >= 2.34, -lc also provides libpthread and libdl (as needed, ahead of libc as with
  # an explicit -lpthread): libc++abi/libunwind need them, and their .deplibs are lost under LTO.
  sed -i -E 's#^GROUP \( (/usr/lib/libc\.so\.6 )#GROUP ( AS_NEEDED ( /usr/lib/libpthread.so.0 /usr/lib/libdl.so.2 ) /usr/lib/libpthread_nonshared.a \1#' \
    "$staging/usr/lib/libc.so"
  grep -q 'libpthread.so.0' "$staging/usr/lib/libc.so" || die "could not extend libc.so with libpthread/libdl"
}

# ensure_loader_link SYSROOT CPU — the canonical PT_INTERP path must exist inside the sysroot
# so libc.so's AS_NEEDED(ld-linux…) resolves at link time. Relative, so the sysroot relocates.
ensure_loader_link() {
  local sysroot="$1" cpu="$2" loader name
  loader="$(glibc_loader "$cpu")"
  name="$(basename "$loader")"
  if [ -e "$sysroot/$loader" ] && [ "$(readlink "$sysroot/$loader" | cut -c1)" != "/" ]; then return 0; fi
  [ -e "$sysroot/usr/lib/$name" ] || die "glibc loader $name not installed in $sysroot/usr/lib"
  mkdir -p "$sysroot/$(dirname "$loader")"
  ln -sfn "../usr/lib/$name" "$sysroot/$loader"
}
