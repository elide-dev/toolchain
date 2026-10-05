# shellcheck shell=bash
# Sanitizer verification (spec 2026-10-05 §8). Sourced by scripts/verify/checks.sh; uses its
# pass/fail helpers. run_sanitizer_checks covers the main bundle per triple;
# run_sanitizer_addon_checks extracts each add-on over its own hardlinked copy of the verified
# main bundle (proving add-ons are independent of each other) and checks it there.

SAN_FIXTURES="$ROOT_DIR/tests/fixtures/sanitizers"

run_sanitizer_checks() { # ROOT TRIPLE
  local root="$1" t="$2"
  [ -n "$(triple_sanitizers "$t")" ] || return 0
  case "$(triple_os "$t")" in
    linux) check_sanitizer_runtimes "$root" "$t" ;;
    darwin) check_darwin_sanitizers "$root" ;;
  esac
  check_sanitizer_trips "$root" "$t" "" main
  if [ "$(triple_libc "$t")" = gnu ]; then
    check_sanitizer_static_policy "$root" "$t"
    check_sanitizer_shared "$root" "$t"
  fi
  if triple_has_libfuzzer "$t"; then check_libfuzzer "$root" "$t"; fi
}

# check_sanitizer_runtimes ROOT TRIPLE — shipped runtimes match the matrix; musl ships no
# dynamic-only sanitizer (musl is static-only by design).
check_sanitizer_runtimes() {
  local root="$1" t="$2" rd s r missing="" name="sanitizer runtimes $2" names=""
  rd="$root/lib/clang/$LLVM_MAJOR/lib/$t"
  for s in $(triple_sanitizers "$t"); do names="$names $(san_runtimes "$s")"; done
  if triple_has_libfuzzer "$t"; then names="$names $(san_runtimes fuzzer)"; fi
  for r in $names; do [ -f "$rd/libclang_rt.$r.a" ] || missing="$missing $r"; done
  for r in include/sanitizer/common_interface_defs.h include/sanitizer/asan_interface.h; do
    [ -f "$root/lib/clang/$LLVM_MAJOR/$r" ] || missing="$missing $r"
  done
  if [ "$(triple_libc "$t")" = gnu ]; then
    for r in asan tsan ubsan_standalone; do [ -f "$rd/libclang_rt.$r.so" ] || missing="$missing $r.so"; done
  fi
  if [ "$(triple_libc "$t")" = musl ] && find "$rd" -name 'libclang_rt.*' | grep -qE 'libclang_rt\.(asan|tsan|msan|lsan|hwasan)'; then
    missing="$missing (dynamic-only sanitizer runtime present for musl)"
  fi
  if [ -z "$missing" ]; then pass "$name"; else fail "$name" "missing:$missing"; fi
}

check_darwin_sanitizers() {
  local root="$1" d s missing=""
  d="$root/lib/clang/$LLVM_MAJOR/lib/darwin"
  for s in asan tsan ubsan; do [ -f "$d/libclang_rt.${s}_osx_dynamic.dylib" ] || missing="$missing $s"; done
  [ -f "$d/libclang_rt.fuzzer_osx.a" ] || missing="$missing fuzzer"
  if [ -z "$missing" ]; then pass "sanitizer runtimes darwin"; else fail "sanitizer runtimes darwin" "missing:$missing"; fi
}

hwasan_kernel_ok() { # PR_GET_TAGGED_ADDR_CTRL (56) succeeds only with the tagged-address ABI
  [ "$(uname -m)" = aarch64 ] || return 1
  python3 -c 'import ctypes,sys; sys.exit(0 if ctypes.CDLL(None).prctl(56,0,0,0,0) >= 0 else 1)' 2>/dev/null
}

