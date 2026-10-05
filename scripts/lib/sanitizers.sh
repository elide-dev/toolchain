# shellcheck shell=bash
# Sanitizer support (spec docs/superpowers/specs/2026-10-05-sanitizer-variants-design.md):
# the shipped matrix, front-ends (cfg layers, wrappers, CMake toolchain files), the compile layer
# stage 60 uses to build instrumented components, and the per-sanitizer add-on packaging.

# ---------------------------------------------------------------------------------------------
# Matrix (§3). Selectable short names: asan tsan msan ubsan lsan hwasan.

# triple_sanitizers TRIPLE — selectable sanitizers whose runtimes the main bundle ships for TRIPLE.
triple_sanitizers() {
  local t="$1" list=""
  if ! is_yes "${BUILD_SANITIZERS:-yes}"; then echo ""; return 0; fi
  case "$(triple_libc "$t")" in
    gnu)
      list="$SANITIZERS_LINUX_GNU"
      if [ "$(triple_cpu "$t")" = aarch64 ]; then list="$list $SANITIZERS_LINUX_GNU_AARCH64"; fi ;;
    musl) list="$SANITIZERS_LINUX_MUSL" ;;
    darwin) list="$SANITIZERS_DARWIN" ;;
  esac
  printf '%s\n' "$list"
}

# triple_variants TRIPLE — sanitizers with an add-on (instrumented libc++ + components) for TRIPLE.
triple_variants() {
  if [ "$(triple_libc "$1")" = gnu ] && is_yes "${BUILD_SANITIZERS:-yes}" \
     && is_yes "${BUILD_SANITIZER_VARIANTS:-no}"; then
    printf '%s\n' "$SANITIZER_VARIANTS"
  else
    echo ""
  fi
}

# all_variants — union of triple_variants over the bundle's targets (stable order).
all_variants() {
  local s t out=""
  for s in $SANITIZER_VARIANTS; do
    for t in $ALL_TARGETS; do
      case " $(triple_variants "$t") " in *" $s "*) out="$out $s"; break ;; esac
    done
  done
  printf '%s\n' "${out# }"
}

triple_has_libfuzzer() {
  is_yes "${BUILD_SANITIZERS:-yes}" || return 1
  case " $LIBFUZZER_LIBCS " in *" $(triple_libc "$1") "*) return 0 ;; esac
  return 1
}

san_flag() {
  case "$1" in
    asan) echo address ;; tsan) echo thread ;; msan) echo memory ;;
    ubsan) echo undefined ;; lsan) echo leak ;; hwasan) echo hwaddress ;;
    *) die "unknown sanitizer: $1" ;;
  esac
}

# san_cmake SAN — LLVM_USE_SANITIZER value for the add-on's instrumented libc++.
san_cmake() {
  case "$1" in asan) echo Address ;; tsan) echo Thread ;; msan) echo MemoryWithOrigins ;; *) die "no add-on for $1" ;; esac
}

# san_symbol SAN — runtime symbol prefix every instrumented archive references.
san_symbol() {
  case "$1" in asan) echo __asan_ ;; tsan) echo __tsan_ ;; msan) echo __msan_ ;; *) die "no add-on for $1" ;; esac
}

# san_report SAN — text the runtime prints for the fixture bug (tests/fixtures/sanitizers/<san>.c).
san_report() {
  case "$1" in
    asan) echo heap-buffer-overflow ;; tsan) echo "data race" ;; msan) echo use-of-uninitialized-value ;;
    ubsan) echo "runtime error" ;; lsan) echo "detected memory leaks" ;; hwasan) echo tag-mismatch ;;
    *) die "unknown sanitizer: $1" ;;
  esac
}

