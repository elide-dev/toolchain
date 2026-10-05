# Sanitizer Variants Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship compiler-rt sanitizer runtimes in every bundle, plus, for the Linux gnu triples,
a `-sanitizers` overlay archive with ASan-, TSan- and MSan-instrumented libc++ and components. A
consumer then builds an end-to-end sanitized binary with one switch:
`elide-toolchain env --target T --sanitizer S`.

**Architecture:** Stage 30 gains a third pass (sanitizer runtimes); darwin's stage 10 flips
compiler-rt sanitizers on. A new stage `60-sanitizer-variants` builds instrumented libc++ and
components with the repo's existing recipes. It also assembles a symlink-farm sysroot
`sysroot/<G>+<san>/` per variant. Selection uses generated POSIX-sh wrappers
`bin/<T>-<san>-clang{,++}`, which stack `--config` layers on top of the normal auto-loaded
`<T>.cfg`, and per-variant CMake toolchain files. Stage 90 splits the output into the main archive
and the overlay archive.

**Tech Stack:** bash (build), POSIX sh (wrappers, helper), CMake + Ninja, LLVM 23.1.x
compiler-rt/libc++, Python 3 (manifest), TypeScript + bun (action), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-05-sanitizer-variants-design.md` (§N below). **Evidence:**
`docs/notes/sanitizer-spikes.md` (spikes A–H). Read both first. The base spec
`docs/superpowers/specs/2026-10-04-universal-native-toolchain-design.md` stays binding.

## Global Constraints

- Everything in the base plan's Global Constraints still applies (relocatable, no `sudo`, writes
  only under `out/` and `dist/`, POSIX sh for shipped scripts, bash ≥ 4 for build scripts).
- Short sanitizer names everywhere in file names and the CLI: `asan tsan msan ubsan lsan hwasan`.
  Clang names (`address` …) appear only inside cfgs.
- Shipped matrix (spec §3), single source in `versions.env`:
  gnu `asan lsan tsan msan ubsan` (+`hwasan` on aarch64), musl `ubsan`, darwin `asan tsan ubsan`;
  libFuzzer on gnu and darwin. Overlay variants: `asan tsan msan`, gnu triples only.
- compiler-rt sanitizer runtimes are **native code** (base spec §3.3a exemption). Variant libc++
  stays fat ThinLTO and variant components stay pure ThinLTO bitcode (`LLVM_MAJOR` producer).
- **Never ship an instrumented `libunwind`** (spike C: infinite recursion under MSan). Variant
  libc++abi is built with `LIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=OFF`.
- Variant sysroots are relative-symlink farms. Instrumented archives are real files, and a `.so`
  whose `.a` was replaced is **dropped** from the farm (spike F negative control).
- The gnu glibc floor (`GLIBC_2.34`) applies to every new `.so`.
- Commit messages are plain, with no attribution trailer (this plan's requester asked for that;
  it overrides the base plan's trailer rule for this work).

## Review Focus

1. **MSan false positives.** Every layer on an MSan link line must be instrumented except
   libunwind. Pinned by `check_sanitizer_variant_clean` (Task 13), which links every component,
   with and without `-flto=thin`, and by `check_sanitizer_variant_instrumented`, which rejects
   uninstrumented archives and any `libunwind.a` in the variant dir.
2. **CMake bypassing `-L`.** CMake consumers must resolve the farm's archives. Pinned by
   `check_sanitizer_cmake` (Task 13).
3. **Overlay/main drift.** One `overlay_paths` function drives both archives (Task 12). The
   overlay refuses to load over a different bundle version (helper check, Task 8).
4. **mimalloc.** The farm's `libmimalloc.a` is the forwarding shim, never the `MI_OVERRIDE=ON`
   archive. Pinned by `check_sanitizer_mimalloc` (Task 13).
5. **Relocation.** Wrappers and farm symlinks must work after moving the bundle to a path with a
   space. Pinned by the extended `check_relocatable` (Task 13) and the frontends unit test
   (Task 6).

---

## File Structure

```
versions.env                               # MODIFY: sanitizer matrix (Task 3)
vars.sh                                    # MODIFY: BUILD_SANITIZERS, BUILD_SANITIZER_VARIANTS (Task 3)
build.sh                                   # MODIFY: stage 60 in STAGES + usage (Task 11)
scripts/lib/platform.sh                    # MODIFY: triple_sanitizers, triple_variants, san_* (Task 3)
scripts/lib/runtimes.sh                    # NEW: runtimes_common_args/cxx_runtime_args moved from stage 30 (Task 4)
scripts/lib/env.sh                         # MODIFY: source runtimes.sh (Task 4)
scripts/lib/frontends.sh                   # MODIFY: sanitizer cfgs, wrappers, cmake files (Task 6)
scripts/lib/flags.sh                       # MODIFY: SANITIZER_LAYER (Task 9)
scripts/lib/components.sh                  # MODIFY: component_variant_args (Task 9)
scripts/components/aws-lc.sh, openssl.sh   # MODIFY: variant hooks (Task 9)
scripts/stages/10-llvm-stage1.sh           # MODIFY: darwin sanitizers (Task 5)
scripts/stages/30-runtimes.sh              # MODIFY: pass 3 + prune (Task 4)
scripts/stages/60-sanitizer-variants.sh    # NEW (Task 11)
scripts/stages/90-package.sh               # MODIFY: overlay archive (Task 12)
scripts/stages/95-verify.sh                # MODIFY: extract overlay (Task 13)
scripts/verify/checks.sh                   # MODIFY: sanitizer checks (Tasks 2, 7, 13)
scripts/gen-manifest.py                    # MODIFY: sanitizers section, overlay.json (Task 12)
src/elide-toolchain                        # MODIFY: --sanitizer, sanitizers, overlay install (Tasks 8, 16)
src/mimalloc-sanitizer-shim.c              # NEW (Task 10)
tests/fixtures/sanitizers/{asan,tsan,msan,ubsan,lsan,hwasan}.c   # NEW (Task 7)
tests/fixtures/sanitizers/{clean.cpp,exc.cpp,workload.c,mimalloc-oob.c,mimalloc-api.c,jni-lib.c,jni-host.c,cmake/CMakeLists.txt,rust/main.rs,rust/c_part.c}  # NEW (Tasks 7, 13)
tests/unit/{platform,frontends,flags,components,helper,manifest}.test.sh   # MODIFY
tests/stages/30-runtimes.check.sh          # MODIFY (Task 4)
tests/stages/60-sanitizer-variants.check.sh  # NEW (Task 11)
action/{action.yml,lib.ts,main.ts,lib.test.ts,dist/main.js}      # MODIFY (Task 14)
.github/workflows/{on.release.yml,job.action-e2e.yml,job.build.yml}  # MODIFY (Task 15)
docs/notes/mise-assets.md                  # MODIFY (Task 1)
README.md                                  # MODIFY (Task 17)
docs/notes/build-timings.md                # MODIFY (Task 17)
```

**New directory variables:** none. Variant build trees live under `$BUILD_DIR/variants/<san>/`
(stage 60), so they never collide with stage 50's `$BUILD_DIR/components/`.

---

## Phase A — Risk checks

### Task 1: mise with a second `linux-<arch>` asset

**Files:** Modify `docs/notes/mise-assets.md`.

**Interfaces:** Produces the decision on the overlay asset name, which Tasks 12, 14 and 16 consume.

- [ ] **Step 1:** In the mise checkout used for `docs/notes/mise-assets.md` (tag `v2026.9.12`), read
  the scoring in `src/backend/asset_matcher.rs`. Determine what autodetection picks when a release
  holds both `elide-toolchain-2026.10.0-linux-amd64.tar.xz` and
  `elide-toolchain-2026.10.0-linux-amd64-sanitizers.tar.xz`. Look for tie-breaks (name length,
  extra tokens, first match). If a unit-test harness exists there (as at `:1800-1812`), add a
  local scratch test with both names and run it (`cargo test asset_matcher`). Do not push
  anything.
- [ ] **Step 2:** Decide:
  - main asset always wins → keep `…-linux-<arch>-sanitizers.tar.xz`;
  - ambiguous → rename the overlay so it carries **no** os/arch tokens that mise scores, e.g.
    `elide-toolchain-sanitizers-2026.10.0-linux-x86_64-gnu.tar.xz` will not do (`x86_64` matches).
    Prefer `elide-toolchain-<ver>-<os>-<arch>.sanitizers.overlay` (non-archive extension,
    scored 0). Record the exact rule.
- [ ] **Step 3:** Append a `## Overlay assets` section to `docs/notes/mise-assets.md` with the
  file:line evidence and the decision, then commit.

**Verification:** The note names the chosen asset pattern and cites the scoring code.

### Task 2: Record the dynamic-musl defect as a visible check

**Files:** Modify `scripts/verify/checks.sh`, `vars.sh`.

Spec §10: every dynamically linked musl executable segfaults in mimalloc init inside `libc.so`.
This design does not depend on a fix, but verification must stop hiding it.

- [ ] **Step 1:** Add to `vars.sh`: `REQUIRE_MUSL_DYNAMIC=${REQUIRE_MUSL_DYNAMIC:-no}`.
- [ ] **Step 2:** Add the check:

```bash
# check_musl_dynamic ROOT TRIPLE — a dynamically linked musl hello must run through the sysroot's
# own loader (spec 2026-10-05 §10). Known failure today; fatal only with REQUIRE_MUSL_DYNAMIC=yes.
check_musl_dynamic() {
  local root="$1" t="$2" tmp sr name="musl dynamic $2"
  sr="$root/sysroot/$t"
  tmp="$(mktemp -d)"
  if "$root/bin/$t-clang" "$ROOT_DIR/tests/fixtures/hello.c" -o "$tmp/h" \
       -Wl,--dynamic-linker="$sr/$(musl_loader "$(triple_cpu "$t")")" 2>"$tmp/err" \
     && "$tmp/h" >/dev/null 2>>"$tmp/err"; then
    pass "$name"
  elif is_yes "${REQUIRE_MUSL_DYNAMIC:-no}"; then
    fail "$name" "dynamic musl executable failed (see spec 2026-10-05 §10)"
  else
    printf 'note  %s: dynamic musl executables fail (known, spec 2026-10-05 §10)\n' "$name"
  fi
  rm -rf "$tmp"
}
```

