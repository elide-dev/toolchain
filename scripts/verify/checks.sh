# shellcheck shell=bash
# Bundle verification (spec §6). Operates on an extracted bundle ROOT, never on the build tree.

VERIFY_FAILURES=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }

# Propeller, DeduBB, MemProf and libelidealloc-shim checks (run_feature_checks).
# shellcheck source=scripts/verify/checks-pgo.sh
source "$ROOT_DIR/scripts/verify/checks-pgo.sh"

smoke_dir() { printf '%s/smoke/%s\n' "$VERIFY_DIR" "$1"; }

# shellcheck source=scripts/verify/sanitizers.sh
source "$ROOT_DIR/scripts/verify/sanitizers.sh"

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
  # musl: -lmimalloc is the empty stub, the mi_* API comes from libc.a.
  defs+=(-DHAVE_MIMALLOC); libs+=(-lmimalloc)
  if [ "$(triple_libc "$t")" = musl ]; then static=(-static); fi
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
  case " ${defs[*]} " in *" -DHAVE_CRYPTO "*) [ "$(triple_os "$t")" = linux ] && check_components_shared "$root" "$t" ;; esac
  return 0
}

# check_components_shared ROOT TRIPLE — R23: ACCP/JNI link libssl.a/libcrypto.a into a -shared
# object. The link must succeed with -z defs (every symbol resolved against libc), and on gnu
# the result must stay within the glibc floor.
check_components_shared() {
  local root="$1" t="$2" tmp v
  tmp="$(mktemp -d)"
  if ! "$root/bin/$t-clang" -shared -fPIC "$ROOT_DIR/tests/fixtures/shared-crypto.c" -o "$tmp/libshared.so" \
      -Wl,-z,defs -l:libssl.a -l:libcrypto.a 2>"$tmp/err"; then
    fail "components shared $t" "$(head -5 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  if [ "$(triple_libc "$t")" = gnu ]; then
    v="$(glibc_floor_violations "$tmp/libshared.so")"
    if [ -n "$v" ]; then fail "components shared $t" "$(head -5 <<< "$v")"; rm -rf "$tmp"; return; fi
  fi
  rm -rf "$tmp"
  pass "components shared $t"
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
  member="$("$root/bin/llvm-ar" t "$lib" 2>/dev/null || true)"
  member="$(grep -m1 '^printf\.' <<< "$member" || true)"
  [ -n "$member" ] || { fail "musl libc $t" "no printf member in $lib"; rm -rf "$tmp"; return; }
  (cd "$tmp" || exit 1; "$root/bin/llvm-ar" x "$lib" "$member")
  sections="$("$root/bin/llvm-readelf" -S "$tmp/$member")"
  if is_yes "$MUSL_USE_LTO"; then
    case "$sections" in *.llvm.lto*) ;; *) fail "musl libc $t" "no .llvm.lto section in $member"; rm -rf "$tmp"; return ;; esac
    "$root/bin/llvm-objcopy" --dump-section ".llvm.lto=$tmp/bc" "$tmp/$member" "$tmp/discard.o"
    "$root/bin/llvm-dis" "$tmp/bc" -o "$tmp/bc.ll" 2>/dev/null || true
    if ! grep -qF "target triple = \"$t\"" "$tmp/bc.ll" 2>/dev/null; then
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
  local dump
  dump="$("$1" --dump "$2" 2>/dev/null || true)"
  dump="$(sed -n "s/.*IDENTIFICATION.*//; s/.*STRING.*'\(LLVM[0-9.]*\)'.*/\1/p" <<< "$dump")"
  printf '%s\n' "${dump%%$'\n'*}"
}

