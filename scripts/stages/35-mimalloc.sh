# shellcheck shell=bash
# Stage 35: mimalloc for every target. On Linux, musl is rebuilt (phase 2) with mimalloc as
# its allocator and, with MUSL_USE_LTO, as fat ThinLTO objects (bitcode + native code) so lld
# can do cross-language LTO while GNU ld, older rust-lld and GraalVM links still work.

stage_main() {
  local t
  if [ "$HOST_OS" = linux ]; then export TOOLCHAIN_ROOT="$STAGE1_DIR"; else export TOOLCHAIN_ROOT="$BUNDLE_DIR"; fi
  for t in $ALL_TARGETS; do
    case "$(triple_libc "$t")" in
      musl) build_musl_phase2 "$t" ;;
      *) build_mimalloc_standalone "$t" ;;
    esac
    build_elidealloc_shim "$t"
  done
}

# libelidealloc-shim: allocator-agnostic hint partitioning (MemProf hot/cold today, allocation
# tokens later) over a build-time backend. Fat ThinLTO objects like the other shipped archives.
build_elidealloc_shim() {
  local t="$1" prefix b backend f libs lto src="$ROOT_DIR/src/elidealloc-shim"
  prefix="$(target_prefix "$t")"
  b="$(component_build_dir elidealloc-shim "$t")"
  backend="$(elidealloc_backend "$t")"
  # Fat objects are ELF-only; darwin archives are pure ThinLTO bitcode (spec §3.3a).
  lto="-flto=thin -ffat-lto-objects"
  if [ "$(triple_os "$t")" = darwin ]; then lto="-flto=thin"; fi
  for f in core hotcold "backend-$backend"; do
    # shellcheck disable=SC2046,SC2086
    "$TOOLCHAIN_ROOT/bin/$t-clang++" -c -O2 -fPIC -std=c++17 -fvisibility=hidden \
      $lto $(arch_flags "$t") \
      -I"$src" -I"$prefix/include" "$src/$f.cc" -o "$b/$f.o"
  done
  mkdir -p "$prefix/lib/pkgconfig" "$prefix/include"
  rm -f "$prefix/lib/libelidealloc-shim.a"
  "$TOOLCHAIN_ROOT/bin/llvm-ar" rcs "$prefix/lib/libelidealloc-shim.a" "$b/core.o" "$b/hotcold.o" "$b/backend-$backend.o"
  cp "$src/elidealloc-shim.h" "$prefix/include/"
  libs="-lelidealloc-shim"
  if [ "$(triple_libc "$t")" = gnu ]; then libs="$libs -lmimalloc"; fi
  sed -e "s|@LIBS@|$libs|" -e "s|@BACKEND@|$backend|" -e "s|@VERSION@|$TOOLCHAIN_VERSION|" \
    "$src/elidealloc-shim.pc.in" > "$prefix/lib/pkgconfig/elidealloc-shim.pc"
}

mimalloc_args() { # OVERRIDE
  printf '%s\n' \
    -DMI_SECURE="$MIMALLOC_SECURE" -DMI_GUARDED="$MIMALLOC_GUARDED" \
    -DMI_OPT_ARCH=ON -DMI_BUILD_SHARED=OFF -DMI_BUILD_STATIC=ON -DMI_BUILD_TESTS=OFF \
    -DMI_INSTALL_TOPLEVEL=ON -DMI_OVERRIDE="$1" -DMI_SKIP_COLLECT_ON_EXIT=ON \
    "-DMI_EXTRA_CPPDEFS=MI_DEFAULT_ARENA_RESERVE=33554432;MI_DEFAULT_ALLOW_LARGE_OS_PAGES=0"
}

build_mimalloc_standalone() {
  local t="$1" override=ON args=()
  # macOS malloc override needs dylib interposing; the static archive exposes the mi_* API only.
  if [ "$(triple_os "$t")" = darwin ]; then override=OFF; fi
  mapfile -t args < <(mimalloc_args "$override")
  cmake_target "$t" "$(stage_source mimalloc "$t")" "$(component_build_dir mimalloc "$t")" \
    "$(target_prefix "$t")" "${args[@]}" -DMI_BUILD_OBJECT=OFF
}