- [ ] **Step 3:** Call it from the `musl)` branch of `run_all_checks`.
- [ ] **Step 4:** Run `./build.sh --only 95-verify` on the existing build and expect the `note`
  line. Commit.

---

## Phase B — Runtimes in the main bundle

### Task 3: Sanitizer matrix in config and platform helpers

**Files:** Modify `versions.env`, `vars.sh`, `scripts/lib/platform.sh`, `tests/unit/platform.test.sh`.

**Interfaces (produced, used by every later task):**
- `triple_sanitizers T` → space-separated selectable sanitizers for T
- `triple_variants T` → overlay variants for T (empty unless gnu and `BUILD_SANITIZER_VARIANTS=yes`)
- `triple_has_libfuzzer T` → exit status
- `san_flag S`, `san_cmake S`, `san_symbol S`, `san_report S`, `san_runtimes S`
- `crt_sanitizers_to_build T` → value for `COMPILER_RT_SANITIZERS_TO_BUILD`

- [ ] **Step 1: Write the failing unit tests** (append to `tests/unit/platform.test.sh`):

```bash
assert_eq "$(triple_sanitizers x86_64-unknown-linux-gnu)" "asan lsan tsan msan ubsan"
assert_eq "$(triple_sanitizers aarch64-unknown-linux-gnu)" "asan lsan tsan msan ubsan hwasan"
assert_eq "$(triple_sanitizers x86_64-unknown-linux-musl)" "ubsan"
assert_eq "$(triple_sanitizers arm64-apple-darwin)" "asan tsan ubsan"
assert_eq "$(BUILD_SANITIZER_VARIANTS=yes triple_variants x86_64-unknown-linux-gnu)" "asan tsan msan"
assert_eq "$(BUILD_SANITIZER_VARIANTS=yes triple_variants x86_64-unknown-linux-musl)" ""
assert_eq "$(BUILD_SANITIZER_VARIANTS=no triple_variants x86_64-unknown-linux-gnu)" ""
assert_eq "$(BUILD_SANITIZERS=no triple_sanitizers x86_64-unknown-linux-gnu)" ""
assert_ok triple_has_libfuzzer x86_64-unknown-linux-gnu
assert_fails triple_has_libfuzzer x86_64-unknown-linux-musl
assert_eq "$(san_flag msan)" "memory"
assert_eq "$(san_cmake msan)" "MemoryWithOrigins"
assert_eq "$(san_symbol tsan)" "__tsan_"
assert_eq "$(san_report asan)" "heap-buffer-overflow"
assert_contains "$(san_runtimes asan)" "asan_static"
assert_eq "$(crt_sanitizers_to_build x86_64-unknown-linux-gnu)" "asan;tsan;msan;ubsan_minimal"
assert_eq "$(crt_sanitizers_to_build aarch64-unknown-linux-gnu)" "asan;tsan;msan;ubsan_minimal;hwasan"
assert_eq "$(crt_sanitizers_to_build x86_64-unknown-linux-musl)" "ubsan_minimal"
assert_fails san_flag bogus
```

Run: `tests/run.sh platform` → Expected: FAIL.

- [ ] **Step 2: Config.** In `versions.env`, after the LLVM projects block:

```bash
# Sanitizers (spec 2026-10-05 §3). Selectable short names; compiler-rt names are derived.
SANITIZERS_LINUX_GNU="asan lsan tsan msan ubsan"
SANITIZERS_LINUX_GNU_AARCH64="hwasan"
SANITIZERS_LINUX_MUSL="ubsan"
SANITIZERS_DARWIN="asan tsan ubsan"
SANITIZER_VARIANTS="asan tsan msan"
LIBFUZZER_LIBCS="gnu darwin"
```

In `vars.sh`:

```bash
BUILD_SANITIZERS=${BUILD_SANITIZERS:-yes}                   # compiler-rt sanitizer runtimes in the bundle
BUILD_SANITIZER_VARIANTS=${BUILD_SANITIZER_VARIANTS:-yes}   # Linux: instrumented libc++/components overlay
```

- [ ] **Step 3: Implement** in `scripts/lib/platform.sh`:

```bash
# triple_sanitizers TRIPLE — selectable sanitizers shipped for TRIPLE (spec 2026-10-05 §3).
triple_sanitizers() {
  local t="$1" list=""
  is_yes "${BUILD_SANITIZERS:-yes}" || { echo ""; return 0; }
  case "$(triple_libc "$t")" in
    gnu)
      list="$SANITIZERS_LINUX_GNU"
      if [ "$(triple_cpu "$t")" = aarch64 ]; then list="$list $SANITIZERS_LINUX_GNU_AARCH64"; fi ;;
    musl) list="$SANITIZERS_LINUX_MUSL" ;;
    darwin) list="$SANITIZERS_DARWIN" ;;
  esac
  printf '%s\n' "$list"
}

triple_variants() {
  if [ "$(triple_libc "$1")" = gnu ] && is_yes "${BUILD_SANITIZERS:-yes}" \
     && is_yes "${BUILD_SANITIZER_VARIANTS:-yes}"; then
    printf '%s\n' "$SANITIZER_VARIANTS"
  else
    echo ""
  fi
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
san_cmake() { # LLVM_USE_SANITIZER value for overlay variants
  case "$1" in asan) echo Address ;; tsan) echo Thread ;; msan) echo MemoryWithOrigins ;; *) die "no variant for $1" ;; esac
}
san_symbol() {
  case "$1" in asan) echo __asan_ ;; tsan) echo __tsan_ ;; msan) echo __msan_ ;; *) die "no variant for $1" ;; esac
}
san_report() {
  case "$1" in
    asan) echo heap-buffer-overflow ;; tsan) echo "data race" ;; msan) echo use-of-uninitialized-value ;;
    ubsan) echo "runtime error" ;; lsan) echo "detected memory leaks" ;; hwasan) echo tag-mismatch ;;
    *) die "unknown sanitizer: $1" ;;
  esac
}
# san_runtimes S — compiler-rt runtime basenames (libclang_rt.<name>.*) S needs on Linux.
san_runtimes() {
  case "$1" in
    asan) echo "asan asan_static asan-preinit asan_cxx" ;;
    tsan) echo "tsan tsan_cxx" ;;
    msan) echo "msan msan_cxx" ;;
    lsan) echo "lsan" ;;
    ubsan) echo "ubsan_standalone ubsan_standalone_cxx ubsan_minimal" ;;
    hwasan) echo "hwasan hwasan_cxx hwasan-preinit hwasan_aliases hwasan_aliases_cxx" ;;
    fuzzer) echo "fuzzer fuzzer_no_main fuzzer_interceptors" ;;
    *) die "unknown sanitizer: $1" ;;
  esac
}
# crt_sanitizers_to_build TRIPLE — COMPILER_RT_SANITIZERS_TO_BUILD. lsan and ubsan_standalone are
# always built by compiler-rt when sanitizers are on; ubsan selects ubsan_minimal as well.
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
```

Note the ordering for gnu: the test expects `asan;tsan;msan;ubsan_minimal`, which follows
`SANITIZERS_LINUX_GNU` order minus `lsan`, with `ubsan`→`ubsan_minimal`, and `hwasan` appended
on aarch64.

- [ ] **Step 4:** `tests/run.sh platform` → PASS; `tests/run.sh` (incl. shellcheck) → PASS. Commit.

### Task 4: Stage 30 pass 3 — sanitizer runtimes (Linux)

**Files:** Create `scripts/lib/runtimes.sh`; modify `scripts/lib/env.sh`,
`scripts/stages/30-runtimes.sh`, `tests/stages/30-runtimes.check.sh`.

**Interfaces:**
- Consumes: Task 3 helpers; the installed libc++ from pass 2.
- Produces in **both** `$STAGE1_DIR` and `$BUNDLE_DIR`:
  `lib/clang/$LLVM_MAJOR/lib/<T>/libclang_rt.<rt>.{a,a.syms,so}` for every `san_runtimes`
  of every `triple_sanitizers T` (+ fuzzer where applicable), `lib/clang/$LLVM_MAJOR/include/sanitizer/*.h`,
  `lib/clang/$LLVM_MAJOR/share/*_ignorelist.txt`. Nothing else (`prune_sanitizer_runtimes`).
- `scripts/lib/runtimes.sh`: `runtimes_common_args T [CLANG_DIR]` and `cxx_runtime_args T`,
  moved verbatim from stage 30 (with `CLANG_DIR` defaulting to `$STAGE1_DIR/bin`). Stage 60
  reuses them.

- [ ] **Step 1: Extend the failing stage check** (`tests/stages/30-runtimes.check.sh`, inside
  the per-target loop, after the existing asserts):