# check_sanitizer_trips ROOT TRIPLE [SANS] [LABEL] — each sanitizer's wrapper builds the fixture
# bug and the runtime reports it. In the main bundle (no add-on) the msan wrapper must refuse.
check_sanitizer_trips() {
  local root="$1" t="$2" sans="${3:-}" label="${4:-main}" s tmp static=() expect name
  [ -n "$sans" ] || sans="$(triple_sanitizers "$t")"
  tmp="$(mktemp -d)"
  if [ "$(triple_libc "$t")" = musl ]; then static=(-static); fi
  for s in $sans; do
    name="sanitizer $s trips $t ($label)"
    if [ "$s" = msan ] && [ ! -f "$(san_cfg_dir "$root")/$t-msan.addon.cfg" ]; then
      if "$root/bin/$t-msan-clang" -c "$SAN_FIXTURES/msan.c" -o "$tmp/m.o" 2>/dev/null; then
        fail "sanitizer msan refuses without add-on $t" "wrapper compiled without the add-on"
      else
        pass "sanitizer msan refuses without add-on $t"
      fi
      continue
    fi
    if [ "$s" = hwasan ] && ! hwasan_kernel_ok; then
      printf 'note  %s: kernel lacks the tagged-address ABI; skipped\n' "$name"; continue
    fi
    expect="$(san_report "$s")"
    if ! "$root/bin/$t-$s-clang" "${static[@]}" -g -fno-sanitize-recover=all \
         "$SAN_FIXTURES/$s.c" -o "$tmp/$s" 2>"$tmp/$s.err"; then
      fail "$name" "build: $(head -3 "$tmp/$s.err")"; continue
    fi
    if ASAN_OPTIONS=detect_leaks=1 "$tmp/$s" >"$tmp/$s.log" 2>&1; then
      fail "$name" "exited 0 without a report"
    elif grep -qF "$expect" "$tmp/$s.log"; then
      pass "$name"
    else
      fail "$name" "no '$expect' in: $(head -c 200 "$tmp/$s.log" | tr '\n' ' ')"
    fi
  done
  rm -rf "$tmp"
}

# run_sanitizer_relocated_checks MOVED — the wrappers and cfg layers resolve from a moved bundle
# whose path contains a space: asan on gnu, static ubsan on musl (check_relocatable calls this).
run_sanitizer_relocated_checks() {
  local moved="$1" t s
  for t in $ALL_TARGETS; do
    case "$(triple_libc "$t")" in gnu) s=asan ;; musl) s=ubsan ;; *) continue ;; esac
    case " $(triple_sanitizers "$t") " in *" $s "*) check_sanitizer_trips "$moved" "$t" "$s" relocated ;; esac
  done
  check_doctor_sanitizers "$moved" relocated
}

# check_doctor_sanitizers ROOT LABEL — `elide-toolchain doctor --sanitizers` passes on ROOT.
check_doctor_sanitizers() {
  local root="$1" out name="doctor --sanitizers ($2)"
  [ -n "$(ls "$(san_cfg_dir "$root")"/*.cfg 2>/dev/null)" ] || return 0
  if out="$("$root/bin/elide-toolchain" doctor --sanitizers 2>&1)"; then pass "$name"; else fail "$name" "$(grep -m3 FAIL <<< "$out")"; fi
}

# check_sanitizer_static_policy ROOT TRIPLE — gnu: the dynamic-only runtimes refuse -static and the
# helper refuses --static with them.
check_sanitizer_static_policy() {
  local root="$1" t="$2" tmp name="sanitizer static policy $2"
  tmp="$(mktemp -d)"
  if "$root/bin/$t-asan-clang" -static "$SAN_FIXTURES/asan.c" -o "$tmp/a" 2>/dev/null; then
    fail "$name" "asan -static linked (expected an error)"
  elif "$root/bin/elide-toolchain" env --target "$t" --sanitizer asan --static >/dev/null 2>&1; then
    fail "$name" "helper accepted --static --sanitizer asan"
  else
    pass "$name"
  fi
  rm -rf "$tmp"
}