# musl_asm_stems ARCH — basenames (no extension) of musl's hand-written assembly sources for
# ARCH (musl/src/*/ARCH/*.s|*.S); musl names their objects <stem>.lo in libc.a.
musl_asm_stems() {
  local f
  while IFS= read -r f; do
    f="${f##*/}"; printf '%s\n' "${f%.*}"
  done < <(find "$ROOT_DIR/musl/src" -path "*/$1/*" \( -name '*.s' -o -name '*.S' \) -type f 2>/dev/null)
}

# check_bitcode ROOT TRIPLE — every member of every shipped static archive carries LLVM bitcode
# whose producer major is LLVM_MAJOR (spec §3.3a). Members are checked per occurrence (musl's
# libc.a holds two clone.lo: src/linux/clone.c and src/thread/<arch>/clone.s), extracting
# duplicates one at a time with `llvm-ar xN`.
#
# Exempt: compiler-rt (lib/clang/**, never scanned); on gnu only, glibc's own archives (listed in
# glibc-files.txt); musl's bare 8-byte `!<arch>\n` stub archives; and hand-written assembly,
# which has no IR. A member is assembly when BOTH hold:
#   (a) what it is: a native ELF object with no .llvm.lto section and no .comment section.
#       clang's code generator records llvm.ident in .comment for every C/C++ translation unit
#       (fat-LTO or native), while its integrated assembler writes none for .s/.S input, so a
#       compiled-but-native member still fails. Mach-O objects carry no ident, so (a) is
#       "native Mach-O" there.
#   (b) where it came from: CMake objects are named after their source (*.S.o, *.s.o, *.asm.o);
#       musl libc.a objects (<stem>.lo) whose stem is a musl/src/*/<arch>/*.s|*.S source.
check_bitcode() {
  local root="$1" t="$2" a rel tmp m kind bad="" bc producer checked nonasm n sections names name k
  local libc asm_stems="" fmt
  local -A total seen
  libc="$(triple_libc "$t")"
  if [ "$libc" = musl ]; then asm_stems="$(musl_asm_stems "$(triple_cpu "$t")")"; fi
  tmp="$(mktemp -d)"
  printf '!<arch>\n' > "$tmp/empty.a"
  while IFS= read -r a; do
    rel="${a#"$root/sysroot/$t"/}"
    if [ "$libc" = gnu ] && [ "$a" != "$rel" ] && grep -qxF "$rel" "$OUT_DIR/glibc-files.txt"; then continue; fi
    # musl ships bare-header stub archives (libm.a, libpthread.a, ...): exactly "!<arch>\n".
    if cmp -s "$a" "$tmp/empty.a"; then continue; fi
    if ! names="$("$root/bin/llvm-ar" t "$a" 2>/dev/null)"; then bad="$bad$a: cannot list members"$'\n'; continue; fi
    rm -rf "$tmp/x" "$tmp/dup"; mkdir -p "$tmp/x" "$tmp/dup"
    if ! (cd "$tmp/x" || exit 1; "$root/bin/llvm-ar" x "$a"); then bad="$bad$a: cannot extract"$'\n'; continue; fi
    total=(); seen=()
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      total[$name]=$(( ${total[$name]:-0} + 1 ))
    done <<< "$names"
    checked=0; nonasm=0; n=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      n=$((n + 1))
      seen[$name]=$(( ${seen[$name]:-0} + 1 ))
      k="${seen[$name]}"
      if [ "${total[$name]}" -eq 1 ]; then
        m="$tmp/x/$name"
      else
        mkdir -p "$tmp/dup/$n"
        if ! (cd "$tmp/dup/$n" || exit 1; "$root/bin/llvm-ar" xN "$k" "$a" "$name"); then
          bad="$bad$a($name#$k): cannot extract"$'\n'; continue
        fi
        m="$tmp/dup/$n/$name"
      fi
      [ -f "$m" ] || { bad="$bad$a($name#$k): member not extracted"$'\n'; continue; }
      kind="$(head -c 4 "$m" | od -An -tx1 | tr -d ' \n')"
      bc=""; fmt=""; sections=""
      case "$kind" in
        4243c0de|dec0170b)   # raw bitcode, or the Mach-O bitcode wrapper (bcanalyzer reads both)
          # ELF targets ship fat objects so non-LTO links work; only darwin may be pure bitcode.
          if [ "$(triple_os "$t")" = linux ]; then
            bad="$bad$a($name#$k): pure bitcode, want a fat object (-ffat-lto-objects)"$'\n'; continue
          fi
          bc="$m" ;;
        7f454c46)
          fmt=elf
          sections="$("$root/bin/llvm-readelf" -S "$m" 2>/dev/null || true)"
          if grep -qF '.llvm.lto' <<< "$sections"; then
            rm -f "$tmp/fat.bc"
            if "$root/bin/llvm-objcopy" --dump-section ".llvm.lto=$tmp/fat.bc" "$m" "$tmp/discard.o" 2>/dev/null && [ -s "$tmp/fat.bc" ]; then
              bc="$tmp/fat.bc"
            else
              bad="$bad$a($name#$k): cannot dump .llvm.lto section"$'\n'; continue
            fi
          fi ;;
        cffaedfe|cefaedfe|feedface|feedfacf|cafebabe) fmt=macho ;;
        *) bad="$bad$a($name#$k): not an object (magic $kind)"$'\n'; continue ;;
      esac
      if [ -z "$bc" ]; then
        if is_asm_member "$fmt" "$name" "$sections" "$rel" "$asm_stems"; then continue; fi
        nonasm=$((nonasm + 1))
        bad="$bad$a($name#$k): native code only, no bitcode"$'\n'; continue
      fi
      nonasm=$((nonasm + 1)); checked=$((checked + 1))
      producer="$(bitcode_producer "$root/bin/llvm-bcanalyzer" "$bc")"
      producer="${producer#LLVM}"
      if [ "${producer%%.*}" != "$LLVM_MAJOR" ]; then
        bad="$bad$a($name#$k): bitcode producer 'LLVM$producer', want LLVM$LLVM_MAJOR.x"$'\n'
      fi
    done <<< "$names"
    if [ "$checked" -eq 0 ] && { [ "$nonasm" -gt 0 ] || [ "$n" -eq 0 ]; }; then
      bad="$bad$a: no member checked (empty archive or no bitcode)"$'\n'
    fi
  done < <(find "$root/sysroot/$t/usr/lib" "$root/lib/$t" -name '*.a' -type f 2>/dev/null | sort)
  rm -rf "$tmp"
  if [ -z "$bad" ]; then pass "bitcode $t"; else fail "bitcode $t" "$(printf '%s' "$bad" | head -10)"; fi
}