```bash
  rd="$BUNDLE_DIR/lib/clang/$LLVM_MAJOR/lib/$t"
  for s in $(triple_sanitizers "$t"); do
    for r in $(san_runtimes "$s"); do
      case "$r" in hwasan_aliases*) [ "$(triple_cpu "$t")" = x86_64 ] || continue ;; esac
      assert_file "$rd/libclang_rt.$r.a"
    done
  done
  if [ "$(triple_libc "$t")" = musl ]; then
    assert_eq "$(ls "$rd" | grep -cE '^libclang_rt\.(asan|tsan|msan|lsan|hwasan)')" "0" "no dynamic-only sanitizers on musl"
    # shellcheck disable=SC2086
    assert_ok "$STAGE1_DIR/bin/$t-clang" -static -fsanitize=undefined -fno-sanitize-recover=all \
      "$ROOT_DIR/tests/fixtures/sanitizers/ubsan.c" -o "$tmp/ub-$t"
  else
    assert_file "$rd/libclang_rt.asan.so"
    assert_ok "$STAGE1_DIR/bin/$t-clang" -fsanitize=address "$ROOT_DIR/tests/fixtures/sanitizers/asan.c" -o "$tmp/as-$t"
  fi
  assert_file "$BUNDLE_DIR/lib/clang/$LLVM_MAJOR/include/sanitizer/asan_interface.h"
  assert_file "$BUNDLE_DIR/lib/clang/$LLVM_MAJOR/share/msan_ignorelist.txt"
```

(`tests/fixtures/sanitizers/*.c` arrive in Task 7. Implement Task 7 Step 1 first, or create
those two files now.) Run `bash tests/stages/30-runtimes.check.sh` → FAIL.

- [ ] **Step 2: Move the shared args** into `scripts/lib/runtimes.sh`:

```bash
# shellcheck shell=bash
# LLVM runtimes cmake arguments shared by stage 30 (main runtimes) and stage 60 (sanitizer
# variants). Bare --target/--sysroot (never the cfg): see stage 30's header.

runtimes_common_args() { # TRIPLE [CLANG_DIR]
  local t="$1" s="${2:-$STAGE1_DIR/bin}" af
  af="--no-default-config $(arch_flags "$t")"
  printf '%s\n' \
    … # body moved unchanged from 30-runtimes.sh, with "$s" as the compiler dir
}

cxx_runtime_args() { # TRIPLE — libunwind/libc++abi/libc++ options (stage 30 pass 2, unchanged)
  local t="$1" musl=OFF
  if [ "$(triple_libc "$t")" = musl ]; then musl=ON; fi
  printf '%s\n' \
    -DLIBUNWIND_USE_COMPILER_RT=ON -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_STATIC=ON \
    … # the rest of build_cxx_runtimes' -D list, moved unchanged (including the -flto=thin;-ffat-lto-objects flags)
}
```

Source it from `scripts/lib/env.sh` after `cmake.sh`. `build_cxx_runtimes` now does
`mapfile -t extra < <(cxx_runtime_args "$t")` and passes `"${extra[@]}"`. Re-run the existing
stage-30 check on a fresh `--only 30-runtimes` to prove the refactor is behaviour-neutral (compare
`__config_site` and `llvm-nm` of `libc++.a` member names before and after).

- [ ] **Step 3: Pass 3** in `scripts/stages/30-runtimes.sh`:

```bash
stage_main() {
  local t
  [ -x "$STAGE1_DIR/bin/clang" ] || die "stage-1 clang missing; run 10-llvm-stage1"
  for t in $ALL_TARGETS; do
    build_builtins "$t"
    build_cxx_runtimes "$t"
    if [ -n "$(triple_sanitizers "$t")" ]; then build_sanitizer_runtimes "$t"; fi
  done
  install_frontends "$STAGE1_DIR"
}

# Pass 3: compiler-rt sanitizers, after pass 2 so libFuzzer and the *_cxx runtimes compile and
# link against our libc++ (spike A recipe). Native code only (base spec §3.3a).
build_sanitizer_runtimes() {
  local t="$1" b="$BUILD_DIR/runtimes/$1/sanitizers" args=() af lf fuzzer=OFF
  mapfile -t args < <(runtimes_common_args "$t")
  af="--no-default-config $(arch_flags "$t")"
  lf="-rtlib=compiler-rt -unwindlib=libunwind -stdlib=libc++ -fuse-ld=lld"
  if triple_has_libfuzzer "$t"; then fuzzer=ON; fi
  fresh_dir "$b"
  cmake -S "$ROOT_DIR/llvm/runtimes" -B "$b" "${args[@]}" \
    -DCMAKE_CXX_FLAGS="$af -stdlib=libc++" \
    -DCMAKE_EXE_LINKER_FLAGS="$lf" -DCMAKE_SHARED_LINKER_FLAGS="$lf" -DCMAKE_MODULE_LINKER_FLAGS="$lf" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=EXECUTABLE \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DCOMPILER_RT_BUILD_BUILTINS=OFF -DCOMPILER_RT_BUILD_CRT=OFF -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_SANITIZERS=ON \
    -DCOMPILER_RT_SANITIZERS_TO_BUILD="$(crt_sanitizers_to_build "$t")" \
    -DCOMPILER_RT_BUILD_LIBFUZZER="$fuzzer" \
    -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
    -DSANITIZER_CXX_ABI=libc++ -DSANITIZER_TEST_CXX=libc++ \
    -DCOMPILER_RT_INCLUDE_TESTS=OFF
  cmake --build "$b" -j "$JOBS"
  install_both "$b"
  prune_sanitizer_runtimes "$STAGE1_DIR" "$t"
  prune_sanitizer_runtimes "$BUNDLE_DIR" "$t"
}

# prune_sanitizer_runtimes PREFIX TRIPLE — keep only runtimes the matrix ships (compiler-rt
# always adds lsan, ubsan_standalone, stats, ubsan_loop_detect, …).
prune_sanitizer_runtimes() {
  local rd="$1/lib/clang/$LLVM_MAJOR/lib/$2" keep=" builtins profile " s r f base
  for s in $(triple_sanitizers "$2"); do for r in $(san_runtimes "$s"); do keep="$keep$r "; done; done
  if triple_has_libfuzzer "$2"; then for r in $(san_runtimes fuzzer); do keep="$keep$r "; done; fi
  for f in "$rd"/libclang_rt.*; do
    [ -e "$f" ] || continue
    base="${f##*/libclang_rt.}"; base="${base%%.*}"
    case "$keep" in *" $base "*) ;; *) rm -f "$f" ;; esac
  done
}
```

`runtimes_common_args` sets `CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY`. Pass 3 overrides it
with `EXECUTABLE`, because the builtins and libc++ exist now and compiler-rt's link probes
(`COMPILER_RT_HAS_*` for `-Wl,-z,…`) are more accurate as real links. If any probe regresses,
fall back to `STATIC_LIBRARY`: spike A used the default, which is executable.

- [ ] **Step 4:** `./build.sh --from 30-runtimes` (or `--only 30-runtimes` followed by the
  later stages), then `bash tests/stages/30-runtimes.check.sh` → PASS. Record the pass-3 wall time
  per triple in the commit message (spike A: ~30 s per triple on 32 threads). Commit.

### Task 5: darwin sanitizer runtimes (stage 10)

**Files:** Modify `scripts/stages/10-llvm-stage1.sh`, `tests/stages/10-llvm-stage1.check.sh`.

- [ ] **Step 1:** In the darwin check, assert the dylibs:

```bash
if [ "$HOST_OS" = darwin ] && [ -n "$(triple_sanitizers "$ALL_TARGETS")" ]; then
  d="$BUNDLE_DIR/lib/clang/$LLVM_MAJOR/lib/darwin"
  for s in asan tsan ubsan; do assert_file "$d/libclang_rt.${s}_osx_dynamic.dylib"; done
  assert_file "$d/libclang_rt.fuzzer_osx.a"
fi
```

- [ ] **Step 2:** In `llvm_darwin`, replace the sanitizer-related `-D`s:

```bash
  local san=OFF fuzz=OFF
  if [ -n "$(triple_sanitizers "$t")" ]; then san=ON; fi
  if triple_has_libfuzzer "$t"; then fuzz=ON; fi
  …
    -DCOMPILER_RT_BUILD_SANITIZERS="$san" -DCOMPILER_RT_BUILD_LIBFUZZER="$fuzz" \
    -DCOMPILER_RT_SANITIZERS_TO_BUILD="$(crt_sanitizers_to_build "$t")" \
    -DSANITIZER_MIN_OSX_VERSION="$MACOS_MIN" \
```

(keep XRAY/MEMPROF/ORC/CTX_PROFILE/GWP_ASAN `OFF` and iOS/watchOS/tvOS/xrOS off).

- [ ] **Step 3:** On the macOS runner, run `./build.sh --from 10-llvm-stage1`. Then: the stage
  check passes; `check_macos_minos` and `check_darwin_dylibs` pass on the new dylibs; `otool -l`
  shows `minos 12.0`; `codesign -dv` shows an ad-hoc signature. Record the added minutes.
  Commit. **This task is the first execution on darwin; treat failures as spike findings and
  record them in `docs/notes/sanitizer-spikes.md`.**

### Task 6: Front-ends — sanitizer cfg layers, wrappers, CMake files

**Files:** Modify `scripts/lib/frontends.sh`, `tests/unit/frontends.test.sh`.

**Interfaces (produced):**
- `render_san_cfg T S` → runtime layer
- `render_san_overlay_cfg T S` → overlay layer (gnu only)
- `render_san_wrapper T S DRIVER` → POSIX sh wrapper text
- `render_san_toolchain_cmake T S`
- `install_frontends PREFIX` now also writes, for every (T, S ∈ `triple_sanitizers T`):
  `share/elide-toolchain/sanitizers/<T>-<S>.cfg`, `bin/<T>-<S>-clang{,++}`,
  `share/elide-toolchain/cmake/<T>-<S>.cmake`
- `install_sanitizer_overlay_frontends PREFIX T S` writes `<T>-<S>.overlay.cfg` (stage 60)

- [ ] **Step 1: Failing unit tests** (append to `tests/unit/frontends.test.sh`, reusing its
  fake-tool prefix `"$T/pre fix"`, whose fake `clang`/`clang++` echo their argv):

