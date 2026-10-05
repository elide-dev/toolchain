#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
T="$(mktemp -d)"
ELIDE_HOST_OS=linux ELIDE_HOST_ARCH=amd64 ELIDE_OUT_DIR="$T/out"
export ELIDE_HOST_OS ELIDE_HOST_ARCH ELIDE_OUT_DIR
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
G=x86_64-unknown-linux-gnu M=x86_64-unknown-linux-musl

# --- matrix -----------------------------------------------------------------------------------
assert_eq "$(triple_sanitizers $G)" "asan lsan tsan msan ubsan"
assert_eq "$(triple_sanitizers aarch64-unknown-linux-gnu)" "asan lsan tsan msan ubsan hwasan"
assert_eq "$(triple_sanitizers $M)" "ubsan"
assert_eq "$(triple_sanitizers arm64-apple-darwin)" "asan tsan ubsan"
assert_eq "$(BUILD_SANITIZERS=no triple_sanitizers $G)" ""
assert_eq "$(BUILD_SANITIZER_VARIANTS=yes triple_variants $G)" "asan tsan msan"
assert_eq "$(BUILD_SANITIZER_VARIANTS=yes triple_variants $M)" ""
assert_eq "$(BUILD_SANITIZER_VARIANTS=no triple_variants $G)" ""
assert_eq "$(BUILD_SANITIZER_VARIANTS=yes all_variants)" "asan tsan msan"
# add-ons are x86_64-only (SANITIZER_VARIANT_CPUS)
assert_eq "$(BUILD_SANITIZER_VARIANTS=yes triple_variants aarch64-unknown-linux-gnu)" ""
assert_eq "$(BUILD_SANITIZER_VARIANTS=yes ALL_TARGETS="aarch64-unknown-linux-gnu aarch64-unknown-linux-musl" all_variants)" ""
assert_ok triple_has_libfuzzer $G
assert_fails triple_has_libfuzzer $M
assert_eq "$(san_flag msan)" "memory"
assert_eq "$(san_cmake msan)" "MemoryWithOrigins"
assert_eq "$(san_symbol tsan)" "__tsan_"
assert_eq "$(san_report asan)" "heap-buffer-overflow"
assert_contains "$(san_runtimes asan)" "asan_static"
assert_fails san_flag bogus
assert_eq "$(crt_sanitizers_to_build $G)" "asan;tsan;msan;ubsan_minimal"
assert_eq "$(crt_sanitizers_to_build aarch64-unknown-linux-gnu)" "asan;tsan;msan;ubsan_minimal;hwasan"
assert_eq "$(crt_sanitizers_to_build $M)" "ubsan_minimal"
for s in asan tsan msan ubsan lsan hwasan; do assert_file "$ROOT_DIR/tests/fixtures/sanitizers/$s.c"; done

# --- variant libc++ options stay in sync with stage 30's pass 2 (except the unwinder merge) -----
stage30="$(sed -n '/^build_cxx_runtimes()/,/^}/p' "$ROOT_DIR/scripts/stages/30-runtimes.sh")"
mine="$(san_cxx_args $G | xargs)"
while IFS= read -r opt; do
  case "$opt" in -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=*) continue ;; esac
  assert_contains " $mine " " ${opt//\"/} " "san_cxx_args has stage 30's $opt"
done < <(grep -oE -- '-D(LIBUNWIND|LIBCXXABI|LIBCXX)_[A-Z_]+=[^ \\]*' <<< "$stage30" | sed "s/\$t/$G/; s/\"//g; s/\$musl/OFF/")
assert_contains "$mine" "-DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=OFF"

# --- compiler-rt is split between stages 30 and 31, never built twice ---------------------------
# Stage 30: builtins/crt (pass 1), profile + memprof (pass 2, x86_64 gnu). Stage 31: sanitizers and
# libFuzzer only. Each stage's own -D options (later ones override runtimes_common_args).
s30="$(cat "$ROOT_DIR/scripts/stages/30-runtimes.sh")"
s31="$(sed -n '/^build_sanitizer_runtimes()/,/^}/p' "$ROOT_DIR/scripts/stages/31-sanitizer-runtimes.sh")"
for o in BUILTINS=OFF CRT=OFF PROFILE=OFF MEMPROF=OFF XRAY=OFF ORC=OFF CTX_PROFILE=OFF GWP_ASAN=OFF SANITIZERS=ON; do
  assert_contains "$s31" "-DCOMPILER_RT_BUILD_$o" "stage 31 sets COMPILER_RT_BUILD_$o"