# check_sanitizer_shared ROOT TRIPLE — JNI shape: a -shared-libsan .so dlopen'ed by an
# uninstrumented host trips with the runtime from `env --sanitizer asan` LD_PRELOADed.
check_sanitizer_shared() {
  local root="$1" t="$2" tmp rt name="sanitizer shared runtime $2"
  tmp="$(mktemp -d)"
  rt="$("$root/bin/elide-toolchain" env --target "$t" --sanitizer asan --format json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ELIDE_SANITIZER_RUNTIME",""))' 2>/dev/null || true)"
  if [ -z "$rt" ] || [ ! -f "$rt" ]; then
    fail "$name" "helper reports no ELIDE_SANITIZER_RUNTIME ($rt)"; rm -rf "$tmp"; return
  fi
  if "$root/bin/$t-clang" -fsanitize=address -shared-libsan -shared -fPIC -g \
       "$SAN_FIXTURES/jni-lib.c" -o "$tmp/libnative.so" 2>"$tmp/err" \
     && "$root/bin/$t-clang" -g "$SAN_FIXTURES/jni-host.c" -o "$tmp/host" 2>>"$tmp/err" \
     && ! LD_PRELOAD="$rt" ASAN_OPTIONS=detect_leaks=0 "$tmp/host" "$tmp/libnative.so" >"$tmp/log" 2>&1 \
     && grep -q heap-buffer-overflow "$tmp/log"; then
    pass "$name"
  else
    fail "$name" "$(cat "$tmp/err" "$tmp/log" 2>/dev/null | head -3)"
  fi
  rm -rf "$tmp"
}

# check_libfuzzer ROOT TRIPLE — a libFuzzer target links (-fsanitize=fuzzer,address) and runs.
check_libfuzzer() {
  local root="$1" t="$2" tmp name="libfuzzer $2"
  tmp="$(mktemp -d)"
  if "$root/bin/$t-clang" -g -fsanitize=fuzzer,address "$SAN_FIXTURES/fuzz.c" -o "$tmp/fuzz" 2>"$tmp/err" \
     && (cd "$tmp" && ./fuzz -runs=2000 -seed=1 >"$tmp/log" 2>&1) && grep -q 'Done 2000 runs' "$tmp/log"; then
    pass "$name"
  else
    fail "$name" "$(cat "$tmp/err" "$tmp/log" 2>/dev/null | tail -3)"
  fi
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------------------------
# Add-ons.

run_sanitizer_addon_checks() { # ROOT (the extracted, already verified main bundle)
  local root="$1" s archive tree t main_list
  [ -n "$(all_variants)" ] || return 0
  main_list="$VERIFY_DIR/main.list"
  tar -tJf "$DIST_DIR/$TOOLCHAIN_NAME-$TOOLCHAIN_VERSION-$HOST_OS-$HOST_ARCH.tar.xz" | sed 's#/$##' | sort -u > "$main_list"
  for s in $(all_variants); do
    archive="$DIST_DIR/$(addon_asset_name "$s")"
    if [ ! -f "$archive" ] || [ "$(awk '{print $1}' "$archive.sha256" 2>/dev/null)" != "$(sha256_of "$archive")" ]; then
      fail "sanitizer add-on $s" "missing or bad checksum: $archive"; continue
    fi
    check_addon_archive "$archive" "$main_list" "$s"
    tree="$VERIFY_DIR/addon-$s"
    rm -rf "$tree"; mkdir -p "$tree"
    cp -al "$root" "$tree/$TOOLCHAIN_NAME"
    tar -C "$tree" -xJf "$archive"
    for t in $ALL_TARGETS; do
      case " $(triple_variants "$t") " in *" $s "*) ;; *) continue ;; esac
      check_addon_layout "$tree/$TOOLCHAIN_NAME" "$t" "$s"
      check_sanitizer_trips "$tree/$TOOLCHAIN_NAME" "$t" "$s" "add-on"
      check_addon_clean "$tree/$TOOLCHAIN_NAME" "$t" "$s"
      check_addon_cmake "$tree/$TOOLCHAIN_NAME" "$t" "$s"
      check_addon_bitcode "$tree/$TOOLCHAIN_NAME" "$t" "$s"
      check_addon_mimalloc "$tree/$TOOLCHAIN_NAME" "$t" "$s"
      check_addon_elidealloc "$tree/$TOOLCHAIN_NAME" "$t" "$s"
      check_addon_env "$tree/$TOOLCHAIN_NAME" "$t" "$s"
      if [ "$s" = asan ]; then check_rust_sanitizer "$tree/$TOOLCHAIN_NAME" "$t"; fi
    done
    check_doctor_sanitizers "$tree/$TOOLCHAIN_NAME" "add-on $s"
    rm -rf "$tree"
  done
}