```bash
assert_eq "$(render_san_cfg x86_64-unknown-linux-gnu msan)" \
  "$(printf '%s\n' -fsanitize=memory -fsanitize-memory-track-origins -fno-omit-frame-pointer)"
assert_contains "$(render_san_overlay_cfg x86_64-unknown-linux-gnu asan)" \
  "--sysroot=<CFGDIR>/../../../sysroot/x86_64-unknown-linux-gnu+asan"
assert_contains "$(render_san_overlay_cfg x86_64-unknown-linux-gnu asan)" \
  "-isystem <CFGDIR>/../../../include/x86_64-unknown-linux-gnu/asan/c++/v1"
assert_not_contains "$(render_san_overlay_cfg x86_64-unknown-linux-gnu msan)" "-isystem"
assert_contains "$(render_san_toolchain_cmake x86_64-unknown-linux-gnu tsan)" \
  'bin/x86_64-unknown-linux-gnu-tsan-clang"'
assert_contains "$(render_san_toolchain_cmake x86_64-unknown-linux-gnu tsan)" \
  'if(EXISTS "${_ET_ROOT}/sysroot/x86_64-unknown-linux-gnu+tsan/usr/lib")'

install_frontends "$P"
for f in x86_64-unknown-linux-gnu-asan-clang x86_64-unknown-linux-gnu-msan-clang++ x86_64-unknown-linux-musl-ubsan-clang; do
  assert_file "$P/bin/$f"
done
assert_fails test -e "$P/bin/x86_64-unknown-linux-musl-asan-clang"
# fake <T>-clang must exist for the wrapper to exec
ln -sfn clang "$P/bin/x86_64-unknown-linux-gnu-clang"
out="$("$P/bin/x86_64-unknown-linux-gnu-asan-clang" -c a.c)"
assert_contains "$out" "--config=$P/share/elide-toolchain/sanitizers/x86_64-unknown-linux-gnu-asan.cfg"
assert_not_contains "$out" "overlay.cfg" "no overlay layer before the overlay is installed"
assert_fails "$P/bin/x86_64-unknown-linux-gnu-msan-clang" -c a.c   # msan requires the overlay
install_sanitizer_overlay_frontends "$P" x86_64-unknown-linux-gnu msan
out="$("$P/bin/x86_64-unknown-linux-gnu-msan-clang" -c a.c)"
assert_contains "$out" "x86_64-unknown-linux-gnu-msan.overlay.cfg"
assert_contains "$out" "-c a.c"
```

Run `tests/run.sh frontends` → FAIL.

- [ ] **Step 2: Implement** in `scripts/lib/frontends.sh`:

```bash
render_san_cfg() {
  local s="$2"
  printf -- '-fsanitize=%s\n' "$(san_flag "$s")"
  if [ "$s" = msan ]; then echo "-fsanitize-memory-track-origins"; fi
  echo "-fno-omit-frame-pointer"
}

render_san_overlay_cfg() { # paths are relative to share/elide-toolchain/sanitizers/
  local t="$1" s="$2"
  echo "--sysroot=<CFGDIR>/../../../sysroot/$t+$s"
  echo "-L<CFGDIR>/../../../lib/$t/$s"
  if [ "$s" = asan ]; then echo "-isystem <CFGDIR>/../../../include/$t/asan/c++/v1"; fi
}

render_san_wrapper() { # TRIPLE SAN DRIVER(clang|clang++)
  local t="$1" s="$2" d="$3" req=""
  if [ "$s" = msan ]; then
    req="echo \"$t-$s-$d: msan needs the sanitizers overlay (instrumented libc++ and components); see elide-toolchain sanitizers\" >&2; exit 2"
  fi
  cat <<EOF
#!/bin/sh
# $t + $s: auto-loaded $t.cfg, the $s runtime layer, and the overlay layer when installed.
here=\$(CDPATH='' cd -- "\$(dirname -- "\$0")" && pwd -P)
sd=\$here/../share/elide-toolchain/sanitizers
if [ -f "\$sd/$t-$s.overlay.cfg" ]; then
  exec "\$here/$t-$d" --config="\$sd/$t-$s.cfg" --config="\$sd/$t-$s.overlay.cfg" "\$@"
fi
$req
exec "\$here/$t-$d" --config="\$sd/$t-$s.cfg" "\$@"
EOF
}

render_san_toolchain_cmake() {
  local t="$1" s="$2"
  render_toolchain_cmake "$t" \
    | sed -e "s#/bin/$t-clang\"#/bin/$t-$s-clang\"#" -e "s#/bin/$t-clang++\"#/bin/$t-$s-clang++\"#" \
          -e "/^set(CMAKE_SYSROOT /d"
  if [ "$(triple_os "$t")" = linux ]; then
    cat <<EOF
if(EXISTS "\${_ET_ROOT}/sysroot/$t+$s/usr/lib")
  set(CMAKE_SYSROOT "\${_ET_ROOT}/sysroot/$t+$s")
else()
  set(CMAKE_SYSROOT "\${_ET_ROOT}/sysroot/$t")
endif()
EOF
  fi
}

install_sanitizer_frontends() { # PREFIX TRIPLE
  local prefix="$1" t="$2" s d sd="$1/share/elide-toolchain/sanitizers"
  mkdir -p "$sd"
  for s in $(triple_sanitizers "$t"); do
    render_san_cfg "$t" "$s" > "$sd/$t-$s.cfg"
    for d in clang clang++; do
      render_san_wrapper "$t" "$s" "$d" > "$prefix/bin/$t-$s-$d"
      chmod 0755 "$prefix/bin/$t-$s-$d"
    done
    render_san_toolchain_cmake "$t" "$s" > "$prefix/share/elide-toolchain/cmake/$t-$s.cmake"
  done
}

install_sanitizer_overlay_frontends() { # PREFIX TRIPLE SAN
  render_san_overlay_cfg "$2" "$3" > "$1/share/elide-toolchain/sanitizers/$2-$3.overlay.cfg"
}
```

Call `install_sanitizer_frontends "$prefix" "$t"` at the end of the per-target loop in
`install_frontends`. `render_toolchain_cmake` writes `CMAKE_SYSROOT` on one line, so the `sed
/^set(CMAKE_SYSROOT /d` is exact. The unit test asserts the conditional block replaces it.

- [ ] **Step 3:** `tests/run.sh frontends` → PASS; `tests/run.sh` → PASS (shellcheck runs on the
  generated wrapper text indirectly through the test; also run
  `render_san_wrapper x86_64-unknown-linux-gnu asan clang | shellcheck -s sh -`). Commit.

### Task 7: Fixtures and main-bundle sanitizer checks

**Files:** Create `tests/fixtures/sanitizers/*`; modify `scripts/verify/checks.sh`.

- [ ] **Step 1: Fixtures** (from spikes B and H; keep them tiny and argc-dependent so the
  optimiser cannot fold the bug away):

`asan.c`:
```c
#include <stdlib.h>
int main(int c, char **v) { int *p = malloc(4 * sizeof(int)); int r = p[c + 3]; free(p); return r; }
```
`tsan.c`:
```c
#include <pthread.h>
static int g;
static void *w(void *a) { g++; return a; }
int main(void) { pthread_t a, b; pthread_create(&a, 0, w, 0); pthread_create(&b, 0, w, 0);
  pthread_join(a, 0); pthread_join(b, 0); return g == 0; }
```
`ubsan.c`:
```c
#include <limits.h>
#include <stdio.h>
int main(int c, char **v) { int x = INT_MAX; x += c; printf("%d\n", x); return 0; }
```
`lsan.c`:
```c
#include <stdlib.h>
void *keep;
int main(void) { keep = malloc(77); keep = 0; return 0; }
```
`msan.c`:
```c
#include <stdio.h>
int main(int c, char **v) { int x; if (c > 5) x = 1; if (x) puts("y"); return 0; }
```
`hwasan.c`:
```c
#include <stdlib.h>
int main(int c, char **v) { char *p = malloc(16); p[16 + c - 1] = 1; free(p); return 0; }
```
`clean.cpp`, `exc.cpp`, `workload.c`, `mimalloc-api.c`, `mimalloc-oob.c`, `jni-lib.c`,
`jni-host.c`: copy them verbatim from the spike notes' descriptions (spikes B, C, E, H).
`workload.c` must only include headers of **enabled** components: guard each block with the
`HAVE_*` macros from `component_link`, as `tests/fixtures/components.c` does, and add
`HAVE_BROTLIENC` for the encoder. Its buffers **must be heap-allocated** (`malloc`, never static
or zero-initialised). MSan treats static storage as initialised, so with static buffers an
uninstrumented component goes unnoticed (spike D correction). Every output must reach a branch
(`memcmp` against the input, then `if`).

- [ ] **Step 2: Checks.** Add to `scripts/verify/checks.sh`:

```bash
# check_sanitizer_runtimes ROOT TRIPLE — shipped runtimes match the matrix (spec 2026-10-05 §3).
check_sanitizer_runtimes() {
  local root="$1" t="$2" rd s r missing="" name="sanitizer runtimes $2"
  [ -n "$(triple_sanitizers "$t")" ] || return 0
  [ "$(triple_os "$t")" = linux ] || return 0          # darwin: check_darwin_sanitizers
  rd="$root/lib/clang/$LLVM_MAJOR/lib/$t"
  for s in $(triple_sanitizers "$t"); do
    for r in $(san_runtimes "$s"); do
      case "$r" in hwasan_aliases*) [ "$(triple_cpu "$t")" = x86_64 ] || continue ;; esac
      [ -f "$rd/libclang_rt.$r.a" ] || missing="$missing $r"
    done
  done
  [ -f "$root/lib/clang/$LLVM_MAJOR/include/sanitizer/common_interface_defs.h" ] || missing="$missing headers"
  if [ "$(triple_libc "$t")" = musl ] && ls "$rd" | grep -qE '^libclang_rt\.(asan|tsan|msan|lsan|hwasan)'; then
    missing="$missing (dynamic-only sanitizer present on musl)"
  fi
  if [ -z "$missing" ]; then pass "$name"; else fail "$name" "missing:$missing"; fi
}

# check_sanitizer_trips ROOT TRIPLE — each shipped sanitizer reports its fixture bug.
check_sanitizer_trips() {
  local root="$1" t="$2" s tmp static=() expect name
  tmp="$(mktemp -d)"
  if [ "$(triple_libc "$t")" = musl ]; then static=(-static); fi
  for s in $(triple_sanitizers "$t"); do
    name="sanitizer $s trips $t"
    if [ "$s" = msan ] && [ ! -f "$root/share/elide-toolchain/sanitizers/$t-msan.overlay.cfg" ]; then
      printf 'note  %s: overlay not installed; skipped\n' "$name"; continue
    fi
    if [ "$s" = hwasan ] && ! hwasan_kernel_ok; then
      printf 'note  %s: kernel lacks the tagged-address ABI; skipped\n' "$name"; continue
    fi
    expect="$(san_report "$s")"
    if ! "$root/bin/$t-$s-clang" "${static[@]}" -g -fno-sanitize-recover=all \
         "$ROOT_DIR/tests/fixtures/sanitizers/$s.c" -o "$tmp/$s" 2>"$tmp/$s.err"; then
      fail "$name" "build: $(head -3 "$tmp/$s.err")"; continue
    fi
    if ASAN_OPTIONS=detect_leaks=1 "$tmp/$s" >"$tmp/$s.log" 2>&1; then
      fail "$name" "exited 0"
    elif grep -q "$expect" "$tmp/$s.log"; then
      pass "$name"
    else
      fail "$name" "no '$expect' in report: $(head -c 200 "$tmp/$s.log")"
    fi
  done
  rm -rf "$tmp"
}

hwasan_kernel_ok() { # PR_GET_TAGGED_ADDR_CTRL = 56 succeeds only with the tagged-address ABI
  [ "$(uname -m)" = aarch64 ] || return 1
  python3 -c 'import ctypes,sys; sys.exit(0 if ctypes.CDLL(None).prctl(56,0,0,0,0) >= 0 else 1)' 2>/dev/null
}

# check_sanitizer_static_policy ROOT TRIPLE — gnu: dynamic-only sanitizers refuse -static.
check_sanitizer_static_policy() {
  local root="$1" t="$2" tmp name="sanitizer static policy $2"
  [ "$(triple_libc "$t")" = gnu ] || return 0
  tmp="$(mktemp -d)"
  if "$root/bin/$t-asan-clang" -static "$ROOT_DIR/tests/fixtures/sanitizers/asan.c" -o "$tmp/a" 2>/dev/null; then
    fail "$name" "asan -static linked (expected an error)"
  elif "$root/bin/elide-toolchain" env --target "$t" --sanitizer asan --static >/dev/null 2>&1; then
    fail "$name" "helper accepted --static --sanitizer asan"
  else
    pass "$name"
  fi
  rm -rf "$tmp"
}

# check_sanitizer_shared ROOT TRIPLE — JNI shape: -shared-libsan .so in an uninstrumented host.
check_sanitizer_shared() {
  local root="$1" t="$2" tmp rt name="sanitizer shared runtime $2"
  [ "$(triple_libc "$t")" = gnu ] || return 0
  tmp="$(mktemp -d)"
  rt="$root/lib/clang/$LLVM_MAJOR/lib/$t/libclang_rt.asan.so"
  if "$root/bin/$t-clang" -fsanitize=address -shared-libsan -shared -fPIC -g \
       "$ROOT_DIR/tests/fixtures/sanitizers/jni-lib.c" -o "$tmp/libnative.so" 2>"$tmp/err" \
     && "$root/bin/$t-clang" -g "$ROOT_DIR/tests/fixtures/sanitizers/jni-host.c" -o "$tmp/host" 2>>"$tmp/err" \
     && ! LD_PRELOAD="$rt" ASAN_OPTIONS=detect_leaks=0 "$tmp/host" "$tmp/libnative.so" >"$tmp/log" 2>&1 \
     && grep -q heap-buffer-overflow "$tmp/log"; then
    pass "$name"
  else
    fail "$name" "$(head -3 "$tmp/err" "$tmp/log" 2>/dev/null)"
  fi
  rm -rf "$tmp"
}
```

In `run_all_checks`, per target: `check_sanitizer_runtimes`, `check_sanitizer_trips`,
`check_sanitizer_static_policy`, `check_sanitizer_shared`. On darwin, add
`check_darwin_sanitizers`: the three dylibs exist and `asan.c` trips via
`arm64-apple-darwin-asan-clang`.

- [ ] **Step 3:** `./build.sh --from 90-package` → stage 95 shows `ok` for every runtime/trip line
  on linux-amd64. msan shows the `note` until Task 13; hwasan shows a note on x86_64. Commit.

### Task 8: Helper CLI — `--sanitizer` and `sanitizers`

**Files:** Modify `src/elide-toolchain`, `tests/unit/helper.test.sh`.

- [ ] **Step 1: Failing tests** (helper tests build a fake bundle tree; extend it with
  `share/elide-toolchain/sanitizers/x86_64-unknown-linux-gnu-{asan,msan,ubsan}.cfg`,
  `x86_64-unknown-linux-musl-ubsan.cfg`, the wrappers as empty executables,
  `lib/clang/23/lib/x86_64-unknown-linux-gnu/libclang_rt.asan.so`, and `share/elide-toolchain/VERSION`):

```bash
H="$B/bin/elide-toolchain"
out="$("$H" env --target x86_64-unknown-linux-gnu --sanitizer asan --format json 2>"$T/warn")"
assert_contains "$out" "\"CC\":\"$B/bin/x86_64-unknown-linux-gnu-asan-clang\""
assert_contains "$out" "\"CMAKE_TOOLCHAIN_FILE\":\"$B/share/elide-toolchain/cmake/x86_64-unknown-linux-gnu-asan.cmake\""
assert_contains "$out" "\"CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS\":\"-Zsanitizer=address -Zexternal-clangrt\""
assert_contains "$out" "\"ELIDE_SANITIZER_RUNTIME\":\"$B/lib/clang/23/lib/x86_64-unknown-linux-gnu/libclang_rt.asan.so\""
assert_contains "$(cat "$T/warn")" "not instrumented"            # no overlay yet
assert_fails "$H" env --target x86_64-unknown-linux-gnu --sanitizer msan   # overlay required
assert_fails "$H" env --target x86_64-unknown-linux-musl --sanitizer asan
assert_fails "$H" env --target x86_64-unknown-linux-gnu --sanitizer asan --static
assert_ok "$H" env --target x86_64-unknown-linux-musl --sanitizer ubsan --static
out="$("$H" env --target x86_64-unknown-linux-gnu --sanitizer ubsan --format json)"
assert_not_contains "$out" "RUSTFLAGS"
# overlay present: farm used for pkg-config, version must match
mkdir -p "$B/sysroot/x86_64-unknown-linux-gnu+msan/usr/lib"
: > "$B/share/elide-toolchain/sanitizers/x86_64-unknown-linux-gnu-msan.overlay.cfg"
printf '{"version":"%s"}\n' "$(cat "$B/share/elide-toolchain/VERSION")" > "$B/share/elide-toolchain/sanitizers/overlay.json"
out="$("$H" env --target x86_64-unknown-linux-gnu --sanitizer msan --format json)"
assert_contains "$out" "\"PKG_CONFIG_SYSROOT_DIR\":\"$B/sysroot/x86_64-unknown-linux-gnu+msan\""
printf '{"version":"1999.1.0"}\n' > "$B/share/elide-toolchain/sanitizers/overlay.json"
assert_fails "$H" env --target x86_64-unknown-linux-gnu --sanitizer msan
assert_contains "$("$H" sanitizers --target x86_64-unknown-linux-gnu)" "msan"
```

- [ ] **Step 2: Implement** in `src/elide-toolchain` (POSIX sh):

```sh
san_dir() { echo "$ROOT/share/elide-toolchain/sanitizers"; }
san_flag() {
  case $1 in asan) echo address ;; tsan) echo thread ;; msan) echo memory ;; lsan) echo leak ;;
    hwasan) echo hwaddress ;; ubsan) echo undefined ;; *) return 1 ;; esac
}
overlay_version() { # prints the overlay's version, empty if none
  f=$(san_dir)/overlay.json
  [ -f "$f" ] || return 0
  sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' "$f" | head -n 1
}
check_overlay() { # TARGET SAN -> 0 if the overlay layer for (T,S) is installed and matches
  [ -f "$(san_dir)/$1-$2.overlay.cfg" ] || return 1
  v=$(overlay_version); want=$(cat "$ROOT/share/elide-toolchain/VERSION")
  [ "$v" = "$want" ] || die "sanitizers overlay is $v but the bundle is $want; install the matching -sanitizers archive"
}
```

In `cmd_env`: parse `--sanitizer S` / `--sanitizer=S`. After `has_target` and the base `add`s:

```sh
  if [ -n "$san" ]; then
    san_flag "$san" >/dev/null || die "unknown sanitizer: $san (expected asan tsan msan ubsan lsan hwasan)"
    [ -f "$(san_dir)/$target-$san.cfg" ] || die "$san is not supported for $target (see: elide-toolchain sanitizers --target $target)"
    if [ "$static" = yes ] && [ "$san" != ubsan ]; then die "--static cannot be combined with --sanitizer $san (runtime needs dynamic linking)"; fi
    if check_overlay "$target" "$san"; then
      sr="$ROOT/sysroot/$target+$san"
    else
      [ "$san" != msan ] || die "msan needs the sanitizers overlay (elide-toolchain-$(cat "$ROOT/share/elide-toolchain/VERSION")-<os>-<arch>-sanitizers.tar.xz)"
      case $san in asan|tsan) echo "elide-toolchain: warning: libc++ and components are not instrumented for $san; install the sanitizers overlay for full coverage" >&2 ;; esac
      sr="$ROOT/sysroot/$target"
    fi
    replace CC "$bin/$target-$san-clang"
    replace CXX "$bin/$target-$san-clang++"
    replace CMAKE_TOOLCHAIN_FILE "$ROOT/share/elide-toolchain/cmake/$target-$san.cmake"
    replace "CARGO_TARGET_${rt}_LINKER" "$bin/$target-$san-clang"
    case $target in *-linux-*)
      replace PKG_CONFIG_SYSROOT_DIR "$sr"
      replace PKG_CONFIG_LIBDIR "$sr/usr/lib/pkgconfig:$sr/usr/share/pkgconfig" ;;
    esac
    [ "$san" = ubsan ] || add "CARGO_TARGET_${rt}_RUSTFLAGS" "-Zsanitizer=$(san_flag "$san") -Zexternal-clangrt"
    add ELIDE_SANITIZER "$san"
    for so in "$ROOT/lib/clang/"*"/lib/$target/libclang_rt.$san.so" \
              "$ROOT/lib/clang/"*"/lib/darwin/libclang_rt.${san}_osx_dynamic.dylib"; do
      [ -f "$so" ] && { add ELIDE_SANITIZER_RUNTIME "$so"; break; }
    done
  fi
```

`replace KEY VALUE` rewrites an existing line in `$ENV_FILE`
(`grep -v "^$1$TAB" … > tmp && add`). `cmd_sanitizers` prints a table
`TARGET  SANITIZER  RUNTIME(yes/no)  OVERLAY(installed/required/recommended/n/a)` from the cfg
files, `overlay.json` and `supported.json`. Extend the usage comment.

- [ ] **Step 3:** `tests/run.sh helper` → PASS; `shellcheck -s sh src/elide-toolchain` clean.
  Commit.

---

## Phase C — The overlay

### Task 9: Variant compile layer for component recipes

**Files:** Modify `scripts/lib/flags.sh`, `scripts/lib/components.sh`,
`scripts/components/aws-lc.sh`, `scripts/components/openssl.sh`, `tests/unit/flags.test.sh`,
`tests/unit/components.test.sh`.

**Interfaces:**
- `SANITIZER_LAYER=<san>` (exported by stage 60) makes `target_cflags T` start with
  `--config=$TOOLCHAIN_ROOT/share/elide-toolchain/sanitizers/<T>-<san>.cfg -L$TOOLCHAIN_ROOT/lib/<T>/<san>`
  (+ `-isystem $TOOLCHAIN_ROOT/include/<T>/asan/c++/v1` for asan). The overlay cfg is **not**
  used here: the farm does not exist yet while components build.
- `component_variant_args NAME` → extra args for the active `SANITIZER_LAYER` (empty otherwise).

- [ ] **Step 1: Failing tests:**

```bash
# flags.test.sh
TOOLCHAIN_ROOT=/tc
assert_not_contains "$(target_cflags x86_64-unknown-linux-gnu)" "--config="
assert_contains "$(SANITIZER_LAYER=msan target_cflags x86_64-unknown-linux-gnu)" \
  "--config=/tc/share/elide-toolchain/sanitizers/x86_64-unknown-linux-gnu-msan.cfg -L/tc/lib/x86_64-unknown-linux-gnu/msan"
assert_contains "$(SANITIZER_LAYER=asan target_cflags x86_64-unknown-linux-gnu)" "-isystem /tc/include/x86_64-unknown-linux-gnu/asan/c++/v1"
# components.test.sh
assert_eq "$(component_variant_args aws-lc)" ""
assert_eq "$(SANITIZER_LAYER=msan component_variant_args aws-lc)" "-DOPENSSL_NO_ASM=1"
assert_eq "$(SANITIZER_LAYER=asan component_variant_args aws-lc)" ""
assert_eq "$(SANITIZER_LAYER=msan component_variant_args openssl)" "no-asm"
```

- [ ] **Step 2: Implement.** `flags.sh`:

```bash
# sanitizer_layer_flags TRIPLE — compile/link layer for stage 60's instrumented component builds.
sanitizer_layer_flags() {
  local t="$1" s="${SANITIZER_LAYER:-}" r="$TOOLCHAIN_ROOT"
  [ -n "$s" ] || return 0
  printf -- '--config=%s/share/elide-toolchain/sanitizers/%s-%s.cfg -L%s/lib/%s/%s' "$r" "$t" "$s" "$r" "$t" "$s"
  if [ "$s" = asan ]; then printf -- ' -isystem %s/include/%s/asan/c++/v1' "$r" "$t"; fi
  printf ' '
}

target_cflags() {
  local t="$1" os arch
  os="$(triple_os "$t")"
  arch="$(cpu_to_arch "$(triple_cpu "$t")")"
  # shellcheck disable=SC2046
  printf '%s%s %s\n' "$(sanitizer_layer_flags "$t")" \
    "$(filter_flags_for_triple "$t" $(profile_flags "$os" "$arch"))" "$(arch_flags "$t")"
}
```

`components.sh`:

```bash
# component_variant_args NAME — extra recipe args under SANITIZER_LAYER (spec 2026-10-05 §6.4).
# MSan cannot see stores made by uninstrumented assembly; zstd and zlib-ng disable their own asm
# under __has_feature(memory_sanitizer), aws-lc and OpenSSL need it switched off explicitly.
component_variant_args() {
  case "${SANITIZER_LAYER:-}:$1" in
    msan:aws-lc) echo "-DOPENSSL_NO_ASM=1" ;;
    msan:openssl) echo "no-asm" ;;
    *) echo "" ;;
  esac
}
```

`aws-lc.sh`: append `$(component_variant_args aws-lc)` (read into an array) to the static
`cmake_target` call, and skip the shared build when `SANITIZER_LAYER` is set. `openssl.sh`:
append `$(component_variant_args openssl)` to its `Configure` arguments and pass `no-shared`
when `SANITIZER_LAYER` is set.

- [ ] **Step 3:** `tests/run.sh flags components` → PASS. Commit.

### Task 10: mimalloc forwarding shim

**Files:** Create `src/mimalloc-sanitizer-shim.c`.

- [ ] **Step 1:** Write the shim from spike E's file. It covers the `mi_*` entry points the
  consumers use (malloc/zalloc/calloc/realloc/free, aligned variants, `mi_usable_size`,
  `mi_strdup`, `mi_free_size`, `mi_option_*` and `mi_collect` as no-ops, `mi_version`). Add any
  symbol from `mimalloc.h` that Elide/Bali/Komodo reference: grep those repos for `mi_[a-z_]*(`
  and record the list in the file header. Every function forwards to the libc allocator, which
  every sanitizer intercepts. `mi_version()` returns `MI_MALLOC_VERSION` from the bundled
  `mimalloc.h` so version checks pass.
- [ ] **Step 2:** Prove it standalone with the Task 6 wrappers on the existing build:

```bash
B=out/linux-amd64/elide-toolchain; T=x86_64-unknown-linux-gnu
$B/bin/$T-asan-clang -O2 -flto=thin -c src/mimalloc-sanitizer-shim.c -I$B/sysroot/$T/usr/include -o /tmp/shim.o
```

Expected: no warnings with `-Wall -Wextra -Werror`. Commit.

### Task 11: Stage 60 — sanitizer variants

**Files:** Create `scripts/stages/60-sanitizer-variants.sh`,
`tests/stages/60-sanitizer-variants.check.sh`; modify `build.sh` (STAGES list and usage).

**Interfaces:**
- Consumes: stage-1 clang (variant libc++), the bundle's `<T>-<san>-clang` wrappers and runtime
  cfgs (Task 6), recipes (Task 9), shim (Task 10), `runtimes_common_args`/`cxx_runtime_args` (Task 4).
- Produces in `$BUNDLE_DIR`, for each gnu T in `$TARGETS` and S in `triple_variants T`:
  `lib/T/S/libc++{,abi,experimental}.a`, `include/T/asan/c++/v1/__config_site` (asan),
  `sysroot/T+S/` (farm), `share/elide-toolchain/sanitizers/T-S.overlay.cfg`.

- [ ] **Step 1: Failing stage check** `tests/stages/60-sanitizer-variants.check.sh` (common header):

```bash
[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }
tmp="$(mktemp -d)"
for t in $ALL_TARGETS; do
  for s in $(triple_variants "$t"); do
    d="$BUNDLE_DIR/lib/$t/$s"; farm="$BUNDLE_DIR/sysroot/$t+$s"
    for f in libc++.a libc++abi.a; do assert_file "$d/$f"; done
    assert_fails test -e "$d/libunwind.a"
    assert_ok test -L "$farm/usr/include"
    assert_ok test -f "$farm/usr/lib/libz.a"; assert_fails test -L "$farm/usr/lib/libz.a"
    assert_fails test -e "$farm/usr/lib/libcrypto.so"
    assert_file "$BUNDLE_DIR/share/elide-toolchain/sanitizers/$t-$s.overlay.cfg"
    sym="$(san_symbol "$s")"
    assert_ok sh -c "'$BUNDLE_DIR/bin/llvm-nm' '$farm/usr/lib/libz.a' 2>/dev/null | grep -q '$sym'"
    assert_ok sh -c "'$BUNDLE_DIR/bin/llvm-nm' '$d/libc++.a' 2>/dev/null | grep -q '$sym'"
    assert_ok "$BUNDLE_DIR/bin/$t-$s-clang++" -g -x c "$ROOT_DIR/tests/fixtures/sanitizers/workload.c" -x none \
      -lz -lzstd -o "$tmp/w-$s"
    assert_ok "$tmp/w-$s"
  done
  [ "$(triple_libc "$t")" = gnu ] && [ -n "$(triple_variants "$t")" ] && \
    assert_contains "$(cat "$BUNDLE_DIR/include/$t/asan/c++/v1/__config_site")" "_LIBCPP_INSTRUMENTED_WITH_ASAN 1"
done
rm -rf "$tmp"; finish
```

