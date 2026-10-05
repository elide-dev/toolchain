# shellcheck shell=bash
# Bundle verification (spec §6). Operates on an extracted bundle ROOT, never on the build tree.

VERIFY_FAILURES=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }

smoke_dir() { printf '%s/smoke/%s\n' "$VERIFY_DIR" "$1"; }

# check_smoke ROOT TRIPLE — C and C++ hello-worlds compile, link and run (musl: fully static).
check_smoke() {
  local root="$1" t="$2" d static=() name="smoke $2${3:+ ($3)}"
  d="$(smoke_dir "$t")${3:+-$3}"
  mkdir -p "$d"
  if [ "$(triple_libc "$t")" = musl ]; then static=(-static); fi
  if ! "$root/bin/$t-clang" "${static[@]}" "$ROOT_DIR/tests/fixtures/hello.c" -o "$d/hello-c" 2>"$d/err"; then
    fail "$name" "C compile: $(head -3 "$d/err")"; return
  fi
  if ! "$root/bin/$t-clang++" "${static[@]}" "$ROOT_DIR/tests/fixtures/hello.cpp" -o "$d/hello-cxx" 2>"$d/err"; then
    fail "$name" "C++ compile: $(head -3 "$d/err")"; return
  fi
  if [ "$("$d/hello-c")" != "hello from elide-toolchain" ] || [ "$("$d/hello-cxx")" != "hello from elide-toolchain" ]; then
    fail "$name" "programs did not print the expected output"; return
  fi
  if [ "$(triple_libc "$t")" = musl ] && [ -n "$(interp_of "$d/hello-c")" ]; then
    fail "$name" "musl output is not static"; return
  fi
  pass "$name"
}

check_werror() {
  local root="$1" t="$2" tmp
  tmp="$(mktemp -d)"
  if "$root/bin/$t-clang" -Werror -c "$ROOT_DIR/tests/fixtures/hello.c" -o "$tmp/h.o" 2>"$tmp/err"; then
    pass "werror $t"
  else
    fail "werror $t" "$(head -3 "$tmp/err")"
  fi
  rm -rf "$tmp"
}

check_components() {
  local root="$1" t="$2" c link defs=() libs=() more=() static=() tmp
  for c in $(enabled_components); do
    link="$(component_link "$c")"
    [ -n "$link" ] || continue
    defs+=("-D${link%%|*}")
    read -r -a more <<< "${link#*|}"
    libs+=("${more[@]}")
  done
  if [ "$(triple_libc "$t")" != musl ]; then defs+=(-DHAVE_MIMALLOC); libs+=(-lmimalloc); else static=(-static); fi
  if [ "$(triple_os "$t")" = linux ]; then
    local i
    for i in "${!libs[@]}"; do
      case "${libs[$i]}" in -lssl) libs[i]=-l:libssl.a ;; -lcrypto) libs[i]=-l:libcrypto.a ;; esac
    done
  fi
  tmp="$(mktemp -d)"
  if "$root/bin/$t-clang" "${defs[@]}" -c "$ROOT_DIR/tests/fixtures/components.c" -o "$tmp/c.o" 2>"$tmp/err" \
    && "$root/bin/$t-clang++" "${static[@]}" "$tmp/c.o" "${libs[@]}" -lpthread -o "$tmp/c" 2>>"$tmp/err" \
    && "$tmp/c" >/dev/null 2>>"$tmp/err"; then
    pass "components $t"
  else
    fail "components $t" "$(head -5 "$tmp/err")"
  fi
  rm -rf "$tmp"
}