# check_addon_archive ARCHIVE MAIN_LIST SAN — one elide-toolchain/ root and no entry shared with the
# main archive: extraction never overwrites a main-bundle file, so add-ons are independent.
check_addon_archive() {
  local archive="$1" list="$2" name="sanitizer add-on $3 archive" members dup
  members="$(tar -tJf "$archive" | sed 's#/$##' | sort -u)"
  if grep -qv "^$TOOLCHAIN_NAME/" <<< "$members"; then fail "$name" "entry outside $TOOLCHAIN_NAME/"; return; fi
  dup="$(comm -12 "$list" - <<< "$members")"
  if [ -z "$dup" ]; then pass "$name"; else fail "$name" "overlaps the main archive: $(head -3 <<< "$dup" | xargs)"; fi
}

# check_addon_layout ROOT TRIPLE SAN — instrumented archives, no libunwind, sound farm, metadata.
check_addon_layout() {
  local root="$1" t="$2" s="$3" farm d f bad="" sym name="sanitizer add-on $3 layout $2"
  farm="$root/sysroot/$t+$s"; d="$root/lib/$t/$s"; sym="$(san_symbol "$s")"
  [ -d "$farm/usr/lib" ] || { fail "$name" "no $farm"; return; }
  [ ! -e "$d/libunwind.a" ] || bad="${bad}instrumented libunwind.a shipped; "
  for f in "$d"/libc++.a "$d"/libc++abi.a; do
    [ -f "$f" ] || { bad="${bad}missing ${f##*/}; "; continue; }
    "$root/bin/llvm-nm" "$f" 2>/dev/null | grep -q "$sym" || bad="${bad}${f##*/} not instrumented; "
  done
  while IFS= read -r f; do
    "$root/bin/llvm-nm" "$f" 2>/dev/null | grep -q "$sym" || bad="${bad}${f#"$farm"/} not instrumented; "
    if [ -e "${f%.a}.so" ] || [ -L "${f%.a}.so" ]; then bad="${bad}${f#"$farm"/}: .so beside replaced .a; "; fi
  done < <(find "$farm/usr/lib" -maxdepth 1 -name '*.a' -type f)
  if [ -n "$(find -L "$farm" -maxdepth 3 -type l 2>/dev/null | head -1)" ]; then bad="${bad}dangling farm symlinks; "; fi
  if [ -n "$(find "$farm" -type l -lname '/*' | head -1)" ]; then bad="${bad}absolute farm symlinks; "; fi
  grep -q "\"version\": \"$TOOLCHAIN_VERSION\"" "$(san_cfg_dir "$root")/$s.addon.json" 2>/dev/null \
    || bad="${bad}$s.addon.json missing or wrong version; "
  [ -f "$(san_cfg_dir "$root")/$t-$s.addon.cfg" ] || bad="${bad}no add-on cfg; "
  if [ "$s" = asan ]; then
    grep -q '_LIBCPP_INSTRUMENTED_WITH_ASAN 1' "$root/include/$t/asan/c++/v1/__config_site" 2>/dev/null \
      || bad="${bad}asan __config_site; "
  fi
  if [ -z "$bad" ]; then pass "$name"; else fail "$name" "$bad"; fi
}

# check_addon_clean ROOT TRIPLE SAN — the false-positive check: libc++ and every enabled component
# through the wrapper, with and without -flto=thin, must run without a report.
check_addon_clean() {
  local root="$1" t="$2" s="$3" tmp c link defs=() libs=() more=() lto name
  for c in $(enabled_components); do
    link="$(component_link "$c")"; [ -n "$link" ] || continue
    defs+=("-D${link%%|*}"); read -r -a more <<< "${link#*|}"; libs+=("${more[@]}")
    if [ "$c" = brotli ]; then libs+=(-lbrotlienc); fi
  done
  defs+=(-DHAVE_MIMALLOC); libs+=(-lmimalloc)
  tmp="$(mktemp -d)"
  for lto in "" -flto=thin; do
    name="sanitizer add-on $s clean $t${lto:+ (thinlto)}"
    # shellcheck disable=SC2086
    if "$root/bin/$t-$s-clang++" -g $lto "$SAN_FIXTURES/clean.cpp" -o "$tmp/cxx" 2>"$tmp/err" \
       && "$root/bin/$t-$s-clang++" -g $lto "${defs[@]}" -x c "$SAN_FIXTURES/workload.c" -x none \
            "${libs[@]}" -lpthread -o "$tmp/w" 2>>"$tmp/err" \
       && "$root/bin/$t-$s-clang" -g $lto "$SAN_FIXTURES/mimalloc-api.c" -lmimalloc -o "$tmp/mi" 2>>"$tmp/err" \
       && "$tmp/cxx" >"$tmp/log" 2>&1 && "$tmp/w" >>"$tmp/log" 2>&1 && "$tmp/mi" >>"$tmp/log" 2>&1 \
       && ! grep -qE 'Sanitizer|runtime error' "$tmp/log"; then
      pass "$name"
    else
      fail "$name" "$(grep -m3 -hE 'error|Sanitizer|MISMATCH' "$tmp/err" "$tmp/log" 2>/dev/null | head -3)"
    fi
  done
  rm -rf "$tmp"
}