- [ ] **Step 2: Implement** `scripts/stages/60-sanitizer-variants.sh`:

```bash
# shellcheck shell=bash
# Stage 60: sanitizer variants for the gnu triples (spec 2026-10-05 §6.4): instrumented libc++
# (no libunwind), instrumented components via the normal recipes, a mimalloc forwarding shim,
# and a relative-symlink farm sysroot sysroot/<T>+<san>/ per variant.

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t s
  export TOOLCHAIN_ROOT="$BUNDLE_DIR"
  check_component_conflicts
  for t in $TARGETS; do
    for s in $(triple_variants "$t"); do
      log "sanitizer variant $s -> $t"
      build_variant_cxx "$t" "$s"
      build_variant_components "$t" "$s"
      build_mimalloc_shim "$t" "$s"
      assemble_variant_sysroot "$t" "$s"
      install_sanitizer_overlay_frontends "$BUNDLE_DIR" "$t" "$s"
    done
  done
}

variant_stage_dir() { printf '%s/variants/%s/%s\n' "$BUILD_DIR" "$2" "$1"; }   # TRIPLE SAN

build_variant_cxx() {
  local t="$1" s="$2" b inst args=() extra=()
  b="$(variant_stage_dir "$t" "$s")/cxx"; inst="$(variant_stage_dir "$t" "$s")/cxx-install"
  mapfile -t args < <(runtimes_common_args "$t")
  mapfile -t extra < <(cxx_runtime_args "$t")
  fresh_dir "$b"; rm -rf "$inst"
  cmake -S "$ROOT_DIR/llvm/runtimes" -B "$b" "${args[@]}" "${extra[@]}" \
    -DCMAKE_INSTALL_PREFIX="$inst" \
    -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx" \
    -DLLVM_USE_SANITIZER="$(san_cmake "$s")" \
    -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=OFF
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
  mkdir -p "$BUNDLE_DIR/lib/$t/$s"
  cp "$inst/lib/$t/libc++.a" "$inst/lib/$t/libc++abi.a" "$inst/lib/$t/libc++experimental.a" "$BUNDLE_DIR/lib/$t/$s/"
  rm -f "$BUNDLE_DIR/lib/$t/$s/libunwind.a"   # never ship an instrumented unwinder (spike C)
  if [ "$s" = asan ]; then
    mkdir -p "$BUNDLE_DIR/include/$t/asan/c++/v1"
    cp "$inst/include/$t/c++/v1/__config_site" "$BUNDLE_DIR/include/$t/asan/c++/v1/"
  fi
}

build_variant_components() {
  local t="$1" s="$2" prefix c
  prefix="$(variant_stage_dir "$t" "$s")/usr"
  rm -rf "$prefix"; mkdir -p "$prefix"
  (
    export SANITIZER_LAYER="$s"
    BUILD_DIR="$BUILD_DIR/variants/$s"   # stage_source/component_build_dir stay out of stage 50's trees
    for c in "${COMPONENTS[@]}"; do
      component_enabled "$c" || continue
      log "component $c -> $t ($s)"
      "$(component_fn "$c")" "$t" "$prefix"
    done
  )
}

build_mimalloc_shim() {
  local t="$1" s="$2" o
  o="$(variant_stage_dir "$t" "$s")/mimalloc-shim.o"
  # Base front-end + the runtime layer: the msan wrapper refuses to run until the overlay cfg exists.
  # shellcheck disable=SC2046
  "$BUNDLE_DIR/bin/$t-clang" $(SANITIZER_LAYER="$s" sanitizer_layer_flags "$t") -O2 -flto=thin -fPIC \
    -I"$(target_prefix "$t")/include" -c "$ROOT_DIR/src/mimalloc-sanitizer-shim.c" -o "$o"
  rm -f "$(variant_stage_dir "$t" "$s")/usr/lib/libmimalloc.a"
  "$BUNDLE_DIR/bin/llvm-ar" rcs "$(variant_stage_dir "$t" "$s")/usr/lib/libmimalloc.a" "$o"
}

# assemble_variant_sysroot TRIPLE SAN — farm over sysroot/<T>: relative symlinks everywhere, real
# files for the instrumented archives, and no .so whose .a was replaced (lld prefers .so).
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
  for a in "$(variant_stage_dir "$t" "$s")"/usr/lib/*.a; do
    n="${a##*/}"
    rm -f "$farm/usr/lib/$n"; cp "$a" "$farm/usr/lib/$n"
    rm -f "$farm/usr/lib/${n%.a}.so" "$farm/usr/lib/${n%.a}".so.*
  done
}
```

Add `60-sanitizer-variants` to `STAGES` in `build.sh` between `50-components` and `90-package`,
and to the usage text. When `triple_variants` is empty for every target, the stage is a no-op.

- [ ] **Step 3:** `./build.sh --only 60-sanitizer-variants`, then `bash tests/stages/60-sanitizer-variants.check.sh`
  → PASS. Expected wall time on 32 threads ≈ 3 min per gnu triple (spikes C/D). Commit with the
  measured time.

### Task 12: Stage 90 — the overlay archive and manifest

**Files:** Modify `scripts/stages/90-package.sh`, `scripts/gen-manifest.py`,
`tests/unit/manifest.test.sh`, `tests/stages/90-package.check.sh`.

**Interfaces:**
- `overlay_paths` → newline-separated paths relative to `$OUT_DIR` (each starts with `$TOOLCHAIN_NAME/`)
- Main archive `…-<os>-<arch>.tar.xz` excludes them. Overlay archive (name from Task 1) contains
  exactly them plus `share/elide-toolchain/sanitizers/overlay.json`.
- `manifest.json` gains `sanitizers` (spec §4.4). `gen-manifest.py overlay` prints `overlay.json`.

- [ ] **Step 1: Failing tests.** `manifest.test.sh`:

```bash
m="$(ENABLED_COMPONENTS="zlib-ng zstd" python3 "$ROOT_DIR/scripts/gen-manifest.py" manifest)"
assert_contains "$m" '"sanitizers"'
assert_contains "$m" '"x86_64-unknown-linux-musl": {"runtimes": ["ubsan"], "overlay": []}'
o="$(python3 "$ROOT_DIR/scripts/gen-manifest.py" overlay)"
assert_contains "$o" "\"version\": \"$TOOLCHAIN_VERSION\""
```

`90-package.check.sh`: list both archives with `tar -tJf`. No `+asan/` path appears in the main
archive. Every overlay member matches an `overlay_paths` prefix. The overlay has exactly one
top-level dir, `elide-toolchain/`.

- [ ] **Step 2: Implement.** `90-package.sh`:

```bash
# overlay_paths — bundle paths that belong to the sanitizers overlay, relative to $OUT_DIR.
overlay_paths() {
  local t s n="$TOOLCHAIN_NAME"
  for t in $ALL_TARGETS; do
    for s in $(triple_variants "$t"); do
      printf '%s\n' "$n/lib/$t/$s" "$n/sysroot/$t+$s" "$n/share/elide-toolchain/sanitizers/$t-$s.overlay.cfg"
      if [ "$s" = asan ]; then printf '%s\n' "$n/include/$t/asan"; fi
    done
  done
}
```

Write `overlay.json` (via `gen-manifest.py overlay`) into `share/elide-toolchain/sanitizers/`
before archiving. Main archive: `tar -C "$OUT_DIR" --exclude-from=<(overlay_paths) … -cf - "$TOOLCHAIN_NAME"`
(GNU tar matches the exclude patterns against member names; on darwin `overlay_paths` is empty
so `bsdtar` never sees the option). If `overlay_paths` is non-empty, the overlay archive is
`tar -C "$OUT_DIR" -cf - $(overlay_paths) "$n/share/elide-toolchain/sanitizers/overlay.json" | xz -T0 -9`,
plus a `.sha256`. `relocate_prefix` is not needed for farms: their `.pc` files are symlinks.
`check_no_build_paths` still scans everything. `gen-manifest.py`: build the `sanitizers` map from
the same env variables (pass `SANITIZERS_LINUX_GNU` etc. through `os.environ`), mirroring
`triple_sanitizers`/`triple_variants`.

- [ ] **Step 3:** `tests/run.sh manifest` → PASS; `./build.sh --only 90-package`; the stage check
  passes. Overlay size is ~65 MiB xz for linux-amd64 (spike D: 65.3 MiB). Commit.

### Task 13: Verification of the overlay

**Files:** Modify `scripts/stages/95-verify.sh`, `scripts/verify/checks.sh`; create
`tests/fixtures/sanitizers/cmake/CMakeLists.txt`, `tests/fixtures/sanitizers/rust/{main.rs,c_part.c}`.

- [ ] **Step 1:** In `95-verify.sh`, after extracting the main archive, extract the overlay
  (when it exists) into the same `$VERIFY_DIR`, after verifying its `.sha256`.
- [ ] **Step 2: Checks** (spike B/D/E/F/G recipes). Add:

```bash
# check_sanitizer_variant_clean ROOT TRIPLE SAN — the false-positive check (spec §8).
check_sanitizer_variant_clean() {
  local root="$1" t="$2" s="$3" tmp c link defs=() libs=() more=() lto name
  tmp="$(mktemp -d)"
  for c in $(enabled_components); do
    link="$(component_link "$c")"; [ -n "$link" ] || continue
    defs+=("-D${link%%|*}"); read -r -a more <<< "${link#*|}"; libs+=("${more[@]}")
  done
  component_enabled brotli && { defs+=(-DHAVE_BROTLIENC); libs+=(-lbrotlienc); }
  for lto in "" -flto=thin; do
    name="sanitizer $s clean $t${lto:+ (thinlto)}"
    # shellcheck disable=SC2086
    if "$root/bin/$t-$s-clang++" -g $lto "$ROOT_DIR/tests/fixtures/sanitizers/clean.cpp" -o "$tmp/cxx" 2>"$tmp/err" \
       && "$root/bin/$t-$s-clang++" -g $lto "$ROOT_DIR/tests/fixtures/sanitizers/exc.cpp" -DNO_BUG -o "$tmp/exc" 2>>"$tmp/err" \
       && "$root/bin/$t-$s-clang++" -g $lto "${defs[@]}" -x c "$ROOT_DIR/tests/fixtures/sanitizers/workload.c" -x none \
            "${libs[@]}" -lmimalloc -lpthread -o "$tmp/w" 2>>"$tmp/err" \
       && "$tmp/cxx" >"$tmp/log" 2>&1 && "$tmp/exc" >>"$tmp/log" 2>&1 && "$tmp/w" >>"$tmp/log" 2>&1 \
       && ! grep -qE 'Sanitizer|runtime error' "$tmp/log"; then
      pass "$name"
    else
      fail "$name" "$(head -5 "$tmp/err" "$tmp/log" 2>/dev/null)"
    fi
  done
  rm -rf "$tmp"
}
```

(`exc.cpp` gets `#ifndef NO_BUG` around its deliberate uninitialised read.) Also add
`check_sanitizer_variant_instrumented`. Every real file under `sysroot/<T>+<S>/usr/lib` and
`lib/<T>/<S>` must have `llvm-nm` output containing `san_symbol S`. There must be no
`lib/<T>/<S>/libunwind.a`. `find -L <farm> -type l` (dangling links) must be empty. No `<x>.so`
may sit next to a real `<x>.a`. Then:

- `check_sanitizer_cmake`: configures `tests/fixtures/sanitizers/cmake` (`find_package(ZLIB)`,
  `find_library(ZSTD zstd)`, `message(STATUS "ZLIB=${ZLIB_LIBRARIES}")`) with
  `-DCMAKE_TOOLCHAIN_FILE=$root/share/elide-toolchain/cmake/<T>-<S>.cmake`, asserts the message
  contains `sysroot/<T>+<S>/usr/lib/libz.a`, builds the target and runs it.
- `check_sanitizer_mimalloc`: `mimalloc-oob.c` linked with `-lmimalloc` via `<T>-asan-clang` must
  report `heap-buffer-overflow`; `mimalloc-api.c` via `<T>-tsan-clang` and `<T>-msan-clang` must
  exit 0 without a report.
- `check_rust_sanitizer`: if `rustup run nightly rustc -vV` works and its `LLVM version` major is ≤
  `LLVM_MAJOR`, compile `rust/c_part.c` with `<T>-asan-clang -c`, archive it, run
  `rustc +nightly --target <T> -Zsanitizer=address -Zexternal-clangrt -Clinker=$root/bin/<T>-asan-clang -L … -l static=… -l z main.rs`,
  and expect `heap-buffer-overflow` from `./main trip`. Otherwise print `note … skipped`.
- Extend `check_bitcode` to iterate the farms' real files and `lib/<T>/<S>/*.a`, with the same
  rules as the main archives.
- Extend `check_relocatable`: after the move, rerun `check_sanitizer_trips` for `asan` on the gnu
  triple against `$moved`.

In `run_all_checks`, per gnu target and per `triple_variants` S: `check_sanitizer_variant_clean`,
`check_sanitizer_variant_instrumented`, `check_sanitizer_cmake`. Once per gnu target:
`check_sanitizer_mimalloc`, `check_rust_sanitizer`.

- [ ] **Step 3:** `./build.sh --from 90-package` → `verification: 0 failure(s)` on linux-amd64,
  including the msan trip, which now runs because the overlay is extracted. Negative control,
  once by hand: delete `libcrypto.a` from one farm in `$VERIFY_DIR`, recreate the `.so` symlink,
  rerun `check_sanitizer_variant_clean` for msan, and expect FAIL. Commit.

---

## Phase D — Distribution

### Task 14: GitHub Action — `sanitizers` and `sanitizer` inputs

**Files:** Modify `action/action.yml`, `action/lib.ts`, `action/main.ts`, `action/lib.test.ts`,
`action/dist/main.js`.

- [ ] **Step 1: Failing tests** (`lib.test.ts`): `overlayAssetName("2026.10.0","linux","amd64")`
  returns Task 1's name. `overlayAssetName(…,"darwin","arm64")` returns `null`.
  `needsOverlay("msan")` and `needsOverlay("asan")` are true; `needsOverlay("ubsan")` is false.
  `envArgs({target, sanitizer: "tsan"})` yields
  `["env","--target",t,"--sanitizer","tsan","--format","github"]`.
- [ ] **Step 2:** Inputs `sanitizers` (boolean, default `false`) and `sanitizer` (string; requires
  `target`; asan/tsan/msan imply `sanitizers: true`). In `main.ts`, after extracting the main
  bundle, if needed, download and verify the overlay with the same resolver (Releases API → R2
  fallback, `.sha256` check) and extract it into the **same** cache dir before `tc.cacheDir`.
  Output `sanitizers`: the JSON list of `*.overlay.cfg` stems found. Rebuild `dist/main.js` with
  bun.
- [ ] **Step 3:** `bun test` → PASS; `bun run build` leaves `git diff --exit-code action/dist`
  clean after the commit. Commit.

### Task 15: CI and release workflows

**Files:** Modify `.github/workflows/job.build.yml`, `on.release.yml`, `job.action-e2e.yml`.

- [ ] **Step 1:** `job.build.yml`: on Linux, install a pinned Rust nightly for
  `check_rust_sanitizer` (`rustup toolchain install nightly-2026-09-29 --profile minimal`; bump
  with LLVM). `dist/*` already uploads the overlay. Raise nothing else: the timeouts (720 min)
  have headroom.
- [ ] **Step 2:** `on.release.yml`: attach `dist/*-sanitizers*` (and `.sha256`) to the release,
  and include them in the R2 mirror sync. Provenance attestation covers them (same `subject-path`
  glob).
- [ ] **Step 3:** `job.action-e2e.yml`: add a matrix leg per Linux arch with
  `target: <arch>-unknown-linux-gnu`, `sanitizer: msan`, and `archive` / an overlay archive input
  (add an `overlay-archive` testing input mirroring `archive` in Task 14). It builds and runs
  `tests/fixtures/sanitizers/msan.c` (expect the report) and `workload.c` (expect clean) with
  `$CC` from the action env.
- [ ] **Step 4:** Push to a branch, watch `on.pr.yml`, and record per-job wall-time deltas in the
  PR description (spec §9 estimates: Linux +12–20 min, darwin +5–8 min). Commit.

### Task 16: Overlay install for mise users

**Files:** Modify `src/elide-toolchain`, `tests/unit/helper.test.sh`.

- [ ] **Step 1: Failing tests:** `elide-toolchain overlay install sanitizers --from <local.tar.xz>`
  extracts into the bundle root. It refuses an archive whose `overlay.json` version differs from
  `share/elide-toolchain/VERSION`. It refuses a missing `.sha256` unless `--no-verify` is given.
- [ ] **Step 2:** Implement: `--from FILE|URL` (URL via `curl -fsSL` or `wget -qO-`); the default
  URL comes from the GitHub release `https://github.com/elide-dev/toolchain/releases/download/v<ver>/<asset>`,
  with an R2 fallback `https://static.elideusercontent.com/toolchain/<ver>/<asset>`. Verify the
  sha256 (`sha256sum`, or `shasum -a 256` on macOS). Extract with `tar -xJf - -C "$ROOT/.."`,
  then check `overlay.json`. If the version check fails, remove what was extracted (list from
  `tar -tJf`).
- [ ] **Step 3:** `tests/run.sh helper` → PASS. Commit.

### Task 17: README, timings, full end-to-end build

**Files:** Modify `README.md`, `docs/notes/build-timings.md`.

- [ ] **Step 1:** README: a "Sanitizers" section with the support matrix (spec §3, short form),
  the overlay asset and how to install it (action input, `overlay install`, manual
  `tar -xJf … -C <parent of elide-toolchain>`), `elide-toolchain env --sanitizer`, wrappers and
  CMake files. Include the caveats: mimalloc (§7.1), one runtime for Rust (§7.3), native-image
  unsupported (§7.4), musl = UBSan only (§3.2), darwin rpath (§7.6), and the JNI `LD_PRELOAD`
  recipe (§11.1). Add consumer notes for Elide, Bali and Komodo (spec §11), kept short.
- [ ] **Step 2:** `REQUIRE_CONTAINER_CHECKS=yes ./build.sh --clean` on linux-amd64; update
  `docs/notes/build-timings.md` with stage 30 (now incl. pass 3), stage 60, the 90 split and 95
  rows, plus both archive sizes.
- [ ] **Step 3:** The same on linux-arm64 (first arm64 execution of sanitizers: HWASan trip,
  TSan/MSan VMA). Record findings in `docs/notes/sanitizer-spikes.md` under a new "arm64"
  heading. Fix or downgrade matrix entries (spec §3) with evidence.
- [ ] **Step 4:** darwin-arm64 full build; `check_darwin_sanitizers` passes. Commit.

---

## Out of scope for this plan (tracked follow-ups)

- musl ASan/TSan/MSan/LSan, through a mallocng `libc.so` farm (spec §3.2), and fixing dynamic
  musl (spec §10).
- A darwin instrumented-components overlay (spec Q7).
- CFI, DFSan, SafeStack, NSan, TySan, RTSan, MemProf, Scudo and GWP-ASan runtimes.
- Pre-instrumented Rust `std` (`-Zbuild-std` artifacts) for MSan/TSan.
- Sanitized builds of the shipped clang/lld.