# check_glibc_floor ROOT TRIPLE — shipped tools, gnu-sysroot shared objects (excluding glibc's
# own files) and smoke outputs need nothing newer than GLIBC_FLOOR, and no libstdc++/libgcc_s.
check_glibc_floor() {
  local root="$1" t="$2" f rel v out="" sysroot
  sysroot="$root/sysroot/$t"
  while IFS= read -r f; do
    is_elf "$f" || continue
    rel="${f#"$sysroot"/}"
    if [ "$f" != "$rel" ] && grep -qxF "$rel" "$OUT_DIR/glibc-files.txt"; then continue; fi
    v="$(glibc_floor_violations "$f")"
    [ -z "$v" ] || out="$out$v"$'\n'
    case " $(needed_libs "$f" | xargs) " in
      *" libstdc++"*|*" libgcc_s"*) out="$out$f: needs libstdc++/libgcc_s"$'\n' ;;
    esac
  done < <(find "$root/bin" "$root/lib" "$sysroot/usr/lib" "$(smoke_dir "$t")" -type f \( -perm -u+x -o -name '*.so*' \) 2>/dev/null)
  if [ -z "$out" ]; then pass "glibc floor $t"; else fail "glibc floor $t" "$(printf '%s' "$out" | head -10)"; fi
}

check_interp() {
  local t="$2" want got
  want="/$(glibc_loader "$(triple_cpu "$t")")"
  got="$(interp_of "$(smoke_dir "$t")/hello-c")"
  if [ "$got" = "$want" ]; then pass "interp $t"; else fail "interp $t" "PT_INTERP $got, want $want"; fi
}

check_musl_libc() {
  local root="$1" t="$2" lib tmp member sections
  lib="$root/sysroot/$t/usr/lib/libc.a"
  tmp="$(mktemp -d)"
  member="$("$root/bin/llvm-ar" t "$lib" | grep '^printf\.' | head -1 || true)"
  [ -n "$member" ] || { fail "musl libc $t" "no printf member in $lib"; rm -rf "$tmp"; return; }
  (cd "$tmp" || exit 1; "$root/bin/llvm-ar" x "$lib" "$member")
  sections="$("$root/bin/llvm-readelf" -S "$tmp/$member")"
  if is_yes "$MUSL_USE_LTO"; then
    case "$sections" in *.llvm.lto*) ;; *) fail "musl libc $t" "no .llvm.lto section in $member"; rm -rf "$tmp"; return ;; esac
    "$root/bin/llvm-objcopy" --dump-section ".llvm.lto=$tmp/bc" "$tmp/$member" "$tmp/discard.o"
    if ! "$root/bin/llvm-dis" "$tmp/bc" -o - 2>/dev/null | grep -q "target triple = \"$t\""; then
      fail "musl libc $t" "bitcode triple is not $t"; rm -rf "$tmp"; return
    fi
  fi
  local textsz syms
  textsz="$("$root/bin/llvm-size" "$tmp/$member" 2>/dev/null | awk 'NR==2{print $1}')"
  syms="$("$root/bin/llvm-nm" --defined-only "$tmp/$member" 2>/dev/null | awk '$2=="T"' | head -1)"
  if [ "${textsz:-0}" -le 0 ] 2>/dev/null && [ -z "$syms" ]; then
    fail "musl libc $t" "no native code (empty .text, no T symbols) in $member"; rm -rf "$tmp"; return
  fi
  if ! "$root/bin/$t-clang" -static -fno-lto "$ROOT_DIR/tests/fixtures/hello.c" -o "$tmp/h" 2>/dev/null || ! "$tmp/h" >/dev/null; then
    fail "musl libc $t" "non-LTO static link failed"; rm -rf "$tmp"; return
  fi
  rm -rf "$tmp"
  pass "musl libc $t"
}

check_shims() {
  local root="$1" t="$2" p tmp
  p="$(musl_gcc_prefix "$t")"
  tmp="$(mktemp -d)"
  if "$root/bin/$p-gcc" -static "$ROOT_DIR/tests/fixtures/hello.c" -o "$tmp/h" 2>"$tmp/err" && "$tmp/h" >/dev/null; then
    pass "gcc shims $t"
  else
    fail "gcc shims $t" "$(head -3 "$tmp/err")"
  fi
  rm -rf "$tmp"
}