build_musl_phase2() {
  local t="$1" s="$STAGE1_DIR/bin" sysroot prefix tflags lto="" ldflags libcc obj="" glue="" malloc_arg=""
  sysroot="$(sysroot_of "$t")"
  prefix="$(target_prefix "$t")"
  # --no-default-config: bare stage-1 clang must not auto-load stage1/bin/<target>.cfg (spec §3.3).
  tflags="--no-default-config --target=$t --sysroot=$sysroot"
  ldflags="$tflags -fuse-ld=lld"
  if is_yes "$MUSL_USE_LTO"; then
    lto="-flto=thin -ffat-lto-objects"
    # ldso bootstrap calls __dls2/__dls3 from asm, invisible to LTO: keep them, link libc.so without LTO.
    ldflags="$ldflags -fno-lto -Wl,--undefined=__dls2 -Wl,--undefined=__dls3"
  fi
  libcc="$("$s/clang" --no-default-config --target="$t" -rtlib=compiler-rt -print-libgcc-file-name)"
  [ -f "$libcc" ] || die "compiler-rt builtins missing for $t ($libcc); run 30-runtimes"

  if is_yes "$MUSL_USE_MIMALLOC"; then
    local mi_src mi_build args=()
    mi_src="$(stage_source mimalloc "$t")"
    mi_build="$(component_build_dir mimalloc "$t")"
    mapfile -t args < <(mimalloc_args OFF)   # glue code provides the libc entry points
    cmake -S "$mi_src" -B "$mi_build" -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE="$(toolchain_file "$t")" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      -DCMAKE_C_FLAGS="$(arch_flags "$t") $lto" \
      "${args[@]}" -DMI_LIBC_MUSL=ON -DMI_BUILD_OBJECT=ON
    cmake --build "$mi_build" -j "$JOBS"
    obj="$mi_build/mimalloc.o"
    [ -f "$obj" ] || die "mimalloc.o not produced at $obj"
    glue="$mi_build/mimalloc-musl-glue.o"
    # shellcheck disable=SC2086,SC2046
    "$s/clang" -c -O3 -fPIC $tflags $lto $(arch_flags "$t") \
      -fno-fast-math -U_FORTIFY_SOURCE -ffunction-sections -fdata-sections \
      -I"$mi_src/include" -I"$prefix/include" \
      "$ROOT_DIR/src/mimalloc-musl-glue.c" -o "$glue"
  else
    malloc_arg="--with-malloc=mallocng"
  fi

  local src cflags cflags_ldso
  src="$(stage_source musl "$t")"
  cflags="$(arch_flags "$t") -ffunction-sections -fdata-sections -fno-fast-math -U_FORTIFY_SOURCE -O3 $tflags $lto"
  cflags_ldso="$(arch_flags "$t") -ffunction-sections -fdata-sections -fno-fast-math -U_FORTIFY_SOURCE -O3 $tflags -fno-lto"
  (
    cd "$src" || exit 1
    unset CFLAGS CXXFLAGS LDFLAGS CC
    # The submodule checkout may hold ignored artifacts from an earlier in-tree build; start clean.
    rm -rf obj lib config.mak buildlog.txt mimalloc
    mkdir -p mimalloc/objs
    if [ -n "$obj" ]; then cp "$obj" "$glue" mimalloc/objs/; fi
    # shellcheck disable=SC2086
    ./configure CC="$s/clang" AR="$s/llvm-ar" RANLIB="$s/llvm-ranlib" \
      CFLAGS="-fno-fast-math $tflags $lto" LDFLAGS="$ldflags" \
      --prefix=/usr --syslibdir=/lib --enable-optimize=internal,malloc,string $malloc_arg
    local mk=(CC="$s/clang" AR="$s/llvm-ar" RANLIB="$s/llvm-ranlib"
      CFLAGS_AUTO="$cflags" CFLAGS_MEMOPS="$cflags" CFLAGS_LDSO="$cflags_ldso"
      LDFLAGS="$ldflags" LIBCC="$libcc" USE_MIMALLOC="$(is_yes "$MUSL_USE_MIMALLOC" && echo yes || echo no)")
    make -j"$JOBS" "${mk[@]}"
    # install must see the same variables, or make re-evaluates the source list and rebuilds libc.a
    # without mimalloc.
    make install DESTDIR="$sysroot" "${mk[@]}"
  )
  # musl installs the loader as an absolute symlink to /usr/lib/libc.so; make it relocatable.
  ln -sfn ../usr/lib/libc.so "$sysroot/$(musl_loader "$(triple_cpu "$t")")"
  cp "$ROOT_DIR"/mimalloc/include/mimalloc*.h "$prefix/include/"
}