# san_runtimes NAME — compiler-rt runtime basenames (libclang_rt.<name>.*) NAME needs on Linux.
san_runtimes() {
  case "$1" in
    asan) echo "asan asan_static asan-preinit asan_cxx" ;;
    tsan) echo "tsan tsan_cxx" ;;
    msan) echo "msan msan_cxx" ;;
    lsan) echo "lsan" ;;
    ubsan) echo "ubsan_standalone ubsan_standalone_cxx ubsan_minimal" ;;
    hwasan) echo "hwasan hwasan_cxx hwasan-preinit" ;;
    fuzzer) echo "fuzzer fuzzer_no_main fuzzer_interceptors" ;;
    *) die "unknown sanitizer: $1" ;;
  esac
}

# crt_sanitizers_to_build TRIPLE — COMPILER_RT_SANITIZERS_TO_BUILD. compiler-rt always builds lsan
# and ubsan_standalone when sanitizers are on; ubsan additionally selects ubsan_minimal.
crt_sanitizers_to_build() {
  local s out=""
  for s in $(triple_sanitizers "$1"); do
    case "$s" in
      lsan) ;;
      ubsan) out="$out;ubsan_minimal" ;;
      *) out="$out;$s" ;;
    esac
  done
  printf '%s\n' "${out#;}"
}

# ---------------------------------------------------------------------------------------------
# Front-ends (§5.1). Runtime layer cfg + wrappers + CMake file live in the main bundle; the
# add-on layer cfg (sysroot farm, variant libc++) ships in each add-on.

san_cfg_dir() { printf '%s/share/elide-toolchain/sanitizers\n' "$1"; }

render_san_cfg() {
  local s="$2"
  printf -- '-fsanitize=%s\n' "$(san_flag "$s")"
  if [ "$s" = msan ]; then echo "-fsanitize-memory-track-origins"; fi
  echo "-fno-omit-frame-pointer"
}

render_san_addon_cfg() { # paths are relative to share/elide-toolchain/sanitizers/
  local t="$1" s="$2"
  echo "--sysroot=<CFGDIR>/../../../sysroot/$t+$s"
  echo "-L<CFGDIR>/../../../lib/$t/$s"
  if [ "$s" = asan ]; then echo "-isystem <CFGDIR>/../../../include/$t/asan/c++/v1"; fi
}

render_san_wrapper() { # TRIPLE SAN DRIVER(clang|clang++)
  local t="$1" s="$2" d="$3" fallback
  # Without its add-on, msan cannot work (uninstrumented libc++/components => false positives).
  fallback="exec \"\$here/$t-$d\" --config=\"\$sd/$t-$s.cfg\" \"\$@\""
  if [ "$s" = msan ]; then
    fallback="echo \"$t-$s-$d: msan needs its add-on (instrumented libc++ and components); see: elide-toolchain sanitizers\" >&2
exit 2"
  fi
  cat <<EOF
#!/bin/sh
# $t + $s: auto-loaded $t.cfg, the $s runtime layer, and the add-on layer when installed.
here=\$(CDPATH='' cd -- "\$(dirname -- "\$0")" && pwd -P)
sd=\$here/../share/elide-toolchain/sanitizers
if [ -f "\$sd/$t-$s.addon.cfg" ]; then
  exec "\$here/$t-$d" --config="\$sd/$t-$s.cfg" --config="\$sd/$t-$s.addon.cfg" "\$@"
fi
$fallback
EOF
}

render_san_toolchain_cmake() {
  local t="$1" s="$2"
  render_toolchain_cmake "$t" \
    | sed -e "s#/bin/$t-clang\"#/bin/$t-$s-clang\"#" -e "s#/bin/$t-clang++\"#/bin/$t-$s-clang++\"#" \
          -e "/^set(CMAKE_SYSROOT /d"
  if [ "$(triple_os "$t")" = linux ]; then
    cat <<EOF
# The $s add-on, when installed, provides an instrumented sysroot; find_package/find_library
# then resolve its archives instead of the base sysroot's.
if(EXISTS "\${_ET_ROOT}/sysroot/$t+$s/usr/lib")
  set(CMAKE_SYSROOT "\${_ET_ROOT}/sysroot/$t+$s")
else()
  set(CMAKE_SYSROOT "\${_ET_ROOT}/sysroot/$t")
endif()
EOF
  fi
}

