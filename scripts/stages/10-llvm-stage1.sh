# shellcheck shell=bash
# Stage 10. Linux: the stage-1 (bootstrap) clang/lld, not shipped: by default the pinned official
# LLVM $LLVM_VERSION release (STAGE1_SOURCE=prebuilt), else built with the host compiler
# (STAGE1_SOURCE=build). Either way it has no runtimes; stage 30 builds those from our patched tree.
# macOS: the shipped LLVM (single stage), deployment target MACOS_MIN, with compiler-rt
# builtins + profile (mainline clang always links its own libclang_rt.osx.a).

host_cc()  { command -v clang   || command -v gcc; }
host_cxx() { command -v clang++ || command -v g++; }

llvm_common_args() {
  printf '%s\n' \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF -DCLANG_INCLUDE_TESTS=OFF -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_CURL=OFF -DLLVM_ENABLE_HTTPLIB=OFF -DLLVM_ENABLE_FFI=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_FORCE_VC_REPOSITORY=https://github.com/llvm/llvm-project.git
  llvm_link_jobs_args
  cmake_launcher_args
}

stage_main() {
  apply_patches llvm "$ROOT_DIR/llvm"
  if [ "$HOST_OS" = darwin ]; then llvm_darwin
  elif [ "$STAGE1_SOURCE" = prebuilt ]; then llvm_stage1_prebuilt
  else llvm_stage1_linux
  fi
}

# Tools later stages run from $STAGE1_DIR/bin (directly, via toolchain files, or via -fuse-ld=lld).
STAGE1_TOOLS="clang clang++ lld ld.lld llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-readelf llvm-strip"

# llvm_stage1_prebuilt — the pinned official release as stage 1. Safe because the version is the
# same (compatible bitcode for the fat-LTO archives stages 30-60 produce) and nothing later relies
# on our LLVM patches being in the bootstrap compiler: they matter for the shipped stage 2 (stage
# 40) and for compiler-rt, which stage 30 builds from the patched tree (spec §3.3b).
llvm_stage1_prebuilt() {
  local url sha tarball t
  url="$(llvm_prebuilt_pin linux "$HOST_ARCH" url)"
  sha="$(llvm_prebuilt_pin linux "$HOST_ARCH" sha256)"
  if [ -z "$url" ] || [ -z "$sha" ]; then die "no prebuilt LLVM pinned for linux-$HOST_ARCH; use STAGE1_SOURCE=build"; fi
  tarball="$CACHE_DIR/llvm-prebuilt/${url##*/}"
  fetch_pinned "$url" "$sha" "$tarball"
  rm -rf "$STAGE1_DIR"
  mkdir -p "$STAGE1_DIR"
  log "extracting $(basename "$tarball") into $STAGE1_DIR"
  xz -T0 -dc "$tarball" | tar -C "$STAGE1_DIR" --strip-components=1 -xf -
  provide_prebuilt_icu
  check_stage1_tools
  prune_prebuilt_runtimes
  "$STAGE1_DIR/bin/clang" --version >/dev/null 2>&1 \
    || die "prebuilt clang stops running once its bundled runtimes are pruned; use STAGE1_SOURCE=build"
  t="$(clang_default_runtimes)"
  [ "$t" = "libgcc libstdc++ ld" ] \
    || die "prebuilt clang's default rtlib/stdlib/linker are '$t', not the upstream 'libgcc libstdc++ ld' stage 30 expects; use STAGE1_SOURCE=build"
  mkdir -p "$BUNDLE_DIR/sysroot"
  ln -sfn "$BUNDLE_DIR/sysroot" "$STAGE1_DIR/sysroot"
}