# check_containers ROOT — gnu output and the shipped clang run on glibc-2.34-era distros.
check_containers() {
  local root="$1" gnu musl image cmd
  gnu="$(bundle_triple_for_libc gnu)"
  musl="$(bundle_triple_for_libc musl)"
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    if is_yes "$REQUIRE_CONTAINER_CHECKS"; then fail "containers" "docker unavailable"; else warn "docker unavailable; skipping container checks"; fi
    return
  fi
  cmd="/smoke-gnu/hello-c && /smoke-gnu/hello-cxx && /smoke-musl/hello-c && /tc/bin/clang --version >/dev/null \
    && /tc/bin/$gnu-clang /src/hello.c -o /tmp/h && /tmp/h"
  for image in almalinux:9 ubuntu:22.04; do
    if docker run --rm -v "$root:/tc:ro" -v "$(smoke_dir "$gnu"):/smoke-gnu:ro" -v "$(smoke_dir "$musl"):/smoke-musl:ro" \
        -v "$ROOT_DIR/tests/fixtures:/src:ro" "$image" sh -c "$cmd" >/dev/null 2>"$VERIFY_DIR/docker.err"; then
      pass "container $image"
    else
      fail "container $image" "$(tail -3 "$VERIFY_DIR/docker.err")"
    fi
  done
}

# bitcode_producer BCANALYZER FILE — producer string of an LLVM bitcode file (e.g. LLVM23.1.2), or empty.
bitcode_producer() {
  "$1" --dump "$2" 2>/dev/null | sed -n "s/.*IDENTIFICATION.*//; s/.*STRING.*'\(LLVM[0-9.]*\)'.*/\1/p" | head -n1
}