done
assert_contains "$s30" "-DCOMPILER_RT_BUILD_SANITIZERS=OFF" "stage 30 leaves sanitizers to stage 31"
assert_contains "$s30" "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF" "stage 30 leaves libFuzzer to stage 31"
assert_contains "$s30" "memprof_args=(-DCOMPILER_RT_BUILD_MEMPROF=ON" "stage 30 keeps the memprof runtime"
assert_not_contains "$s31" "SANITIZER_CXX_ABI=none" "memprof's ABI setting stays in stage 30"
# san_runtimes_base_args is stage 30's runtimes_common_args minus what stage 31/60 set themselves.
common="$(STAGE1_DIR=/s1; source "$ROOT_DIR/scripts/stages/30-runtimes.sh"; runtimes_common_args $G)"
while IFS= read -r opt; do
  assert_contains "$common" "$opt" "san_runtimes_base_args matches stage 30: $opt"
done < <(STAGE1_DIR=/s1 san_runtimes_base_args $G)
for f in "$ROOT_DIR"/scripts/stages/31-sanitizer-runtimes.sh "$ROOT_DIR"/scripts/stages/60-sanitizer-addons.sh; do
  # shellcheck disable=SC2016 # literal source text
  assert_contains "$(cat "$f")" 'apply_patches llvm "$ROOT_DIR/llvm"' "${f##*/} builds from the patched llvm tree"
done

# --- stage 60: instrumented libelidealloc-shim and the sysroot farm (fake compiler and ar) -----
(
  export BUNDLE_DIR="$T/b" BUILD_DIR="$T/build" TOOLCHAIN_ROOT="$T/b"   # as stage_main exports
  # shellcheck source=scripts/stages/60-sanitizer-addons.sh
  source "$ROOT_DIR/scripts/stages/60-sanitizer-addons.sh"
  mkdir -p "$BUNDLE_DIR/bin" "$BUNDLE_DIR/sysroot/$G/usr/lib/pkgconfig" "$BUNDLE_DIR/sysroot/$G/usr/include" "$BUNDLE_DIR/sysroot/$G/lib64"
  # shellcheck disable=SC2016 # fake tools: their $ expand when they run
  printf '#!/bin/sh\necho "$*" >> "%s/cc.log"\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && : > "$2"; shift; done\n' "$T" > "$BUNDLE_DIR/bin/$G-clang++"
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nout=$2; shift 2; cat "$@" > "$out"\n' > "$BUNDLE_DIR/bin/llvm-ar"
  chmod +x "$BUNDLE_DIR/bin/$G-clang++" "$BUNDLE_DIR/bin/llvm-ar"
  sr="$BUNDLE_DIR/sysroot/$G"
  for f in libz.a libzstd.a libcrypto.a libcrypto.so libcrypto.so.1 libmimalloc.a libelidealloc-shim.a libc.so; do echo base > "$sr/usr/lib/$f"; done
  echo pc > "$sr/usr/lib/pkgconfig/zlib.pc"; ln -s ../lib/ld-linux-x86-64.so.2 "$sr/lib64/ld-linux-x86-64.so.2"
  build_variant_elidealloc_shim $G msan
  log="$(cat "$T/cc.log")"
  assert_contains "$log" "--config=$BUNDLE_DIR/share/elide-toolchain/sanitizers/$G-msan.cfg" "shim compiled with the msan layer"
  assert_contains "$log" "backend-forward.cc"
  assert_not_contains "$log" "backend-mimalloc.cc" "variant shim never uses mi_heap_*"
  assert_contains "$log" "-flto=thin"
  v="$(variant_dir $G msan)/usr/lib"
  assert_file "$v/libelidealloc-shim.a"
  for f in libz.a libcrypto.a libmimalloc.a; do echo inst > "$v/$f"; done
  echo extra > "$v/libnotinbase.a"
  assemble_variant_sysroot $G msan
  farm="$BUNDLE_DIR/sysroot/$G+msan"
  for f in libz.a libcrypto.a libmimalloc.a libelidealloc-shim.a; do
    assert_ok test -f "$farm/usr/lib/$f"; assert_fails test -L "$farm/usr/lib/$f"
  done
  assert_eq "$(cat "$farm/usr/lib/libz.a")" "inst"
  assert_eq "$(readlink "$farm/usr/lib/libzstd.a")" "../../../$G/usr/lib/libzstd.a" "unreplaced archives are relative links"
  assert_eq "$(cat "$farm/usr/lib/libzstd.a")" "base"
  assert_fails test -e "$farm/usr/lib/libcrypto.so"   # no .so beside a replaced .a (lld prefers .so)
  assert_fails test -e "$farm/usr/lib/libcrypto.so.1"
  assert_ok test -L "$farm/usr/lib/libc.so"
  assert_fails test -e "$farm/usr/lib/libnotinbase.a"  # only archives the base ships are replaced
  assert_eq "$(readlink "$farm/usr/include")" "../../$G/usr/include"
  assert_eq "$(readlink "$farm/lib64")" "../$G/lib64"
  assert_eq "$(cat "$farm/usr/lib/pkgconfig/zlib.pc")" "pc"
  assert_eq "$(find "$farm" -type l -lname '/*' | head -1)" "" "farm symlinks are relative"
  # a bundle without libelidealloc-shim (stage 35 not run) gets none in the add-on
  rm -f "$sr/usr/lib/libelidealloc-shim.a" "$v/libelidealloc-shim.a"
  build_variant_elidealloc_shim $G tsan
  assert_fails test -e "$(variant_dir $G tsan)/usr/lib/libelidealloc-shim.a"
  [ "$FAILURES" -eq 0 ]
) || _fail "stage 60 farm/shim tests (see above)"

