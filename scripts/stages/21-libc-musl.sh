# shellcheck shell=bash
# Stage 21: musl phase 1 — static-only, native mallocng, built with stage-1 clang. Provides
# headers and crt objects for the runtimes build (stage 30); stage 35 rebuilds musl fully.
# --no-default-config: clang >= 16 auto-loads bin/<target>.cfg, which stage 30 installs into
# stage 1; a rerun must build bare, exactly as the first run did (spec §3.3).

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t sysroot build s="$STAGE1_DIR/bin"
  t="$(bundle_triple_for_libc musl)"
  sysroot="$(sysroot_of "$t")"
  build="$BUILD_DIR/musl-phase1"
  [ -x "$s/clang" ] || die "stage-1 clang missing; run 10-llvm-stage1"
  fresh_dir "$build"
  (
    cd "$build" || exit 1
    unset CFLAGS CXXFLAGS LDFLAGS CC
    "$ROOT_DIR/musl/configure" \
      CC="$s/clang" CFLAGS="--no-default-config --target=$t -O2 -fno-fast-math" \
      AR="$s/llvm-ar" RANLIB="$s/llvm-ranlib" \
      --prefix=/usr --syslibdir=/lib --disable-shared --with-malloc=mallocng
    make -j"$JOBS" AR="$s/llvm-ar" RANLIB="$s/llvm-ranlib" LIBCC=
    make install DESTDIR="$sysroot" AR="$s/llvm-ar" RANLIB="$s/llvm-ranlib"
  )
}
