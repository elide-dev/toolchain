# shellcheck shell=bash
# Feature checks for Propeller, DeduBB, MemProf and libelidealloc-shim
# (docs/superpowers/specs/2026-10-05-memprof-dedubb-design.md §8). Sourced by checks.sh; uses its
# pass/fail and the platform/ELF helpers. Operates on an extracted bundle ROOT.

propeller_testdata() { printf '%s\n' "$ROOT_DIR/llvm-propeller/propeller/testdata"; }
host_cpu() { case "$(uname -m)" in arm64|aarch64) echo aarch64 ;; *) uname -m ;; esac; }
static_flag() { if [ "$(triple_libc "$1")" = musl ]; then echo -static; fi; }

# Propeller "labelled" ThinLTO build of the two-function DeduBB fixture (prints 32).
labelled_build() { # ROOT TRIPLE OUT [extra...]
  local root="$1" t="$2" out="$3"; shift 3
  # shellcheck disable=SC2046
  "$root/bin/$t-clang" -O2 -flto=thin -funique-internal-linkage-names -fbasic-block-address-map \
    -fuse-ld=lld -Wl,--lto-basic-block-address-map -Wl,-z,keep-text-section-prefix \
    $(static_flag "$t") "$ROOT_DIR/tests/fixtures/dedubb/a.c" "$ROOT_DIR/tests/fixtures/dedubb/b.c" \
    -o "$out" "$@"
}

# sym_addr BIN NAME — hex address of NAME (no 0x), empty if absent.
# awk reads to EOF: an early exit SIGPIPEs llvm-nm, which pipefail turns into a stage abort.
sym_addr() { "$ROOT/bin/llvm-nm" "$1" 2>/dev/null | awk -v n="$2" '$3 == n && !a { a = $1 } END { if (a) print a }'; }