# --- compile layer and recipe hooks --------------------------------------------------------------
TOOLCHAIN_ROOT=/tc
assert_not_contains "$(target_cflags $G)" "--config="
assert_contains "$(SANITIZER_LAYER=msan target_cflags $G)" \
  "--config=/tc/share/elide-toolchain/sanitizers/$G-msan.cfg -L/tc/lib/$G/msan"
assert_contains "$(SANITIZER_LAYER=asan target_cflags $G)" "-isystem /tc/include/$G/asan/c++/v1"
assert_eq "$(component_variant_args aws-lc)" ""
assert_eq "$(SANITIZER_LAYER=msan component_variant_args aws-lc)" "-DOPENSSL_NO_ASM=1"
assert_eq "$(SANITIZER_LAYER=asan component_variant_args aws-lc)" ""
assert_eq "$(SANITIZER_LAYER=msan component_variant_args openssl)" "no-asm"

# --- front-ends ----------------------------------------------------------------------------------
assert_eq "$(render_san_cfg $G msan | xargs)" "-fsanitize=memory -fsanitize-memory-track-origins -fno-omit-frame-pointer"
assert_contains "$(render_san_addon_cfg $G asan)" "--sysroot=<CFGDIR>/../../../sysroot/$G+asan"
assert_contains "$(render_san_addon_cfg $G asan)" "-isystem <CFGDIR>/../../../include/$G/asan/c++/v1"
assert_not_contains "$(render_san_addon_cfg $G msan)" "-isystem"
cm="$(render_san_toolchain_cmake $G tsan)"
assert_contains "$cm" "bin/$G-tsan-clang\""
assert_contains "$cm" "bin/$G-tsan-clang++\""
assert_contains "$cm" "if(EXISTS \"\${_ET_ROOT}/sysroot/$G+tsan/usr/lib\")"
assert_not_contains "$(render_san_toolchain_cmake arm64-apple-darwin asan)" "CMAKE_SYSROOT"
if command -v shellcheck >/dev/null 2>&1; then
  for s in asan msan; do
    render_san_wrapper $G $s clang > "$T/w-$s.sh"
    assert_ok shellcheck -s sh "$T/w-$s.sh"
  done