# check_bitcode ROOT TRIPLE — every member of every shipped static archive carries LLVM bitcode
# whose producer major is LLVM_MAJOR (spec §3.3a). Exempt: compiler-rt (lib/clang/**, never
# scanned), glibc's own archives (listed in glibc-files.txt), and hand-written assembly members
# (*.S.o, *.s.o, *.asm.o), which have no IR and so cannot carry bitcode.
check_bitcode() {
  local root="$1" t="$2" a rel tmp m kind bad="" sample bc producer
  tmp="$(mktemp -d)"
  while IFS= read -r a; do
    rel="${a#"$root/sysroot/$t"/}"
    if [ "$a" != "$rel" ] && grep -qxF "$rel" "$OUT_DIR/glibc-files.txt"; then continue; fi
    rm -rf "$tmp/x"; mkdir -p "$tmp/x"
    if ! (cd "$tmp/x" || exit 1; "$root/bin/llvm-ar" x "$a"); then bad="$bad$a: cannot extract"$'\n'; continue; fi
    sample=""
    for m in "$tmp/x"/*; do
      [ -f "$m" ] || continue
      case "$m" in *.S.o|*.s.o|*.asm.o) continue ;; esac
      kind="$(head -c 4 "$m" | od -An -tx1 | tr -d ' \n')"
      case "$kind" in
        4243c0de) sample="${sample:-$m}" ;;
        7f454c46)
          if "$root/bin/llvm-readelf" -S "$m" 2>/dev/null | grep -q '\.llvm\.lto'; then
            if [ -z "$sample" ]; then
              "$root/bin/llvm-objcopy" --dump-section ".llvm.lto=$tmp/fat.bc" "$m" "$tmp/discard.o" && sample="$tmp/fat.bc"
            fi
          else
            bad="$bad$a($(basename "$m")): native code only, no bitcode"$'\n'
          fi ;;
        *) bad="$bad$a($(basename "$m")): not an object (magic $kind)"$'\n' ;;
      esac
    done
    if [ -n "$sample" ]; then
      producer="$(bitcode_producer "$root/bin/llvm-bcanalyzer" "$sample")"
      bc="${producer#LLVM}"
      if [ "${bc%%.*}" != "$LLVM_MAJOR" ]; then bad="$bad$a: bitcode producer '$producer', want LLVM$LLVM_MAJOR.x"$'\n'; fi
    fi
  done < <(find "$root/sysroot/$t/usr/lib" "$root/lib/$t" -name '*.a' -type f 2>/dev/null | sort)
  rm -rf "$tmp"
  if [ -z "$bad" ]; then pass "bitcode $t"; else fail "bitcode $t" "$(printf '%s' "$bad" | head -10)"; fi
}

check_macos_minos() {
  local root="$1" t="$2" f minos out=""
  while IFS= read -r f; do
    file -b "$f" | grep -q Mach-O || continue
    if ! command -v vtool >/dev/null 2>&1; then out="${out}vtool not available, cannot read minos of $f"$'\n'; continue; fi
    minos="$(vtool -show-build "$f" 2>/dev/null | awk '/minos/{print $2; exit}')"
    if [ -z "$minos" ]; then out="$out$f: no minos reported by vtool"$'\n'; continue; fi
    if version_lt "$MACOS_MIN" "$minos"; then out="$out$f: minos $minos"$'\n'; fi
  done < <(find "$root/bin" "$(smoke_dir "$t")" -type f -perm -u+x)
  if [ -z "$out" ]; then pass "macos minos $t"; else fail "macos minos $t" "$(printf '%s' "$out" | head -5)"; fi
}

check_darwin_dylibs() {
  local root="$1" f bad=""
  while IFS= read -r f; do
    file -b "$f" | grep -q Mach-O || continue
    bad="$bad$(otool -L "$f" | tail -n +2 | awk '{print $1}' \
      | grep -vE '^(/usr/lib/|/System/|@rpath/|@loader_path/|@executable_path/)' | sed "s#^#$f: #")"
  done < <(find "$root/bin" -type f -perm -u+x)
  if [ -z "$bad" ]; then pass "darwin dylibs"; else fail "darwin dylibs" "$(printf '%s' "$bad" | head -5)"; fi
}

check_no_build_paths() {
  local root="$1" leaks abs
  leaks="$(grep -rIlF "$ROOT_DIR" "$root" 2>/dev/null | head -5 || true)"
  abs="$(find "$root" -type l -lname '/*' | head -5)"
  if [ -n "$leaks" ]; then fail "no build paths" "text files mention $ROOT_DIR: $leaks"
  elif [ -n "$abs" ]; then fail "no build paths" "absolute symlinks: $abs"
  else pass "no build paths"; fi
}

check_manifest() {
  local root="$1" v
  v="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$root/share/elide-toolchain/manifest.json" 2>/dev/null || true)"
  if [ "$v" = "$TOOLCHAIN_VERSION" ] && [ "$("$root/bin/elide-toolchain" version)" = "$TOOLCHAIN_VERSION" ]; then
    pass "manifest"
  else
    fail "manifest" "manifest/VERSION do not report $TOOLCHAIN_VERSION"
  fi
}

# check_relocatable ROOT — copy the bundle under a path containing a space and rerun the smoke tests.
check_relocatable() {
  local root="$1" moved t
  moved="$VERIFY_DIR/reloc test/$TOOLCHAIN_NAME"
  rm -rf "$VERIFY_DIR/reloc test"; mkdir -p "$VERIFY_DIR/reloc test"
  cp -a "$root" "$moved"
  for t in $ALL_TARGETS; do check_smoke "$moved" "$t" relocated; done
  if "$moved/bin/elide-toolchain" doctor >/dev/null; then pass "doctor (relocated)"; else fail "doctor (relocated)" "see elide-toolchain doctor"; fi
  rm -rf "$VERIFY_DIR/reloc test"
}

run_all_checks() {
  local root="$1" t re
  if [ "$HOST_OS" = linux ]; then
    re="$(readelf_bin 2>/dev/null || true)"
    if [ -z "$re" ] || [ ! -x "$re" ]; then fail "readelf" "no usable readelf/llvm-readelf found"; fi
  fi
  check_manifest "$root"
  check_no_build_paths "$root"
  for t in $ALL_TARGETS; do
    check_smoke "$root" "$t"
    check_werror "$root" "$t"
    check_components "$root" "$t"
    check_bitcode "$root" "$t"
    case "$(triple_libc "$t")" in
      gnu) check_glibc_floor "$root" "$t"; check_interp "$root" "$t" ;;
      musl) check_musl_libc "$root" "$t"; check_shims "$root" "$t" ;;
      darwin) check_macos_minos "$root" "$t" ;;
    esac
  done
  if [ "$HOST_OS" = linux ]; then check_containers "$root"; else check_darwin_dylibs "$root"; fi
  check_relocatable "$root"
  echo "verification: $VERIFY_FAILURES failure(s)"
  [ "$VERIFY_FAILURES" -eq 0 ]
}