# is_asm_member FORMAT NAME SECTIONS ARCHIVE_REL MUSL_ASM_STEMS — see check_bitcode, (a) and (b).
is_asm_member() {
  local fmt="$1" name="$2" sections="$3" rel="$4" stems="$5" stem
  case "$fmt" in
    elf) if grep -qE '[[:space:]]\.comment[[:space:]]' <<< "$sections"; then return 1; fi ;;
    macho) ;;
    *) return 1 ;;
  esac
  case "$name" in
    *.S.o|*.s.o|*.asm.o) return 0 ;;
    *.lo|*.o)
      [ "$rel" = usr/lib/libc.a ] && [ -n "$stems" ] || return 1
      stem="${name%.*}"
      grep -qxF "$stem" <<< "$stems" ;;
    *) return 1 ;;
  esac
}

check_macos_minos() {
  local root="$1" t="$2" f minos out=""
  while IFS= read -r f; do
    case "$(file -b "$f" 2>/dev/null || true)" in *Mach-O*) ;; *) continue ;; esac
    if ! command -v vtool >/dev/null 2>&1; then out="${out}vtool not available, cannot read minos of $f"$'\n'; continue; fi
    minos="$(vtool -show-build "$f" 2>/dev/null | awk '/minos/ && !m {m = $2} END {print m}')"
    if [ -z "$minos" ]; then out="$out$f: no minos reported by vtool"$'\n'; continue; fi
    if version_lt "$MACOS_MIN" "$minos"; then out="$out$f: minos $minos"$'\n'; fi
  done < <(find "$root/bin" "$(smoke_dir "$t")" -type f -perm -u+x)
  if [ -z "$out" ]; then pass "macos minos $t"; else fail "macos minos $t" "$(printf '%s' "$out" | head -5)"; fi
}