# install_sanitizer_frontends PREFIX TRIPLE — runtime layer cfgs, wrappers and CMake files.
install_sanitizer_frontends() {
  local prefix="$1" t="$2" s d sd
  sd="$(san_cfg_dir "$prefix")"
  mkdir -p "$sd" "$prefix/share/elide-toolchain/cmake"
  for s in $(triple_sanitizers "$t"); do
    render_san_cfg "$t" "$s" > "$sd/$t-$s.cfg"
    for d in clang clang++; do
      render_san_wrapper "$t" "$s" "$d" > "$prefix/bin/$t-$s-$d"
      chmod 0755 "$prefix/bin/$t-$s-$d"
    done
    render_san_toolchain_cmake "$t" "$s" > "$prefix/share/elide-toolchain/cmake/$t-$s.cmake"
  done
}

# install_sanitizer_addon_frontends PREFIX TRIPLE SAN — the add-on layer cfg (stage 60).
install_sanitizer_addon_frontends() {
  mkdir -p "$(san_cfg_dir "$1")"
  render_san_addon_cfg "$2" "$3" > "$(san_cfg_dir "$1")/$2-$3.addon.cfg"
}

# ---------------------------------------------------------------------------------------------
# Compile layer for stage 60's instrumented component builds (§6.4). Uses the runtime cfg plus
# the variant libc++ dir directly: the farm (add-on cfg's --sysroot) does not exist yet.

sanitizer_layer_flags() {
  local t="$1" s="${SANITIZER_LAYER:-}" r="${TOOLCHAIN_ROOT:-$BUNDLE_DIR}"
  [ -n "$s" ] || return 0
  printf -- '--config=%s/share/elide-toolchain/sanitizers/%s-%s.cfg -L%s/lib/%s/%s' "$r" "$t" "$s" "$r" "$t" "$s"
  if [ "$s" = asan ]; then printf -- ' -isystem %s/include/%s/asan/c++/v1' "$r" "$t"; fi
  printf ' '
}

# component_variant_args NAME — extra recipe arguments under SANITIZER_LAYER. MSan cannot see
# stores made by uninstrumented assembly; zstd and zlib-ng switch their asm off themselves under
# __has_feature(memory_sanitizer), aws-lc and OpenSSL need it switched off explicitly.
component_variant_args() {
  case "${SANITIZER_LAYER:-}:$1" in
    msan:aws-lc) echo "-DOPENSSL_NO_ASM=1" ;;
    msan:openssl) echo "no-asm" ;;
    *) echo "" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# LLVM runtimes builds for sanitizers (stages 31 and 60). Bare --target/--sysroot like stage 30
# (never the cfg); compiled by stage-1 clang.

san_runtimes_base_args() { # TRIPLE
  local t="$1" s="$STAGE1_DIR/bin" af
  af="--no-default-config $(arch_flags "$t")"
  printf '%s\n' \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$s/clang" -DCMAKE_CXX_COMPILER="$s/clang++" -DCMAKE_ASM_COMPILER="$s/clang" \
    -DCMAKE_C_COMPILER_TARGET="$t" -DCMAKE_CXX_COMPILER_TARGET="$t" -DCMAKE_ASM_COMPILER_TARGET="$t" \
    -DCMAKE_SYSROOT="$(sysroot_of "$t")" \
    -DCMAKE_AR="$s/llvm-ar" -DCMAKE_RANLIB="$s/llvm-ranlib" -DCMAKE_NM="$s/llvm-nm" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$af" -DCMAKE_ASM_FLAGS="$af" \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
    -DCOMPILER_RT_INSTALL_PATH:STRING="lib/clang/$LLVM_MAJOR" \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
  llvm_link_jobs_args
  cmake_launcher_args
}

