# shellcheck shell=bash
# Stage 20: glibc at GLIBC_FLOOR, from the glibc submodule (release/2.34/master), built with
# the host GCC (glibc 2.34 cannot be built with clang). Installed with slibdir=/usr/lib.

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t sysroot build cpu
  t="$(bundle_triple_for_libc gnu)"
  sysroot="$(sysroot_of "$t")"
  cpu="$(triple_cpu "$t")"
  build="$BUILD_DIR/glibc"
  [ -f "$sysroot/usr/include/linux/version.h" ] || die "kernel headers missing in $sysroot; run 00-sources"

  apply_patches glibc "$ROOT_DIR/glibc"
  fresh_dir "$build"
  (
    cd "$build" || exit 1
    unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS CC CXX
    # GCC 15 defaults to C23, which glibc < 2.39 does not build under; pin gnu11.
    # CXX=false: a real host C++ compiler leaks >2.34 libstdc++ symbols into links-dso-program.
    "$ROOT_DIR/glibc/configure" \
      CC=gcc CXX=false CFLAGS="-O2 -std=gnu11" \
      --prefix=/usr --libdir=/usr/lib --libexecdir=/usr/lib \
      libc_cv_slibdir=/usr/lib \
      --with-headers="$sysroot/usr/include" \
      --enable-kernel="$GLIBC_ENABLE_KERNEL" \
      --enable-stack-protector=strong --enable-bind-now \
      --disable-werror --disable-profile --without-selinux
    make -j"$JOBS"
    make install DESTDIR="$sysroot"
  )
  (cd "$ROOT_DIR/glibc" && git checkout -q .)   # leave the submodule pristine; patches live in src/patches
  ensure_loader_link "$sysroot" "$cpu"
  (cd "$sysroot" && find . -type f -o -type l | sed 's#^\./##' | sort) > "$OUT_DIR/glibc-files.txt"
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