fi

# wrappers in a prefix whose path has a space; fake clang echoes its argv
P="$T/pre fix"; mkdir -p "$P/bin"
printf '#!/bin/sh\necho "clang $*"\n' > "$P/bin/clang"; chmod +x "$P/bin/clang"
printf '#!/bin/sh\necho "clang++ $*"\n' > "$P/bin/clang++"; chmod +x "$P/bin/clang++"
install_frontends "$P"
Pr="$(cd "$P" && pwd -P)"
for f in $G-asan-clang $G-msan-clang++ $G-lsan-clang $M-ubsan-clang; do assert_file "$P/bin/$f"; done
assert_fails test -e "$P/bin/$M-asan-clang"
assert_file "$P/share/elide-toolchain/cmake/$G-asan.cmake"
out="$("$P/bin/$G-asan-clang" -c a.c)"
assert_contains "$out" "--config=$Pr/bin/../share/elide-toolchain/sanitizers/$G-asan.cfg"
assert_not_contains "$out" "addon.cfg" "no add-on layer before the add-on is installed"
assert_fails "$P/bin/$G-msan-clang" -c a.c
install_sanitizer_addon_frontends "$P" $G msan
out="$("$P/bin/$G-msan-clang" -c a.c)"
assert_contains "$out" "$G-msan.addon.cfg"
assert_contains "$out" "-c a.c"
assert_contains "$("$P/bin/$G-msan-clang++" -x c++ y.cc)" "clang++ --config="

# --- packaging metadata --------------------------------------------------------------------------
export BUILD_SANITIZER_VARIANTS=yes
assert_eq "$(addon_asset_name tsan)" "elide-toolchain-$TOOLCHAIN_VERSION-linux-amd64-sanitizer-tsan.tar.xz"
ap="$(addon_paths asan)"
assert_contains "$ap" "elide-toolchain/sysroot/$G+asan"
assert_contains "$ap" "elide-toolchain/lib/$G/asan"
assert_contains "$ap" "elide-toolchain/include/$G/asan"
assert_contains "$ap" "elide-toolchain/share/elide-toolchain/sanitizers/asan.addon.json"
assert_not_contains "$(addon_paths msan)" "include/"
dupes="$(for s in asan tsan msan; do addon_paths "$s"; done | sort | uniq -d)"
assert_eq "$dupes" "" "add-on path sets are disjoint"
assert_contains "$(addon_excludes | head -1)" "--exclude=elide-toolchain/"
assert_eq "$(addon_json msan | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["sanitizer"], d["version"]==sys.argv[1], d["triples"])' "$TOOLCHAIN_VERSION")" \
  "msan True ['$G']"
mj="$(sanitizer_manifest_json)"
assert_eq "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["sanitizers"][sys.argv[2]]["addons"], d["sanitizers"][sys.argv[3]]["runtimes"], sorted(d["addons"]))' "$mj" $G $M)" \
  "['asan', 'tsan', 'msan'] ['ubsan'] ['asan', 'msan', 'tsan']"
assert_contains "$(BUILD_SANITIZER_VARIANTS=no sanitizer_manifest_json)" '"addons": {}'
assert_contains "$(SANITIZER_MANIFEST="$mj" ENABLED_COMPONENTS=zstd python3 "$ROOT_DIR/scripts/gen-manifest.py" manifest)" '"sanitizers"'

# prune keeps non-sanitizer runtimes and drops the ones the matrix does not ship
rd="$T/prune/lib/clang/$LLVM_MAJOR/lib/$M"; mkdir -p "$rd"
for r in builtins profile memprof asan lsan ubsan_standalone ubsan_minimal stats fuzzer dd; do : > "$rd/libclang_rt.$r.a"; done
: > "$rd/libclang_rt.ubsan_standalone.so"
prune_sanitizer_runtimes "$T/prune" $M
assert_eq "$(find "$rd" -type f -printf '%f\n' | sort | xargs)" "libclang_rt.builtins.a libclang_rt.memprof.a libclang_rt.profile.a libclang_rt.ubsan_minimal.a libclang_rt.ubsan_standalone.a"

rm -rf "$T"
finish