# layout_evidence ROOT BIN LDPROFILE — functions laid out in ld-profile order; hot/split
# sections present; every *.cold symbol inside .text.split. Prints a reason on failure.
layout_evidence() {
  local root="$1" bin="$2" ld="$3" prev=0 f a secs lo size cold
  ROOT="$root"
  secs="$("$root/bin/llvm-readelf" -SW "$bin")"
  grep -q ' \.text\.hot ' <<< "$secs" || { echo "no .text.hot section"; return 1; }
  grep -q ' \.text\.split ' <<< "$secs" || { echo "no .text.split section"; return 1; }
  while IFS= read -r f; do
    case "$f" in *.cold|'') continue ;; esac
    a="$(sym_addr "$bin" "$f")"; [ -n "$a" ] || continue
    if [ $((16#$a)) -lt "$prev" ]; then echo "symbol order does not follow the ld profile at $f"; return 1; fi
    prev=$((16#$a))
  done < "$ld"
  # readelf -SW: ... Name Type Address Off Size ...
  read -r lo size < <(awk '{ for (i = 1; i <= NF; i++) if ($i == ".text.split") { print $(i+2), $(i+4); exit } }' <<< "$secs")
  [ -n "$lo" ] || { echo "cannot read .text.split bounds"; return 1; }
  cold="$("$root/bin/llvm-nm" "$bin" | awk '$3 ~ /\.cold$/ { print $1 }')"
  [ -n "$cold" ] || { echo "no .cold symbols"; return 1; }
  for a in $cold; do
    if [ $((16#$a)) -lt $((16#$lo)) ] || [ $((16#$a)) -ge $((16#$lo + 16#$size)) ]; then
      echo "cold symbol at $a outside .text.split"; return 1
    fi
  done
  return 0
}

# check_propeller_golden ROOT — the shipped tool reproduces upstream's golden cc profile from
# upstream's checked-in perf data (no PMU needed).
check_propeller_golden() {
  local root="$1" g="$1/bin/generate_propeller_profiles" td tmp
  [ "$HOST_OS" = linux ] && is_yes "${BUILD_PROPELLER:-yes}" || return 0
  td="$(propeller_testdata)"; tmp="$(mktemp -d)"
  if ! "$g" --binary="$td/sample_with_bb_hash.bin" --profile="$td/sample_with_bb_hash.perfdata" \
       --cc_profile="$tmp/cc.txt" --ld_profile="$tmp/ld.txt" >"$tmp/log" 2>&1; then
    fail "propeller golden" "$(tail -3 "$tmp/log")"; rm -rf "$tmp"; return
  fi
  if [ "$(grep -v '^h ' "$tmp/cc.txt")" = "$(grep -v '^h ' "$td/sample_with_bb_hash_cc_directives.golden.txt")" ] &&
     grep -qx main "$tmp/ld.txt"; then
    pass "propeller golden"
  else
    fail "propeller golden" "cc profile differs from upstream golden"
  fi
  rm -rf "$tmp"
}

# check_propeller_relink ROOT TRIPLE — upstream perf data -> profiles -> relink with the bundle's
# clang/lld (non-LTO and ThinLTO) -> layout evidence. The fixture is x86-64 (its BB IDs are
# arch-specific), so this runs for x86_64 triples. On failure after an LLVM bump, see
# docs/notes/propeller-fixtures.md.
check_propeller_relink() {
  local root="$1" t="$2" g="$1/bin/generate_propeller_profiles" td tmp why st=() mode
  [ "$(triple_os "$t")" = linux ] && [ "$(triple_cpu "$t")" = x86_64 ] && [ -x "$g" ] || return 0
  td="$(propeller_testdata)"; tmp="$(mktemp -d)"
  [ "$(triple_libc "$t")" = musl ] && st=(-static)
  "$g" --binary="$td/bimodal_sample_v2.bin" \
    --profile="$td/bimodal_sample_v2.perfdata.1,$td/bimodal_sample_v2.perfdata.2" \
    --cc_profile="$tmp/cc.txt" --ld_profile="$tmp/ld.txt" >"$tmp/log" 2>&1 \
    || { fail "propeller relink $t" "profile generation: $(tail -2 "$tmp/log")"; rm -rf "$tmp"; return; }
  for mode in plain thin; do
    local lto=()
    if [ "$mode" = thin ]; then lto=(-flto=thin "-Wl,--lto-basic-block-sections=$tmp/cc.txt")
    else lto=("-fbasic-block-sections=list=$tmp/cc.txt"); fi
    if ! "$root/bin/$t-clang" -O2 "${st[@]}" "${lto[@]}" -fuse-ld=lld \
         -Wl,--symbol-ordering-file="$tmp/ld.txt" -Wl,--no-warn-symbol-ordering -Wl,-z,keep-text-section-prefix \
         "$td/bimodal_sample_v2.c" -o "$tmp/opt-$mode" 2>"$tmp/err"; then
      fail "propeller relink $t" "$mode link: $(head -3 "$tmp/err")"; rm -rf "$tmp"; return
    fi
    if ! why="$(layout_evidence "$root" "$tmp/opt-$mode" "$tmp/ld.txt")"; then
      fail "propeller relink $t" "$mode: $why (see docs/notes/propeller-fixtures.md)"; rm -rf "$tmp"; return
    fi
    if [ "$(triple_cpu "$t")" = "$(host_cpu)" ] && ! "$tmp/opt-$mode" >/dev/null 2>&1; then
      fail "propeller relink $t" "$mode binary failed to run"; rm -rf "$tmp"; return
    fi
  done
  pass "propeller relink $t"
  rm -rf "$tmp"
}

# perf_branch_capable TRIPLE — can this host record branch samples (x86 LBR / arm64 SPE)?
perf_branch_capable() {
  local tmp rc=1
  command -v perf >/dev/null 2>&1 || return 1
  tmp="$(mktemp)"
  case "$(triple_cpu "$1")" in
    x86_64) perf record -q -b -e cycles:u -o "$tmp" -- true >/dev/null 2>&1 && rc=0 ;;
    aarch64) perf record -q -e arm_spe// -o "$tmp" -- true >/dev/null 2>&1 && rc=0 ;;
  esac
  rm -f "$tmp"; return "$rc"
}

# check_propeller_live ROOT TRIPLE — live profile collection, only on hosts that can sample
# branches; otherwise a warned skip (REQUIRE_LBR=yes turns it into a failure). Host arch only.
check_propeller_live() {
  local root="$1" t="$2" g="$1/bin/generate_propeller_profiles" par tmp why ev=(-e cycles:u -j "any,u") ptype=()
  [ "$(triple_os "$t")" = linux ] && [ "$(triple_cpu "$t")" = "$(host_cpu)" ] && [ -x "$g" ] || return 0
  [ "$(triple_libc "$t")" = gnu ] || return 0     # one live check per host is enough
  par="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo '?')"
  if ! perf_branch_capable "$t"; then
    if is_yes "${REQUIRE_LBR:-no}"; then fail "propeller live $t" "no LBR/SPE on this host (perf_event_paranoid=$par) and REQUIRE_LBR=yes"
    else warn "propeller live $t: skipped (no LBR/SPE; perf_event_paranoid=$par)"; fi
    return
  fi
  if [ "$(triple_cpu "$t")" = aarch64 ]; then ev=(-e arm_spe//); ptype=(--profile_type=PERF_SPE); fi
  tmp="$(mktemp -d)"
  labelled_build "$root" "$t" "$tmp/app" || { fail "propeller live $t" "labelled build"; rm -rf "$tmp"; return; }
  perf record -q "${ev[@]}" -o "$tmp/perf.data" -- sh -c "for i in 1 2 3 4 5 6 7 8; do '$tmp/app'; done" >/dev/null 2>&1
  if ! "$g" --binary="$tmp/app" --profile="$tmp/perf.data" "${ptype[@]}" \
       --cc_profile="$tmp/cc.txt" --ld_profile="$tmp/ld.txt" >"$tmp/log" 2>&1 || [ ! -s "$tmp/cc.txt" ]; then
    fail "propeller live $t" "$(tail -3 "$tmp/log")"; rm -rf "$tmp"; return
  fi
  if ! labelled_build "$root" "$t" "$tmp/app.opt" "-Wl,--lto-basic-block-sections=$tmp/cc.txt" \
       "-Wl,--symbol-ordering-file=$tmp/ld.txt" -Wl,--no-warn-symbol-ordering 2>"$tmp/err" ||
     [ "$("$tmp/app.opt")" != 32 ]; then
    fail "propeller live $t" "relink: $(head -3 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  why="$("$root/bin/llvm-readelf" -SW "$tmp/app.opt" | grep -c ' \.text\.hot ')"
  if [ "$why" -ge 1 ]; then pass "propeller live $t"; else fail "propeller live $t" "no .text.hot after relink"; fi
  rm -rf "$tmp"
}

# check_propeller_tool ROOT TRIPLE — DeduBB directives from the binary alone (static: no profile).
check_propeller_tool() {
  local root="$1" t="$2" g="$1/bin/generate_propeller_profiles" tmp
  [ "$(triple_os "$t")" = linux ] && [ -x "$g" ] || return 0
  tmp="$(mktemp -d)"
  labelled_build "$root" "$t" "$tmp/app" 2>"$tmp/err" || { fail "propeller tool $t" "labelled build: $(head -3 "$tmp/err")"; rm -rf "$tmp"; return; }
  "$g" --binary="$tmp/app" --dedubb_profile="$tmp/d.txt" >"$tmp/log" 2>&1
  if grep -q '^bbm 0 (DeduBB\.master\.' "$tmp/d.txt" 2>/dev/null && grep -q '^bbf 0 (DeduBB\.master\.' "$tmp/d.txt"; then
    pass "propeller tool $t"
  else
    fail "propeller tool $t" "no bbm/bbf directives: $(tail -2 "$tmp/log")"
  fi
  rm -rf "$tmp"
}

# check_dedubb_codegen ROOT TRIPLE — directives -> relink with -dedubb-directives -> the folded
# function branches to the DeduBB master -> output unchanged.
check_dedubb_codegen() {
  local root="$1" t="$2" g="$1/bin/generate_propeller_profiles" tmp m dis f
  [ "$(triple_os "$t")" = linux ] && is_yes "${LLVM_DEDUBB:-yes}" && [ -x "$g" ] || return 0
  tmp="$(mktemp -d)"
  labelled_build "$root" "$t" "$tmp/app" || { fail "dedubb codegen $t" "labelled build"; rm -rf "$tmp"; return; }
  if ! "$g" --binary="$tmp/app" --dedubb_profile="$tmp/d.txt" >"$tmp/gen" 2>&1; then
    fail "dedubb codegen $t" "generator: $(tail -3 "$tmp/gen")"; rm -rf "$tmp"; return
  fi
  if ! labelled_build "$root" "$t" "$tmp/app.dd" "-Wl,-mllvm,-dedubb-directives=$tmp/d.txt" 2>"$tmp/err"; then
    fail "dedubb codegen $t" "$(head -3 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  ROOT="$root"; m="$(sym_addr "$tmp/app.dd" DeduBB.master.0)"
  [ -n "$m" ] || { fail "dedubb codegen $t" "no DeduBB.master.0 symbol"; rm -rf "$tmp"; return; }
  f="$(awk '/^f /{fn=$2} /^bbf 0 \(DeduBB\.master\.0\)/{print fn; exit}' "$tmp/d.txt")"
  [ -n "$f" ] || { fail "dedubb codegen $t" "no bbf entry for DeduBB.master.0 in directives"; rm -rf "$tmp"; return; }
  if ! dis="$("$root/bin/llvm-objdump" -d --no-show-raw-insn --disassemble-symbols="$f" "$tmp/app.dd" 2>&1)"; then
    fail "dedubb codegen $t" "llvm-objdump: $(head -3 <<< "$dis")"; rm -rf "$tmp"; return
  fi
  if ! grep -Eiq "(jmp|b)[[:space:]]+(0x)?0*${m#"${m%%[!0]*}"}" <<< "$dis"; then
    fail "dedubb codegen $t" "$f does not branch to DeduBB.master.0 ($m)"; rm -rf "$tmp"; return
  fi
  if [ "$(triple_cpu "$t")" = "$(host_cpu)" ] && [ "$("$tmp/app.dd")" != 32 ]; then
    fail "dedubb codegen $t" "folded program printed the wrong result"; rm -rf "$tmp"; return
  fi
  pass "dedubb codegen $t"
  rm -rf "$tmp"
}

# check_dedubb_inert ROOT TRIPLE — without directives the patched compiler leaves no trace and
# stays deterministic.
check_dedubb_inert() {
  local root="$1" t="$2" tmp
  [ "$t" = x86_64-unknown-linux-gnu ] || [ "$t" = aarch64-unknown-linux-gnu ] || return 0
  tmp="$(mktemp -d)"
  if ! labelled_build "$root" "$t" "$tmp/a1" || ! labelled_build "$root" "$t" "$tmp/a2"; then
    fail "dedubb inert $t" "labelled build"; rm -rf "$tmp"; return
  fi
  if ! cmp -s "$tmp/a1" "$tmp/a2"; then fail "dedubb inert $t" "non-deterministic output"
  elif "$root/bin/llvm-nm" "$tmp/a1" | grep -c 'DeduBB\.' >/dev/null; then fail "dedubb inert $t" "DeduBB symbols without directives"
  else pass "dedubb inert $t"; fi
  rm -rf "$tmp"
}

# shim_libs ROOT TRIPLE — link flags from the shipped elidealloc-shim.pc (Libs:, minus -L).
shim_libs() {
  sed -n 's/^Libs: *//p' "$1/sysroot/$2/usr/lib/pkgconfig/elidealloc-shim.pc" | tr ' ' '\n' | grep -v '^-L' | xargs
}
# can_run TRIPLE — binaries for TRIPLE run on this host.
can_run() {
  local c; c="$(triple_cpu "$1")"; [ "$c" = arm64 ] && c=aarch64
  [ "$(triple_os "$1")" = "$HOST_OS" ] && [ "$c" = "$(host_cpu)" ]
}

# check_elidealloc_shim ROOT TRIPLE — the packaged shim links via its .pc and passes its test.
check_elidealloc_shim() {
  local root="$1" t="$2" tmp libs st=()
  [ -f "$root/sysroot/$t/usr/lib/libelidealloc-shim.a" ] || { fail "elidealloc shim $t" "libelidealloc-shim.a missing"; return; }
  tmp="$(mktemp -d)"; libs="$(shim_libs "$root" "$t")"
  [ "$(triple_libc "$t")" = musl ] && st=(-static)
  # shellcheck disable=SC2086
  if ! "$root/bin/$t-clang++" -O2 "${st[@]}" "$ROOT_DIR/tests/fixtures/elidealloc-shim-test.cc" $libs \
       -o "$tmp/t" 2>"$tmp/err"; then
    fail "elidealloc shim $t" "$(head -3 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  if can_run "$t"; then
    if ! "$tmp/t" >"$tmp/out" 2>&1 || ! ELIDEALLOC_DISABLE=1 "$tmp/t" disabled >/dev/null 2>&1 ||
       ! ELIDEALLOC_HOT_MIN=200 "$tmp/t" hotmin200 >/dev/null 2>&1; then
      fail "elidealloc shim $t" "$(grep FAIL "$tmp/out" | head -3)"; rm -rf "$tmp"; return
    fi
  fi
  pass "elidealloc shim $t"
  rm -rf "$tmp"
}

memprof_hint_ldflags() {
  printf '%s\n' -flto=thin -fuse-ld=lld -Wl,-mllvm,-enable-memprof-context-disambiguation \
    -Wl,-mllvm,-optimize-hot-cold-new -Wl,-mllvm,-supports-hot-cold-new
}

# check_memprof_runtime ROOT TRIPLE — instrument, run, index (x86_64 gnu only).
check_memprof_runtime() {
  local root="$1" t="$2" tmp n
  memprof_supported "$t" || return 0
  tmp="$(mktemp -d)"
  if ! "$root/bin/$t-clang++" -O2 -gmlt -fdebug-info-for-profiling -fmemory-profile \
       -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -fno-optimize-sibling-calls -fno-pie -no-pie \
       -Wl,-z,noseparate-code -Wl,--build-id "$ROOT_DIR/tests/fixtures/memprof.cc" -o "$tmp/instr" 2>"$tmp/err"; then
    fail "memprof runtime $t" "$(head -3 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  if ! (cd "$tmp" && ./instr); then fail "memprof runtime $t" "instrumented binary failed"; rm -rf "$tmp"; return; fi
  if ! "$root/bin/llvm-profdata" merge "$tmp"/memprof.profraw.* --profiled-binary "$tmp/instr" \
       -o "$tmp/p.memprofdata" 2>"$tmp/err"; then
    fail "memprof runtime $t" "merge: $(head -3 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  n="$("$root/bin/llvm-profdata" show --memory "$tmp/p.memprofdata" | sed -n 's/^#  *Total contexts: //p')"
  if [ "${n:-0}" -ge 2 ]; then pass "memprof runtime $t"; else fail "memprof runtime $t" "contexts=${n:-none}"; fi
  rm -rf "$tmp"
}

# check_memprof_use ROOT TRIPLE — YAML profile -> match -> ThinLTO context cloning -> hot/cold
# operator new served by libelidealloc-shim (cold context lands in the COLD partition).
check_memprof_use() {
  local root="$1" t="$2" tmp st=() l=() libs
  tmp="$(mktemp -d)"; mapfile -t l < <(memprof_hint_ldflags); libs="$(shim_libs "$root" "$t")"
  [ "$(triple_libc "$t")" = musl ] && st=(-static)
  "$root/bin/llvm-profdata" merge "$ROOT_DIR/tests/fixtures/memprof-ctx.yaml" -o "$tmp/p.memprofdata" \
    || { fail "memprof use $t" "yaml merge"; rm -rf "$tmp"; return; }
  if ! "$root/bin/$t-clang++" -O2 -gmlt -fdebug-info-for-profiling -flto=thin -fmemory-profile-use="$tmp/p.memprofdata" \
       -Rpass=memprof -c "$ROOT_DIR/tests/fixtures/memprof-ctx.cc" -o "$tmp/c.o" 2>"$tmp/rem"; then
    fail "memprof use $t" "$(head -3 "$tmp/rem")"; rm -rf "$tmp"; return
  fi
  grep -q 'matched alloc context' "$tmp/rem" || { fail "memprof use $t" "no MemProf match remark"; rm -rf "$tmp"; return; }
  # shellcheck disable=SC2086
  if ! "$root/bin/$t-clang++" -O2 "${st[@]}" "$tmp/c.o" -o "$tmp/c" "${l[@]}" $libs 2>"$tmp/err"; then
    fail "memprof use $t" "link: $(head -3 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  if ! "$root/bin/llvm-nm" "$tmp/c" | grep -c '_Z5allocm\.memprof\.1' >/dev/null; then fail "memprof use $t" "no context clone"; rm -rf "$tmp"; return; fi
  if ! "$root/bin/llvm-nm" "$tmp/c" | grep -c '_Znam12__hot_cold_t' >/dev/null; then fail "memprof use $t" "no hot/cold operator new"; rm -rf "$tmp"; return; fi
  if can_run "$t" && ! "$tmp/c"; then fail "memprof use $t" "cold context not in the COLD partition"; rm -rf "$tmp"; return; fi
  pass "memprof use $t"
  rm -rf "$tmp"
}

# check_memprof_strip ROOT TRIPLE — without -supports-hot-cold-new no hint survives the link.
check_memprof_strip() {
  local root="$1" t="$2" tmp st=() libs
  tmp="$(mktemp -d)"; libs="$(shim_libs "$root" "$t")"
  [ "$(triple_libc "$t")" = musl ] && st=(-static)
  "$root/bin/llvm-profdata" merge "$ROOT_DIR/tests/fixtures/memprof-ctx.yaml" -o "$tmp/p.memprofdata"
  # shellcheck disable=SC2086
  if ! "$root/bin/$t-clang++" -O2 "${st[@]}" -gmlt -fdebug-info-for-profiling -flto=thin -fuse-ld=lld \
       -fmemory-profile-use="$tmp/p.memprofdata" "$ROOT_DIR/tests/fixtures/memprof-ctx.cc" -o "$tmp/c" $libs 2>"$tmp/err"; then
    fail "memprof strip $t" "$(head -3 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  if "$root/bin/llvm-nm" "$tmp/c" | grep -c '_Znam12__hot_cold_t\|memprof\.1' >/dev/null; then
    fail "memprof strip $t" "hints or clones without -supports-hot-cold-new"
  else pass "memprof strip $t"; fi
  rm -rf "$tmp"
}

check_memprof_absent() {
  local root="$1" t="$2"
  memprof_supported "$t" && return 0
  if compgen -G "$root/lib/clang/$LLVM_MAJOR/lib/$t/libclang_rt.memprof*" >/dev/null; then
    fail "memprof absent $t" "unexpected memprof runtime"
  else pass "memprof absent $t"; fi
}

run_feature_checks() { # ROOT
  local root="$1" t
  check_propeller_golden "$root"
  for t in $ALL_TARGETS; do
    check_propeller_relink "$root" "$t"
    check_propeller_live "$root" "$t"
    check_propeller_tool "$root" "$t"
    check_dedubb_codegen "$root" "$t"
    check_dedubb_inert "$root" "$t"
    check_elidealloc_shim "$root" "$t"
    check_memprof_runtime "$root" "$t"
    check_memprof_use "$root" "$t"
    check_memprof_strip "$root" "$t"
    check_memprof_absent "$root" "$t"
  done
}