# check_addon_cmake ROOT TRIPLE SAN — find_package/find_library resolve the add-on sysroot.
check_addon_cmake() {
  local root="$1" t="$2" s="$3" tmp out name="sanitizer add-on $3 cmake $2"
  tmp="$(mktemp -d)"
  if out="$(cmake -S "$SAN_FIXTURES/cmake" -B "$tmp/b" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
              -DCMAKE_TOOLCHAIN_FILE="$root/share/elide-toolchain/cmake/$t-$s.cmake" 2>&1)" \
     && grep -q "ELIDE_ZLIB=.*/sysroot/$t+$s/usr/lib/libz.a" <<< "$out" \
     && grep -q "ELIDE_ZSTD=.*/sysroot/$t+$s/usr/lib/libzstd.a" <<< "$out" \
     && cmake --build "$tmp/b" >"$tmp/build.log" 2>&1 && "$tmp/b/consumer" >"$tmp/run.log" 2>&1; then
    pass "$name"
  else
    fail "$name" "$(grep -hE 'ELIDE_|Error|error|Sanitizer' <<< "$out" "$tmp/build.log" "$tmp/run.log" 2>/dev/null | head -3)"
  fi
  rm -rf "$tmp"
}

# check_addon_bitcode ROOT TRIPLE SAN — the farm's real archives obey base spec §3.3a (check_bitcode
# over a view whose sysroot/<T> is the farm; symlinked base archives are skipped as non-files).
check_addon_bitcode() {
  local root="$1" t="$2" s="$3" view
  view="$(mktemp -d)"
  mkdir -p "$view/sysroot" "$view/lib/$t"
  ln -s "$root/bin" "$view/bin"
  ln -s "$root/sysroot/$t+$s" "$view/sysroot/$t"
  check_bitcode "$view" "$t" > "$view.out"
  sed "s/bitcode $t/sanitizer add-on $s bitcode $t/" "$view.out"
  rm -f "$view.out"
  rm -rf "$view"
}

# check_addon_mimalloc ROOT TRIPLE SAN — mi_* allocations are visible to ASan through the shim.
check_addon_mimalloc() {
  local root="$1" t="$2" s="$3" tmp name="sanitizer add-on $3 mimalloc $2"
  [ "$s" = asan ] || return 0
  tmp="$(mktemp -d)"
  if "$root/bin/$t-asan-clang" -g "$SAN_FIXTURES/mimalloc-oob.c" -lmimalloc -o "$tmp/oob" 2>"$tmp/err" \
     && ! "$tmp/oob" >"$tmp/log" 2>&1 && grep -q heap-buffer-overflow "$tmp/log"; then
    pass "$name"
  else
    fail "$name" "$(cat "$tmp/err" "$tmp/log" 2>/dev/null | head -3)"
  fi
  rm -rf "$tmp"
}