# san_cxx_args TRIPLE — libunwind/libc++abi/libc++ options of stage 30's pass 2 (kept in sync by
# tests/unit/sanitizers.test.sh), except that the unwinder is NOT merged into libc++abi: an
# instrumented unwinder recurses forever under MSan (spike C), so the add-ons ship no libunwind and
# -lunwind resolves to the main bundle's.
san_cxx_args() {
  local t="$1" musl=OFF
  if [ "$(triple_libc "$t")" = musl ]; then musl=ON; fi
  printf '%s\n' \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DLIBUNWIND_USE_COMPILER_RT=ON -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_STATIC=ON \
    -DLIBCXXABI_USE_COMPILER_RT=ON -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
    -DLIBCXXABI_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_STATIC=ON \
    -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=OFF \
    -DLIBCXX_USE_COMPILER_RT=ON -DLIBCXX_HAS_MUSL_LIBC="$musl" \
    -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_ENABLE_STATIC=ON \
    -DLIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY=ON \
    -DLIBCXX_HARDENING_MODE=fast \
    "-DLIBUNWIND_ADDITIONAL_COMPILE_FLAGS=-flto=thin;-ffat-lto-objects" \
    "-DLIBCXXABI_ADDITIONAL_COMPILE_FLAGS=-flto=thin;-ffat-lto-objects" \
    "-DLIBCXX_ADDITIONAL_COMPILE_FLAGS=-flto=thin;-ffat-lto-objects" \
    -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
    -DLIBCXXABI_INCLUDE_TESTS=OFF -DLIBUNWIND_INCLUDE_TESTS=OFF \
    -DLIBCXX_INSTALL_INCLUDE_DIR=include/c++/v1 \
    -DLIBCXX_INSTALL_INCLUDE_TARGET_DIR="include/$t/c++/v1" \
    -DLIBCXX_INSTALL_LIBRARY_DIR="lib/$t" \
    -DLIBCXXABI_INSTALL_LIBRARY_DIR="lib/$t" \
    -DLIBUNWIND_INSTALL_LIBRARY_DIR="lib/$t"
}

# prune_sanitizer_runtimes PREFIX TRIPLE — keep only the runtimes the matrix ships (compiler-rt
# also builds stats, ubsan_loop_detect, lsan on musl, …). Non-sanitizer runtimes are kept.
prune_sanitizer_runtimes() {
  local rd="$1/lib/clang/$LLVM_MAJOR/lib/$2" keep=" " s r f base all=" "
  for s in asan tsan msan lsan ubsan hwasan fuzzer; do for r in $(san_runtimes "$s"); do all="$all$r "; done; done
  all="$all stats stats_client ubsan_loop_detect hwasan_aliases hwasan_aliases_cxx dd dyndd "
  for s in $(triple_sanitizers "$2"); do for r in $(san_runtimes "$s"); do keep="$keep$r "; done; done
  if triple_has_libfuzzer "$2"; then for r in $(san_runtimes fuzzer); do keep="$keep$r "; done; fi
  for f in "$rd"/libclang_rt.*; do
    [ -e "$f" ] || continue
    base="${f##*/libclang_rt.}"; base="${base%%.*}"
    case "$all" in *" $base "*) ;; *) continue ;; esac
    case "$keep" in *" $base "*) ;; *) rm -f "$f" ;; esac
    # musl is static-only by design: no shared sanitizer runtimes there.
    if [ "$(triple_libc "$2")" = musl ]; then case "$f" in *.so) rm -f "$f" ;; esac; fi
  done
}

# ---------------------------------------------------------------------------------------------
# Add-on packaging (§4.2, §6.5). One archive per sanitizer, disjoint from the main bundle and
# from each other.

addon_asset_name() { # SAN
  printf '%s-%s-%s-%s-sanitizer-%s.tar.xz\n' "$TOOLCHAIN_NAME" "$TOOLCHAIN_VERSION" "$HOST_OS" "$HOST_ARCH" "$1"
}

