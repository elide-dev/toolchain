# shellcheck shell=bash
# Stage 60: sanitizer add-ons for the gnu triples (spec 2026-10-05 §4.2, §6.4). Per sanitizer:
# instrumented libc++/libc++abi (never libunwind), every enabled component rebuilt by its normal
# recipe with the sanitizer layer, a mimalloc forwarding shim, an instrumented libelidealloc-shim
# (forward backend), and a relative-symlink farm sysroot sysroot/<T>+<san>/ holding the
# instrumented archives. Off unless BUILD_SANITIZER_VARIANTS=yes.

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t s
  export TOOLCHAIN_ROOT="$BUNDLE_DIR"
  apply_patches llvm "$ROOT_DIR/llvm"   # the variant libc++ builds from the same patched tree as stage 30
  check_component_conflicts
  remove_stale_addons
  for t in $TARGETS; do
    for s in $(triple_variants "$t"); do
      log "sanitizer add-on $s -> $t"
      [ -f "$(san_cfg_dir "$BUNDLE_DIR")/$t-$s.cfg" ] || die "missing $s runtime cfg for $t; run 31-sanitizer-runtimes and 40-llvm-stage2"
      build_variant_cxx "$t" "$s"
      build_variant_components "$t" "$s"
      build_mimalloc_shim "$t" "$s"
      build_variant_elidealloc_shim "$t" "$s"
      assemble_variant_sysroot "$t" "$s"
      install_sanitizer_addon_frontends "$BUNDLE_DIR" "$t" "$s"
    done
  done
  if [ -z "$(all_variants)" ]; then log "no sanitizer add-ons requested (BUILD_SANITIZER_VARIANTS=${BUILD_SANITIZER_VARIANTS:-no})"; fi
}

# remove_stale_addons — drop add-on trees from earlier runs that this configuration does not
# build, so stage 90 never ships them inside the main archive.
remove_stale_addons() {
  local t s sd
  sd="$(san_cfg_dir "$BUNDLE_DIR")"
  for t in $ALL_TARGETS; do
    for s in $SANITIZER_VARIANTS; do
      case " $(triple_variants "$t") " in *" $s "*) continue ;; esac
      rm -rf "${BUNDLE_DIR:?}/lib/$t/$s" "$BUNDLE_DIR/sysroot/$t+$s" "$sd/$t-$s.addon.cfg"
      if [ "$s" = asan ]; then rm -rf "${BUNDLE_DIR:?}/include/$t/asan"; fi
    done
  done
  for s in $SANITIZER_VARIANTS; do
    case " $(all_variants) " in *" $s "*) ;; *) rm -f "$sd/$s.addon.json" ;; esac
  done
}

variant_dir() { printf '%s/variants/%s/%s\n' "$BUILD_DIR" "$2" "$1"; }   # TRIPLE SAN

build_variant_cxx() {
  local t="$1" s="$2" b inst args=() cxx=()
  b="$(variant_dir "$t" "$s")/cxx"; inst="$(variant_dir "$t" "$s")/cxx-install"
  mapfile -t args < <(san_runtimes_base_args "$t")
  mapfile -t cxx < <(san_cxx_args "$t")
  fresh_dir "$b"; rm -rf "$inst"
  cmake -S "$ROOT_DIR/llvm/runtimes" -B "$b" "${args[@]}" "${cxx[@]}" \
    -DCMAKE_CXX_FLAGS="--no-default-config $(arch_flags "$t")" \
    -DCMAKE_INSTALL_PREFIX="$inst" \
    -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx" \
    -DLLVM_USE_SANITIZER="$(san_cmake "$s")"
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
  rm -rf "${BUNDLE_DIR:?}/lib/$t/$s"; mkdir -p "$BUNDLE_DIR/lib/$t/$s"
  cp "$inst/lib/$t/libc++.a" "$inst/lib/$t/libc++abi.a" "$inst/lib/$t/libc++experimental.a" "$BUNDLE_DIR/lib/$t/$s/"
  if [ "$s" = asan ]; then
    # libc++ built with ASan sets _LIBCPP_INSTRUMENTED_WITH_ASAN 1; consumers need the same.
    rm -rf "${BUNDLE_DIR:?}/include/$t/asan"; mkdir -p "$BUNDLE_DIR/include/$t/asan/c++/v1"
    cp "$inst/include/$t/c++/v1/__config_site" "$BUNDLE_DIR/include/$t/asan/c++/v1/"
  fi
}