# check_addon_elidealloc ROOT TRIPLE SAN — the add-on's libelidealloc-shim (forward backend, see
# stage 60) links with the pkg-config libs through the wrapper and passes its behaviour test clean.
check_addon_elidealloc() {
  local root="$1" t="$2" s="$3" tmp name="sanitizer add-on $3 elidealloc-shim $2"
  [ -f "$root/sysroot/$t+$s/usr/lib/libelidealloc-shim.a" ] || return 0
  tmp="$(mktemp -d)"
  if "$root/bin/$t-$s-clang++" -g "$ROOT_DIR/tests/fixtures/elidealloc-shim-test.cc" \
       -lelidealloc-shim -lmimalloc -o "$tmp/t" 2>"$tmp/err" \
     && "$tmp/t" >"$tmp/log" 2>&1 && ! grep -qE 'Sanitizer|runtime error' "$tmp/log"; then
    pass "$name"
  else
    fail "$name" "$(cat "$tmp/err" "$tmp/log" 2>/dev/null | grep -m3 -E 'error|FAIL|Sanitizer|undefined')"
  fi
  rm -rf "$tmp"
}

# check_addon_env ROOT TRIPLE SAN — the helper points CC and pkg-config at the add-on.
check_addon_env() {
  local root="$1" t="$2" s="$3" out name="sanitizer add-on $3 env $2"
  out="$("$root/bin/elide-toolchain" env --target "$t" --sanitizer "$s" --format json 2>&1)"
  if grep -q "\"PKG_CONFIG_SYSROOT_DIR\":\"[^\"]*/sysroot/$t+$s\"" <<< "$out" \
     && grep -q "\"CC\":\"[^\"]*/bin/$t-$s-clang\"" <<< "$out"; then
    pass "$name"
  else
    fail "$name" "$(head -c 300 <<< "$out")"
  fi
}

# check_rust_sanitizer ROOT TRIPLE — Rust nightly + C under ASan with one runtime (clang's):
# -Zsanitizer=address -Zexternal-clangrt, linked by <T>-asan-clang. Skipped without a nightly
# rustc whose LLVM major is <= LLVM_MAJOR, or without that target's std.
check_rust_sanitizer() {
  local root="$1" t="$2" rustc=() vv major tmp rt name="rust sanitizer $2"
  rt="$(rust_triple "$t")"
  if command -v rustc >/dev/null 2>&1 && rustc -vV 2>/dev/null | grep -q '^release:.*nightly'; then
    rustc=(rustc)
  elif command -v rustup >/dev/null 2>&1 && rustup run nightly rustc -vV >/dev/null 2>&1; then
    rustc=(rustup run nightly rustc)
  else
    printf 'note  %s: no nightly rustc; skipped\n' "$name"; return 0
  fi
  vv="$("${rustc[@]}" -vV 2>/dev/null)"
  major="$(sed -n 's/^LLVM version: \([0-9]*\).*/\1/p' <<< "$vv")"
  if [ -z "$major" ] || [ "$major" -gt "$LLVM_MAJOR" ]; then
    printf 'note  %s: nightly LLVM %s > %s; skipped\n' "$name" "$major" "$LLVM_MAJOR"; return 0
  fi
  if [ ! -d "$("${rustc[@]}" --print sysroot 2>/dev/null)/lib/rustlib/$rt" ]; then
    printf 'note  %s: no nightly std for %s; skipped\n' "$name" "$rt"; return 0
  fi
  tmp="$(mktemp -d)"
  if "$root/bin/$t-asan-clang" -g -c "$SAN_FIXTURES/rust/c_part.c" -o "$tmp/c_part.o" 2>"$tmp/err" \
     && "$root/bin/llvm-ar" rcs "$tmp/libcpart.a" "$tmp/c_part.o" \
     && "${rustc[@]}" --edition 2021 -g --target "$rt" -Zsanitizer=address -Zexternal-clangrt \
          -Clinker="$root/bin/$t-asan-clang" -L "$tmp" -l static=cpart "$SAN_FIXTURES/rust/main.rs" \
          -o "$tmp/main" 2>>"$tmp/err" \
     && "$tmp/main" >/dev/null 2>&1 \
     && ! "$tmp/main" trip >"$tmp/log" 2>&1 && grep -q heap-buffer-overflow "$tmp/log"; then
    pass "$name"
  else
    fail "$name" "$(cat "$tmp/err" "$tmp/log" 2>/dev/null | grep -m3 -E 'error|Sanitizer|undefined')"
  fi
  rm -rf "$tmp"
}