addon_json_rel() { printf 'share/elide-toolchain/sanitizers/%s.addon.json\n' "$1"; }

# addon_paths SAN — bundle paths of SAN's add-on, relative to $OUT_DIR.
addon_paths() {
  local s="$1" t n="$TOOLCHAIN_NAME"
  for t in $ALL_TARGETS; do
    case " $(triple_variants "$t") " in *" $s "*) ;; *) continue ;; esac
    printf '%s\n' "$n/lib/$t/$s" "$n/sysroot/$t+$s" "$n/share/elide-toolchain/sanitizers/$t-$s.addon.cfg"
    if [ "$s" = asan ]; then printf '%s\n' "$n/include/$t/asan"; fi
  done
  printf '%s/%s\n' "$n" "$(addon_json_rel "$s")"
}

# addon_json SAN — the add-on's metadata (version must match the bundle it extracts over).
addon_json() {
  local s="$1" t triples=""
  for t in $ALL_TARGETS; do
    case " $(triple_variants "$t") " in *" $s "*) triples="$triples${triples:+,}\"$t\"" ;; esac
  done
  printf '{"name": "%s", "sanitizer": "%s", "version": "%s", "triples": [%s], "asset": "%s"}\n' \
    "$TOOLCHAIN_NAME" "$s" "$TOOLCHAIN_VERSION" "$triples" "$(addon_asset_name "$s")"
}

# sanitizer_manifest_json — the manifest's "sanitizers"/"addons" data, consumed by gen-manifest.py.
sanitizer_manifest_json() {
  local t s first=1 rts out="{\"sanitizers\": {"
  for t in $ALL_TARGETS; do
    rts=""
    for s in $(triple_sanitizers "$t"); do rts="$rts${rts:+, }\"$s\""; done
    if triple_has_libfuzzer "$t"; then rts="$rts${rts:+, }\"fuzzer\""; fi
    local vs=""
    for s in $(triple_variants "$t"); do vs="$vs${vs:+, }\"$s\""; done
    [ "$first" = 1 ] || out="$out, "
    first=0
    out="$out\"$t\": {\"runtimes\": [$rts], \"addons\": [$vs]}"
  done
  out="$out}, \"addons\": {"
  first=1
  for s in $(all_variants); do
    [ "$first" = 1 ] || out="$out, "
    first=0
    out="$out\"$s\": \"$(addon_asset_name "$s")\""
  done
  printf '%s}}\n' "$out"
}

# addon_excludes — GNU tar --exclude options keeping every add-on path out of the main archive.
addon_excludes() {
  local s p
  for s in $(all_variants); do
    while IFS= read -r p; do printf -- '--exclude=%s\n' "$p"; done < <(addon_paths "$s")
  done
}

# package_sanitizer_addons — write one .tar.xz (+ .sha256) per variant into $DIST_DIR.
package_sanitizer_addons() {
  local s p archive paths=() seen=" "
  for s in $(all_variants); do
    addon_json "$s" > "$BUNDLE_DIR/$(addon_json_rel "$s")"
    paths=()
    while IFS= read -r p; do
      [ -e "$OUT_DIR/$p" ] || die "add-on $s: missing $p (run 60-sanitizer-addons)"
      case "$seen" in *" $p "*) die "add-on path $p is in two add-ons" ;; esac
      seen="$seen$p "
      paths+=("$p")
    done < <(addon_paths "$s")
    archive="$DIST_DIR/$(addon_asset_name "$s")"
    rm -f "$archive" "$archive.sha256"
    tar -C "$OUT_DIR" -cf - "${paths[@]}" | xz -T0 -9 > "$archive.tmp"
    mv "$archive.tmp" "$archive"
    printf '%s  %s\n' "$(sha256_of "$archive")" "${archive##*/}" > "$archive.sha256"
    log "wrote $archive"
  done
}