build_variant_components() {
  local t="$1" s="$2" prefix c
  prefix="$(variant_dir "$t" "$s")/usr"
  rm -rf "$prefix"; mkdir -p "$prefix"
  (
    export SANITIZER_LAYER="$s"
    # stage_source/component_build_dir use $BUILD_DIR/components/<t>/<c>: keep stage 50's trees intact.
    BUILD_DIR="$BUILD_DIR/variants/$s"
    for c in "${COMPONENTS[@]}"; do
      component_enabled "$c" || continue
      log "component $c -> $t ($s)"
      "$(component_fn "$c")" "$t" "$prefix"
    done
  )
}

build_mimalloc_shim() {
  local t="$1" s="$2" o lib
  o="$(variant_dir "$t" "$s")/mimalloc-shim.o"
  lib="$(variant_dir "$t" "$s")/usr/lib/libmimalloc.a"
  # shellcheck disable=SC2046
  "$BUNDLE_DIR/bin/$t-clang" $(SANITIZER_LAYER="$s" sanitizer_layer_flags "$t") $(arch_flags "$t") \
    -O2 -flto=thin -ffat-lto-objects -fPIC -Wall -Werror -I"$ROOT_DIR/mimalloc/include" \
    -c "$ROOT_DIR/src/mimalloc-sanitizer-shim.c" -o "$o"
  mkdir -p "${lib%/*}"; rm -f "$lib"
  "$BUNDLE_DIR/bin/llvm-ar" rcs "$lib" "$o"
}

# build_variant_elidealloc_shim TRIPLE SAN — libelidealloc-shim (stage 35) rebuilt with the
# sanitizer layer and the forward backend. The base archive's mimalloc backend needs mi_heap_* and
# arenas, which the forwarding libmimalloc.a above deliberately lacks (it would not link), and
# under MSan an uninstrumented shim reports false positives. Forward = the sanitized libc
# allocator, so every block stays visible to the sanitizer.
build_variant_elidealloc_shim() {
  local t="$1" s="$2" d f lib src="$ROOT_DIR/src/elidealloc-shim"
  d="$(variant_dir "$t" "$s")/elidealloc-shim"
  lib="$(variant_dir "$t" "$s")/usr/lib/libelidealloc-shim.a"
  [ -f "$(sysroot_of "$t")/usr/lib/libelidealloc-shim.a" ] || return 0   # stage 35 did not build one
  fresh_dir "$d"
  for f in core hotcold backend-forward; do
    # shellcheck disable=SC2046
    "$BUNDLE_DIR/bin/$t-clang++" $(SANITIZER_LAYER="$s" sanitizer_layer_flags "$t") $(arch_flags "$t") \
      -c -O2 -fPIC -std=c++17 -fvisibility=hidden -flto=thin -ffat-lto-objects \
      -I"$src" "$src/$f.cc" -o "$d/$f.o"
  done
  mkdir -p "${lib%/*}"; rm -f "$lib"
  "$BUNDLE_DIR/bin/llvm-ar" rcs "$lib" "$d/core.o" "$d/hotcold.o" "$d/backend-forward.o"
}

# assemble_variant_sysroot TRIPLE SAN — farm over sysroot/<T>: relative symlinks everywhere, real
# files for the instrumented archives, and no .so whose .a was replaced (lld prefers .so within a
# directory, which would silently link the uninstrumented shared library; spike F).
assemble_variant_sysroot() {
  local t="$1" s="$2" base farm e n a
  base="$(sysroot_of "$t")"; farm="$BUNDLE_DIR/sysroot/$t+$s"
  rm -rf "$farm"; mkdir -p "$farm/usr/lib"
  for e in "$base"/* "$base"/.[!.]*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    n="${e##*/}"; [ "$n" = usr ] || ln -s "../$t/$n" "$farm/$n"
  done
  for e in "$base"/usr/*; do n="${e##*/}"; [ "$n" = lib ] || ln -s "../../$t/usr/$n" "$farm/usr/$n"; done
  for e in "$base"/usr/lib/*; do n="${e##*/}"; ln -s "../../../$t/usr/lib/$n" "$farm/usr/lib/$n"; done
  for a in "$(variant_dir "$t" "$s")"/usr/lib/*.a; do
    [ -f "$a" ] || continue
    n="${a##*/}"
    [ -e "$base/usr/lib/$n" ] || [ "$n" = libmimalloc.a ] || continue   # only replace what the base ships
    rm -f "$farm/usr/lib/$n"; cp "$a" "$farm/usr/lib/$n"
    rm -f "$farm/usr/lib/${n%.a}.so" "$farm/usr/lib/${n%.a}".so.*
  done
}
