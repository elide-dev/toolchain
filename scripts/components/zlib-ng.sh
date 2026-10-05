# shellcheck shell=bash
# zlib-ng in zlib-compat mode (installs libz.a and zlib.h).
build_zlib_ng() {
  local t="$1" prefix="$2" src
  src="$(stage_source zlib-ng "$t")"
  (
    cd "$src" || exit 1
    target_env "$t" "$prefix"
    ./configure --prefix="$prefix" --static --zlib-compat
    # zlib-ng's configure sets NOLTOFLAG=-fno-lto for the per-ISA SIMD objects; clear it so every
    # member carries LLVM bitcode (spec §3.3a). Clang keeps the per-function target features in IR.
    # On Darwin, configure also forces AR=libtool ARFLAGS=-o (Apple's libtool can't read LLVM 23
    # bitcode); pin the archiver to llvm-ar on every platform.
    make -j"$JOBS" NOLTOFLAG= AR="$AR" ARFLAGS=rcs RANLIB="$RANLIB"
    make install NOLTOFLAG= AR="$AR" ARFLAGS=rcs RANLIB="$RANLIB"
  )
}