check_darwin_dylibs() {
  local root="$1" f bad="" libs lib
  while IFS= read -r f; do
    case "$(file -b "$f" 2>/dev/null || true)" in *Mach-O*) ;; *) continue ;; esac
    libs="$(otool -L "$f" 2>/dev/null || true)"
    while read -r lib _; do
      case "$lib" in ''|"$f:"|/usr/lib/*|/System/*|@rpath/*|@loader_path/*|@executable_path/*) ;; *) bad="$bad$f: $lib"$'\n' ;; esac
    done <<< "$libs"
  done < <(find "$root/bin" -type f -perm -u+x)
  if [ -z "$bad" ]; then pass "darwin dylibs"; else fail "darwin dylibs" "$(printf '%s' "$bad" | head -5)"; fi
}

check_no_build_paths() {
  local root="$1" leaks abs
  leaks="$(grep -rIlF "$ROOT_DIR" "$root" 2>/dev/null | head -5 || true)"
  abs="$(find "$root" -type l -lname '/*' 2>/dev/null || true)"
  abs="$(head -5 <<< "$abs")"
  if [ -n "$leaks" ]; then fail "no build paths" "text files mention $ROOT_DIR: $leaks"
  elif [ -n "$abs" ]; then fail "no build paths" "absolute symlinks: $abs"
  else pass "no build paths"; fi
}

# check_manifest ROOT — manifest.json and `elide-toolchain version` report TOOLCHAIN_VERSION, the
# manifest's llvmMajor is LLVM_MAJOR, and every submodule's recorded revision is its versions.env
# *_REV pin.
check_manifest() {
  local root="$1" problems
  problems="$(python3 - "$root/share/elide-toolchain/manifest.json" "$ROOT_DIR" "$TOOLCHAIN_VERSION" "$LLVM_MAJOR" <<'PY' 2>&1 || true
import json, os, re, subprocess, sys
path, root, version, llvm_major = sys.argv[1:]
try:
    m = json.load(open(path))
except Exception as e:  # noqa: BLE001
    print(f"cannot read {path}: {e}"); sys.exit(0)
env = {}
for line in open(os.path.join(root, "versions.env")):
    k = re.match(r"^([A-Z0-9_]+)=([^\s#]*)", line.strip())
    if k:
        env[k.group(1)] = k.group(2).strip("\"'")
if m.get("version") != version:
    print(f"version {m.get('version')!r}, want {version!r}")
if str(m.get("llvmMajor")) != llvm_major:
    print(f"llvmMajor {m.get('llvmMajor')!r}, want {llvm_major!r}")
out = subprocess.run(["git", "config", "-f", os.path.join(root, ".gitmodules"), "--get-regexp", r"^submodule\..*\.path$"],
                     capture_output=True, text=True, check=True).stdout
for sub in (line.split(None, 1)[1] for line in out.splitlines()):
    want = env.get(sub.upper().replace("-", "_") + "_REV", "")
    got = m.get("components", {}).get(sub, {}).get("revision", "")
    if not want or got != want:
        print(f"{sub}: revision {got!r}, versions.env {want!r}")
PY
)"
  if [ "$("$root/bin/elide-toolchain" version 2>/dev/null || true)" != "$TOOLCHAIN_VERSION" ]; then
    problems="${problems}elide-toolchain version does not report $TOOLCHAIN_VERSION"
  fi
  if [ -z "$problems" ]; then pass "manifest"; else fail "manifest" "$(head -5 <<< "$problems")"; fi
}

# check_rust ROOT TRIPLE — rustc links through <triple>-clang and a caught panic unwinds. gnu: the
# output stays within the glibc floor and needs no libgcc_s (std's -lgcc_s resolves to the
# sysroot's libgcc_s.so linker script → libunwind). Skipped (warn) without rustc or that
# target's std.
check_rust() {
  local root="$1" t="$2" rt list rsys tmp extra=() v
  rt="$(rust_triple "$t")"
  if ! command -v rustc >/dev/null 2>&1; then warn "rustc not on PATH; skipping rust $t"; return; fi
  list="$(rustc --print target-list 2>/dev/null || true)"
  rsys="$(rustc --print sysroot 2>/dev/null || true)"
  if ! grep -qxF "$rt" <<< "$list" || [ ! -d "$rsys/lib/rustlib/$rt" ]; then
    warn "rust std for $rt not installed; skipping rust $t"; return
  fi
  if [ "$(triple_libc "$t")" = musl ]; then extra=(-C target-feature=+crt-static); fi
  tmp="$(mktemp -d)"
  if ! rustc --target "$rt" "${extra[@]}" -C "linker=$root/bin/$t-clang" \
      "$ROOT_DIR/tests/fixtures/hello.rs" -o "$tmp/hello-rs" 2>"$tmp/err"; then
    fail "rust $t" "$(grep -E 'error|undefined|unable' "$tmp/err" | head -5)"; rm -rf "$tmp"; return
  fi
  if [ "$("$tmp/hello-rs" 2>/dev/null)" != "hello from elide-toolchain" ]; then
    fail "rust $t" "program did not print the expected output (panic not caught?)"; rm -rf "$tmp"; return
  fi
  if [ "$(triple_libc "$t")" = gnu ]; then
    v="$(glibc_floor_violations "$tmp/hello-rs")"
    case " $(needed_libs "$tmp/hello-rs" | xargs) " in *" libgcc_s"*) v="${v}needs libgcc_s"$'\n' ;; esac
    if [ -n "$v" ]; then fail "rust $t" "$(head -5 <<< "$v")"; rm -rf "$tmp"; return; fi
  fi
  rm -rf "$tmp"
  pass "rust $t"
}

# check_relocatable ROOT — copy the bundle under a path containing a space and rerun the smoke tests.
check_relocatable() {
  local root="$1" moved t
  moved="$VERIFY_DIR/reloc test/$TOOLCHAIN_NAME"
  rm -rf "$VERIFY_DIR/reloc test"; mkdir -p "$VERIFY_DIR/reloc test"
  cp -a "$root" "$moved"
  for t in $ALL_TARGETS; do check_smoke "$moved" "$t" relocated; done
  if "$moved/bin/elide-toolchain" doctor >/dev/null; then pass "doctor (relocated)"; else fail "doctor (relocated)" "see elide-toolchain doctor"; fi
  run_sanitizer_relocated_checks "$moved"
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
    check_rust "$root" "$t"
    run_sanitizer_checks "$root" "$t"
    case "$(triple_libc "$t")" in
      gnu) check_glibc_floor "$root" "$t"; check_interp "$root" "$t" ;;
      musl) check_musl_libc "$root" "$t"; check_shims "$root" "$t" ;;
      darwin) check_macos_minos "$root" "$t" ;;
    esac
  done
  if [ "$HOST_OS" = linux ]; then check_containers "$root"; else check_darwin_dylibs "$root"; fi
  run_feature_checks "$root"
  check_relocatable "$root"
  run_sanitizer_addon_checks "$root"
  echo "verification: $VERIFY_FAILURES failure(s)"
  [ "$VERIFY_FAILURES" -eq 0 ]
}