# provide_prebuilt_icu — when the prebuilt lld cannot find its ICU libraries on this host, unpack
# them from the pinned package into stage1/lib (on lld's RUNPATH). No-op where nothing is missing.
provide_prebuilt_icu() {
  local url sha deb tmp missing
  missing="$(ldd "$STAGE1_DIR/bin/lld" 2>/dev/null | awk '/libicu.*not found/ { print $1 }' | xargs)"
  [ -n "$missing" ] || return 0
  url="$(llvm_prebuilt_pin linux "$HOST_ARCH" icu_url)"
  sha="$(llvm_prebuilt_pin linux "$HOST_ARCH" icu_sha256)"
  if [ -z "$url" ] || [ -z "$sha" ]; then die "prebuilt lld needs $missing and no ICU package is pinned for linux-$HOST_ARCH; use STAGE1_SOURCE=build"; fi
  deb="$CACHE_DIR/llvm-prebuilt/${url##*/}"
  fetch_pinned "$url" "$sha" "$deb"
  log "unpacking $(basename "$deb") for the prebuilt lld ($missing)"
  tmp="$(mktemp -d)"
  if command -v dpkg-deb >/dev/null 2>&1; then dpkg-deb -x "$deb" "$tmp"
  else (cd "$tmp" && ar x "$deb" data.tar.zst && zstd -dcq data.tar.zst | tar -xf -); fi
  cp -P "$tmp"/usr/lib/*-linux-gnu/libicu*.so.* "$STAGE1_DIR/lib/"
  rm -rf "$tmp"
}

# prune_prebuilt_runtimes — the release ships compiler-rt, libc++ and friends built for the host
# glibc. Remove them so stage 1 matches a from-source build (clang + lld only): stages 30/31
# install ours, and nothing from the release may satisfy their checks or leak into a link.
prune_prebuilt_runtimes() {
  local d
  rm -rf "$STAGE1_DIR/lib/clang/$LLVM_MAJOR/lib" "$STAGE1_DIR/lib/clang/$LLVM_MAJOR/share" \
    "$STAGE1_DIR/include/c++"
  for d in "$STAGE1_DIR"/lib/*-linux-* "$STAGE1_DIR"/include/*-linux-*; do
    if [ -d "$d" ]; then rm -rf "$d"; fi
  done
  [ -d "$STAGE1_DIR/lib/clang/$LLVM_MAJOR/include" ] \
    || die "prebuilt LLVM has no lib/clang/$LLVM_MAJOR/include (version mismatch?)"
}

# check_stage1_tools — every tool later stages use exists and clang is LLVM_VERSION.
check_stage1_tools() {
  local f v
  for f in $STAGE1_TOOLS; do
    [ -x "$STAGE1_DIR/bin/$f" ] || die "stage 1 lacks bin/$f"
  done
  v="$("$STAGE1_DIR/bin/clang" --version 2>&1)" || die "stage-1 clang does not run on this host: $v"
  case "$v" in
    *"clang version $LLVM_VERSION"*) ;;
    *) die "stage-1 clang is not $LLVM_VERSION: ${v%%$'\n'*}" ;;
  esac
  v="$("$STAGE1_DIR/bin/ld.lld" --version 2>&1)" || die "stage-1 ld.lld does not run on this host: $v"
}

# clang_default_runtimes — "RTLIB STDLIB LINKER" stage-1 clang uses for a gnu target without a cfg
# (libgcc libstdc++ ld for upstream defaults). Stage 30 builds the runtimes with bare clang and
# relies on those defaults; a release built with CLANG_DEFAULT_* overrides would break it.
clang_default_runtimes() {
  local out rt=libgcc std=libstdc++ ld=ld
  out="$("$STAGE1_DIR/bin/clang++" -### --no-default-config --target="$(bundle_triple_for_libc gnu)" \
    -x c++ /dev/null -o /dev/null 2>&1)" || true
  case "$out" in *libclang_rt.builtins*) rt=compiler-rt ;; esac
  case "$out" in *'"-lc++"'*) std=libc++ ;; esac
  case "$out" in *'ld.lld"'*) ld=lld ;; esac
  printf '%s %s %s\n' "$rt" "$std" "$ld"
}

llvm_stage1_linux() {
  local b="$BUILD_DIR/llvm-stage1" args=() lld=()
  mapfile -t args < <(llvm_common_args)
  if command -v ld.lld >/dev/null 2>&1; then lld=(-DLLVM_ENABLE_LLD=ON); fi
  fresh_dir "$b"
  rm -rf "$STAGE1_DIR"
  cmake -S "$ROOT_DIR/llvm/llvm" -B "$b" "${args[@]}" "${lld[@]}" \
    -DCMAKE_INSTALL_PREFIX="$STAGE1_DIR" \
    -DCMAKE_C_COMPILER="$(host_cc)" -DCMAKE_CXX_COMPILER="$(host_cxx)" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_ENABLE_ZLIB=OFF
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
  mkdir -p "$BUNDLE_DIR/sysroot"
  ln -sfn "$BUNDLE_DIR/sysroot" "$STAGE1_DIR/sysroot"
}

llvm_darwin() {
  local t cpu b="$BUILD_DIR/llvm" args=() san=OFF fuzz=OFF
  t="$ALL_TARGETS"
  # Sanitizer dylibs + libFuzzer (spec 2026-10-05 §6.3); matrix in versions.env.
  if [ -n "$(triple_sanitizers "$t")" ]; then san=ON; fi
  if triple_has_libfuzzer "$t"; then fuzz=ON; fi
  cpu="$(triple_cpu "$t")"
  mapfile -t args < <(llvm_common_args)
  fresh_dir "$b"
  cmake -S "$ROOT_DIR/llvm/llvm" -B "$b" "${args[@]}" \
    -DCMAKE_INSTALL_PREFIX="$BUNDLE_DIR" \
    -DCMAKE_C_COMPILER="$(xcrun -f clang)" -DCMAKE_CXX_COMPILER="$(xcrun -f clang++)" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_OSX_SYSROOT="$SDKROOT" \
    -DCMAKE_OSX_ARCHITECTURES="$cpu" \
    -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS_DARWIN" \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$t" \
    -DLLVM_ENABLE_ZLIB=ON \
    -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_PROFILE=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS="$san" -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_LIBFUZZER="$fuzz" \
    -DCOMPILER_RT_SANITIZERS_TO_BUILD="$(crt_sanitizers_to_build "$t")" \
    -DSANITIZER_MIN_OSX_VERSION="$MACOS_MIN" \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
    -DCOMPILER_RT_ENABLE_IOS=OFF -DCOMPILER_RT_ENABLE_WATCHOS=OFF -DCOMPILER_RT_ENABLE_TVOS=OFF \
    -DCOMPILER_RT_ENABLE_XROS=OFF \
    -DDARWIN_osx_ARCHS="$cpu" -DDARWIN_osx_BUILTIN_ARCHS="$cpu"
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
  install_frontends "$BUNDLE_DIR"
}
