# Propeller, DeduBB, mimalloc shim and MemProf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Revive llvm-propeller as a shipped tool, ship DeduBB on top of it (compiler + Propeller path), add `libmimalloc-shim` as a first-class allocator component (MemProf hot/cold now, allocation tokens later), and ship MemProf (runtime + backports) in the elide-toolchain LLVM 23.1.2 bundles, with verification and a documented downstream flag contract.

**Architecture:** LLVM changes are `src/patches/llvm/NNNN-*.patch`, applied to the `llvm` submodule by `apply_patches` in stages 10/30/40. Stage 00 un-applies them before its clean-tree check. A new Linux-only stage `45-propeller` builds `generate_propeller_profiles` against the stage-2 LLVM build tree, using offline-cached deps and its own patch series (find_package LLVM, libelf→LLVM Object, offline deps, DeduBB). Stage 30 adds the compiler-rt memprof runtime for `x86_64-unknown-linux-gnu`. Stage 35 adds `libmimalloc-shim.a` to every sysroot. The helper gains `flags`. Stage 95 gains Propeller, DeduBB, shim and MemProf checks.

**Tech Stack:** bash, POSIX sh (helper), CMake + Ninja, LLVM 23.1.2, llvm-propeller (`ddfb8b7`), abseil/protobuf/googletest/quipper, compiler-rt, mimalloc 3.5.4, C++17/20, Python 3 (manifest).

**Spec:** `docs/superpowers/specs/2026-10-05-memprof-dedubb-design.md` (§N below). Evidence: `docs/notes/memprof-dedubb-research.md` (EN = experiment N). Issue draft for the LLVM patches: `docs/notes/llvm-backports-issue.md`.

## Global Constraints

- Everything in the base plan's Global Constraints holds (glibc floor 2.34, macOS min 12.0, relocatable bundle, no `sudo`, writes only under `out/` and `dist/`, bash ≥ 4 for build scripts, POSIX sh for the helper).
- LLVM stays at `llvmorg-23.1.2`. Submodules are never edited by hand: every change is a patch in `src/patches/<component>/`, and patches never overlap hunks (spec D2).
- No network after stage 00. Propeller's third-party archives are pinned by sha256 in `versions.env` and cached in `out/cache/propeller-deps/`.
- DeduBB is applied by default and must be inert without `-dedubb-directives` (`check_dedubb_inert`).
- The bundle never enables `-supports-hot-cold-new` or `-fsanitize=alloc-token` on its own.
- `libmimalloc-shim` v1 symbols and semantics are frozen once released (spec §5.4).
- Dynamic musl is not supported downstream; musl checks link `-static`.
- Commit messages: plain, no attribution trailers.

## Review Focus

1. **Re-running stages on a patched tree.** `./build.sh --from 40-llvm-stage2` after a full build, then a full `./build.sh` (stage 00's clean-tree check). Every patch is detected as applied, and stage 00 un-applies before checking. Pinned by Task 1's unit tests and the double-run step in Task 2.
2. **Shipped compiler behaviour for consumers who don't use DeduBB.** Byte-identical output without directives. Pinned by `check_dedubb_inert` (Task 9) and the gate in Task 7.
3. **Propeller tool hygiene.** No `libelf`, no `libstdc++`, glibc floor ≤ 2.34, no network during stage 45. Pinned by Task 5's stage check (and by running stage 45 with the network unshared, `unshare -rn`, if available).
4. **Shim on musl.** A single mimalloc instance (libc's), static link, correct partitions. Pinned by the shim test running on musl (Task 12/13).
5. **Shim ABI stability.** v1 symbol list fixed by a checked-in expected-symbols file (Task 12).

---

## File Structure

```
scripts/lib/common.sh                         # MODIFY (T1) '# requires:' gating, unapply_patches
scripts/stages/00-sources.sh                  # MODIFY (T1, T3) unapply before clean check; fetch propeller deps
scripts/stages/10-llvm-stage1.sh, 30-runtimes.sh, 40-llvm-stage2.sh   # MODIFY (T2, T11)
scripts/stages/45-propeller.sh                # NEW (T5)
scripts/stages/35-mimalloc.sh                 # MODIFY (T12)
scripts/lib/platform.sh                       # MODIFY (T11) memprof_supported
scripts/verify/checks.sh                      # MODIFY (T6, T9, T13, T14)
scripts/gen-manifest.py                       # MODIFY (T16)
src/elide-toolchain                           # MODIFY (T15) `flags`
vars.sh                                       # MODIFY (T2) LLVM_DEDUBB, BUILD_PROPELLER
versions.env                                  # MODIFY (T3) propeller dep pins
src/patches/llvm/0001-memprof-deterministic-clone-tiebreak.patch   # NEW (T10) #222126
src/patches/llvm/0002-memprof-histogram-tail-granule.patch         # NEW (T10) #208911
src/patches/llvm/0100-dedubb-codegen.patch                         # NEW (T7)
src/patches/llvm-propeller/0001-find-package-llvm.patch            # REWRITE (T4)
src/patches/llvm-propeller/0002-mccontext-asminfo-pointer.patch    # DELETE (T4)
src/patches/llvm-propeller/0002-quipper-libelf-to-llvm-object.patch   # NEW (T4)
src/patches/llvm-propeller/0003-offline-deps.patch                 # NEW (T4)
src/patches/llvm-propeller/0004-dedubb.patch                       # NEW (T8)
src/mimalloc-shim/{core.cc,hotcold.cc,mimalloc-shim.h,mimalloc-shim.pc.in,abi-v1.symbols}   # NEW (T12)
tests/unit/{common,platform,helper,manifest}.test.sh                # MODIFY
tests/stages/{30-runtimes,35-mimalloc,40-llvm-stage2}.check.sh      # MODIFY
tests/stages/45-propeller.check.sh                                  # NEW (T5)
tests/fixtures/dedubb/{a.c,b.c}                                     # NEW (T6)
tests/fixtures/mimalloc-shim-test.cc                                # NEW (T13)
tests/fixtures/{memprof.cc,memprof-ctx.cc,memprof-ctx.yaml}          # NEW (T14)
docs/notes/llvm-patches.md                                          # NEW (T7) patch ledger + bump procedure
docs/notes/llvm-backports-issue.md                                  # EXISTS (draft issue; maintainer files it)
README.md                                                           # MODIFY (T17)
```

---

## Phase A — Patch plumbing

### Task 1: `apply_patches` gating, `unapply_patches`, stage 00 clean check

**Files:** Modify `scripts/lib/common.sh`, `scripts/stages/00-sources.sh`, `tests/unit/common.test.sh`

**Interfaces:**
- `apply_patches COMPONENT DIR` (unchanged signature). A patch whose first line is `# requires: VAR` is skipped unless `is_yes "${!VAR:-}"`.
- New `unapply_patches COMPONENT DIR`: in **reverse** order, `git apply --reverse` each patch that `--reverse --check`s; skips the rest. Idempotent.
- Stage 00 `check_submodules` calls `unapply_patches <component> <path>` for every submodule that has `src/patches/<component>/` (`llvm`→`llvm`, `llvm-propeller`→`llvm-propeller`, `glibc`→`glibc`) **before** the dirty check. Otherwise the first rerun after stage 10 would die on "submodules with modified … files".

- [ ] **Step 1: Failing tests** (append to `tests/unit/common.test.sh`):

```bash
work="$ROOT_DIR/out/test-tmp/series"; rm -rf "$work"; mkdir -p "$work/src" "$work/patches/demo"
printf 'a\nb\nc\nd\ne\nf\ng\n' > "$work/src/f.txt"; printf 'x\n' > "$work/src/g.txt"
cat > "$work/patches/demo/0001-a.patch" <<'EOF'
--- a/f.txt
+++ b/f.txt
@@ -1,3 +1,3 @@
-a
+A
 b
 c
EOF
cat > "$work/patches/demo/0002-g.patch" <<'EOF'
# upstream: none (test)
--- a/f.txt
+++ b/f.txt
@@ -5,3 +5,3 @@
 e
 f
-g
+G
EOF
cat > "$work/patches/demo/0003-gated.patch" <<'EOF'
# requires: DEMO_KNOB
--- a/g.txt
+++ b/g.txt
@@ -1 +1 @@
-x
+X
EOF
run() { env PATCHES_DIR="$work/patches" DEMO_KNOB="${DEMO_KNOB:-no}" bash -c "source '$ROOT_DIR/scripts/lib/common.sh'; ROOT_DIR='$ROOT_DIR' $1 demo '$work/src'"; }
assert_ok run apply_patches
assert_eq "$(head -1 "$work/src/f.txt")$(tail -1 "$work/src/f.txt")$(cat "$work/src/g.txt")" "AGx" "series applied, gated skipped"
assert_ok run apply_patches                                   # re-run is a no-op
DEMO_KNOB=yes assert_ok run apply_patches
assert_eq "$(cat "$work/src/g.txt")" "X" "gated patch applied when knob is yes"
DEMO_KNOB=yes assert_ok run unapply_patches
assert_eq "$(cat "$work/src/f.txt" | tr -d '\n')$(cat "$work/src/g.txt")" "abcdefgx" "unapply restores pristine tree"
assert_ok run unapply_patches                                 # idempotent
rm -rf "$ROOT_DIR/out/test-tmp"
```
(If `assert_ok` cannot take an env prefix, use `DEMO_KNOB=yes run …` inside a subshell plus `assert_eq "$?" 0`.)

- [ ] **Step 2:** `tests/run.sh common` → FAIL.

- [ ] **Step 3: Implement** (`scripts/lib/common.sh`):

```bash
# patch_required_var PATCH — the VAR of a leading '# requires: VAR' line, if any.
patch_required_var() { head -n1 "$1" | sed -n 's/^# requires: *\([A-Za-z_][A-Za-z0-9_]*\) *$/\1/p'; }
```
In `apply_patches`, after `[ -e "$patch" ] || continue`:
```bash
    local req; req="$(patch_required_var "$patch")"
    if [ -n "$req" ] && ! is_yes "${!req:-}"; then log "skipping $(basename "$patch") ($req is not yes)"; continue; fi
```
New function:
```bash
# unapply_patches COMPONENT DIR — reverse every applied patch of COMPONENT, last first.
unapply_patches() {
  local component="$1" dir="$2" patch_dir patches=() i
  patch_dir="${PATCHES_DIR:-$ROOT_DIR/src/patches}/$component"
  [ -d "$patch_dir" ] || return 0
  for i in "$patch_dir"/*.patch; do [ -e "$i" ] && patches+=("$i"); done
  for (( i=${#patches[@]}-1; i>=0; i-- )); do
    if (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$dir")" git apply --reverse --check "${patches[$i]}" 2>/dev/null); then
      log "un-applying $(basename "${patches[$i]}") from $component"
      (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$dir")" git apply --reverse "${patches[$i]}")
    fi
  done
}
```
Stage 00 `check_submodules`, before computing `dirty`:
```bash
  local c
  for c in glibc llvm llvm-propeller; do
    [ -d "$ROOT_DIR/$c" ] && unapply_patches "$c" "$ROOT_DIR/$c"
  done
```

- [ ] **Step 4:** `tests/run.sh` → all pass, shellcheck clean.

- [ ] **Step 5: Commit** `git commit -m "build: gate patches on '# requires:'; un-apply patches before the clean-tree check"`

---

### Task 2: Apply `src/patches/llvm` in the LLVM stages; knobs

**Files:** Modify `scripts/stages/10-llvm-stage1.sh`, `30-runtimes.sh`, `40-llvm-stage2.sh`, `vars.sh`; create `src/patches/llvm/.gitkeep`

- [ ] **Step 1:** First line of each `stage_main`: `apply_patches llvm "$ROOT_DIR/llvm"` (stage 10 covers the Linux and darwin paths).
- [ ] **Step 2:** `vars.sh`:

```bash
# LLVM feature patches (src/patches/llvm, '# requires:' headers) and tools
LLVM_DEDUBB=${LLVM_DEDUBB:-yes}
BUILD_PROPELLER=${BUILD_PROPELLER:-yes}   # Linux only; stage 45
```
- [ ] **Step 3:** With only `.gitkeep` present, `./build.sh --only 10-llvm-stage1` behaves exactly as before.
- [ ] **Step 4 (after T7/T10 land, re-run as a regression):** `./build.sh --only 40-llvm-stage2` twice → second run logs `already applied` for every patch; then `./build.sh --only 00-sources` → logs `un-applying …` and passes the clean check.
- [ ] **Step 5: Commit** `git commit -m "build: apply src/patches/llvm in LLVM stages; LLVM_DEDUBB and BUILD_PROPELLER knobs"`

---

## Phase B — Propeller revival

### Task 3: Pin and pre-fetch Propeller's third-party deps (stage 00)

**Files:** Modify `versions.env`, `scripts/stages/00-sources.sh`; add `tests/unit/` coverage if the fetch helper is factored into `common.sh`

**Interfaces:**
- `versions.env`:
```
LLVM_PROPELLER_REV=ddfb8b7cbdb87b0cbacff5ed993adb09a6999174   # existing; upstream HEAD 2026-09-24
PROPELLER_ABSL_VERSION=20260107.1      PROPELLER_ABSL_SHA256=<fill>
PROPELLER_PROTOBUF_VERSION=33.4        PROPELLER_PROTOBUF_SHA256=<fill>
PROPELLER_GTEST_VERSION=1.17.0         PROPELLER_GTEST_SHA256=<fill>
PROPELLER_QUIPPER_REV=f9eb05fcce80189c311a01341bb535a382d5d740   PROPELLER_QUIPPER_SHA256=<fill>
```
  (Versions are the ones `ddfb8b7`'s `CMake/{Absl,Protobuf,Googletest,Quipper}/*.cmake` reference. Re-read them on every propeller bump.)
- Stage 00 (Linux, `is_yes "$BUILD_PROPELLER"`): `fetch_pinned URL SHA256 DEST` (generalize `fetch_kernel`) for the four archives into `$CACHE_DIR/propeller-deps/`, using the URLs from those CMake files (abseil `…/archive/refs/tags/<v>.zip`, protobuf `…/releases/download/v<v>/protobuf-<v>.tar.gz`, googletest `…/archive/refs/tags/v<v>.zip`, quipper `google/perf_data_converter/archive/<rev>.tar.gz`).

- [ ] **Step 1:** Compute the sha256s once (`curl -fsSL <url> | sha256sum`) and fill `versions.env`.
- [ ] **Step 2:** Factor `fetch_kernel` into `fetch_pinned` (same cache, re-download-on-mismatch, die-on-mismatch logic). Keep `fetch_kernel` as a thin caller.
- [ ] **Step 3:** `./build.sh --only 00-sources` → four archives in `out/cache/propeller-deps/`, checksums verified. Run it again: no downloads.
- [ ] **Step 4: Commit** `git commit -m "build: pin and cache llvm-propeller third-party deps"`

---

### Task 4: Replace the Propeller patch series

**Files:** Rewrite `src/patches/llvm-propeller/0001-find-package-llvm.patch`; delete `0002-mccontext-asminfo-pointer.patch`; create `0002-quipper-libelf-to-llvm-object.patch`, `0003-offline-deps.patch`

**Interfaces:**
- `0001`: `CMake/LLVM/LLVM.cmake` becomes (spike version, E22):
```cmake
# elide-toolchain: link against an externally built LLVM via find_package(LLVM CONFIG).
if (NOT DEFINED LLVM_DIR)
  message(FATAL_ERROR "elide-toolchain: pass -DLLVM_DIR=<llvm build>/lib/cmake/llvm")
endif()
find_package(LLVM REQUIRED CONFIG)
message(STATUS "Propeller: using LLVM ${LLVM_PACKAGE_VERSION} from ${LLVM_DIR}")
set(LLVM_TARGETS_TO_BUILD X86 AArch64)
include_directories(SYSTEM ${LLVM_INCLUDE_DIRS})
if (DEFINED LLVM_MAIN_SRC_DIR)
  foreach (tgt ${LLVM_TARGETS_TO_BUILD})
    include_directories(SYSTEM ${LLVM_MAIN_SRC_DIR}/lib/Target/${tgt} ${LLVM_BINARY_DIR}/lib/Target/${tgt})
  endforeach()
endif()
separate_arguments(_llvm_defs NATIVE_COMMAND "${LLVM_DEFINITIONS}")
add_definitions(${_llvm_defs})
```
- `0002`: quipper is fetched at configure time, so patch the fetched tree, not the submodule. Propeller's `CMake/Quipper/Quipper.cmake` gains a `PATCH_COMMAND` (in its `CMakeLists.txt.in`) that applies `${PROPELLER_ELIDE_PATCHES}/quipper-dso-llvm-object.patch`. That patch rewrites quipper `src/quipper/dso.cc`'s build-id reader (`ReadElfBuildId*`, `dso.cc:25-128`: `elf_begin`/`gelf_getnote` on `.note.gnu.build-id`/`PT_NOTE`) on top of `llvm::object::ELFObjectFileBase` + `llvm::object::getBuildID` (`llvm/Object/BuildID.h`). Then drop `${LIBELF_LIBRARIES}` from `CMake/Quipper/CMakeLists.quipper.txt:64` and the `find_library(… elf …)` in the top-level `CMakeLists.txt:33`. Store the quipper patch as `src/patches/llvm-propeller/quipper/0001-dso-llvm-object.patch`; `0002` wires it in.
- `0003`: each `*_download_url` in `CMake/{Absl,Googletest,Quipper}/*.cmake` and the protobuf `FetchContent_Declare URL` become `file://${PROPELLER_DEPS_DIR}/<archive>` when `PROPELLER_DEPS_DIR` is set. Set `CMP0135 NEW`.

- [ ] **Step 1:** Scratch copy of the submodule (`cp -r llvm-propeller $S/p && rm -rf $S/p/.git $S/p/build`). Confirm the old patches fail in both directions (E-notes §2.4). `git rm` the old `0002`.
- [ ] **Step 2:** Write `0001` by editing the scratch copy and `diff -u`-ing (`git -C $S/p init -q && git -C $S/p add -A && git -C $S/p commit -qm base` before editing; `git -C $S/p diff > …`). Provenance header: `# local: elide-toolchain find_package(LLVM) integration (replaces download+build of LLVM db9b595)`.
- [ ] **Step 3:** Write the quipper patch against the quipper archive from Task 3 (extract to scratch). Unit-test the new build-id reader with quipper's own `dso_test.cc` if it builds with `BUILD_TESTING=ON`; otherwise with the stage-45 check (Task 5 Step 4) comparing against `llvm-readelf -n`.
- [ ] **Step 4:** Write `0003`.
- [ ] **Step 5:** `PATCHES_DIR=src/patches bash -c 'source scripts/lib/common.sh; ROOT_DIR=$PWD apply_patches llvm-propeller $S/p; apply_patches llvm-propeller $S/p'`: second run all `already applied`.
- [ ] **Step 6: Commit** `git commit -m "propeller: replace stale patches (find_package LLVM, libelf-free quipper, offline deps)"`

---

### Task 5: Stage 45 — build and ship `generate_propeller_profiles`

**Files:** Create `scripts/stages/45-propeller.sh`, `tests/stages/45-propeller.check.sh`

**Interfaces:**
- Consumes: stage-2 build tree `$BUILD_DIR/llvm-stage2` (static LLVM libs + `lib/cmake/llvm/LLVMConfig.cmake`), gnu sysroot `libz.a`, `libcrypto.a` (aws-lc), `libzstd.a`, cached deps.
- Produces: `$BUNDLE_DIR/bin/generate_propeller_profiles` (Linux). Consumed by T6, T8, T9, T15.

- [ ] **Step 1: Stage script**

```bash
# shellcheck shell=bash
# Stage 45: llvm-propeller's generate_propeller_profiles, linked against the stage-2 LLVM build
# tree (static libs) with the stage-1 gnu cfg compiler, so it meets the glibc floor. Linux only.

stage_applies() { [ "$HOST_OS" = linux ] && is_yes "$BUILD_PROPELLER"; }

stage_main() {
  local t s="$STAGE1_DIR/bin" b="$BUILD_DIR/propeller" sr launcher=()
  t="$(bundle_triple_for_libc gnu)"; sr="$(sysroot_of "$t")"
  [ -f "$BUILD_DIR/llvm-stage2/lib/cmake/llvm/LLVMConfig.cmake" ] || die "stage-2 build tree missing; run 40-llvm-stage2"
  [ -d "$CACHE_DIR/propeller-deps" ] || die "propeller deps missing; run 00-sources"
  apply_patches llvm-propeller "$ROOT_DIR/llvm-propeller"
  mapfile -t launcher < <(cmake_launcher_args)
  fresh_dir "$b"
  cmake -S "$ROOT_DIR/llvm-propeller" -B "$b" -G Ninja "${launcher[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$s/$t-clang" -DCMAKE_CXX_COMPILER="$s/$t-clang++" \
    -DCMAKE_AR="$s/llvm-ar" -DCMAKE_RANLIB="$s/llvm-ranlib" \
    -DCMAKE_CXX_FLAGS="$(arch_flags "$t")" \
    -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++ $sr/usr/lib/libzstd.a" \
    -DLLVM_DIR="$BUILD_DIR/llvm-stage2/lib/cmake/llvm" \
    -DPROPELLER_DEPS_DIR="$CACHE_DIR/propeller-deps" \
    -DPROPELLER_ELIDE_PATCHES="$ROOT_DIR/src/patches/llvm-propeller" \
    -DLIBZ_LIBRARIES="$sr/usr/lib/libz.a" -DLIBCRYPTO_LIBRARIES="$sr/usr/lib/libcrypto.a" \
    -DBUILD_TESTING=OFF
  cmake --build "$b" -j "$JOBS" --target generate_propeller_profiles
  install -m 0755 "$b/propeller/generate_propeller_profiles" "$BUNDLE_DIR/bin/"
}
```
(Spike note, E22: `-isystem <sysroot>/usr/include` in `CMAKE_CXX_FLAGS` breaks libc++'s header order. The cfg already supplies the sysroot, so don't add it.)

- [ ] **Step 2: Stage check** `tests/stages/45-propeller.check.sh`:

```bash
[ "$HOST_OS" = linux ] && is_yes "$BUILD_PROPELLER" || { echo "skip"; exit 0; }
g="$BUNDLE_DIR/bin/generate_propeller_profiles"
assert_file "$g"
assert_contains "$("$g" --helpfull 2>&1)" "--cc_profile" "propeller flags"
needed="$(needed_libs "$g" | xargs)"
assert_not_contains " $needed " " libelf" "no libelf"
assert_not_contains " $needed " " libstdc++" "no libstdc++"
assert_eq "$(glibc_floor_violations "$g")" "" "glibc floor"
```
- [ ] **Step 3:** `./build.sh --only 45-propeller && bash tests/stages/45-propeller.check.sh` → `0 failed`. Record build time in `docs/notes/build-timings.md`.
- [ ] **Step 4:** Build-id cross-check (validates the quipper rewrite): run the tool against the DeduBB fixture from Task 6 with a fake `perf.data`-free invocation (`--dedubb_profile` once T8 lands). Before that, run quipper's `dso_test` in the build tree with `-DBUILD_TESTING=ON` in a scratch configure.
- [ ] **Step 5: Offline proof:** `unshare -rn ./build.sh --only 45-propeller` (if user namespaces are allowed) succeeds.
- [ ] **Step 6:** Register the stage in packaging. 90-package copies `bin/` wholesale; confirm the binary is stripped there, and add it to the manifest's tool list (T16).
- [ ] **Step 7: Commit** `git commit -m "feat: stage 45 builds and ships generate_propeller_profiles"`

---

### Task 6: Propeller verification and downstream workflow

**Files:** Create `tests/fixtures/dedubb/a.c`, `tests/fixtures/dedubb/b.c`; modify `scripts/verify/checks.sh`

Fixtures (also used by DeduBB; validated in E24, where the tool emits `bbm`/`bbf` for BB 0 of both functions):

`tests/fixtures/dedubb/a.c`
```c
__attribute__((noinline)) long master_fn(const long *p) { return p[0] * 3 + p[1] * 5 + p[2]; }
```
`tests/fixtures/dedubb/b.c`
```c
#include <stdio.h>
long master_fn(const long *p);
__attribute__((noinline)) long fold_fn(const long *p) { return p[0] * 3 + p[1] * 5 + p[2]; }
int main(void) { long v[3] = {1, 2, 3}; printf("%ld\n", master_fn(v) + fold_fn(v)); return 0; }
```

- [ ] **Step 1: Checks**

```bash
# Propeller step-1 ("labelled") build of the fixture; extra args are appended.
labelled_build() { # ROOT TRIPLE OUT [extra...]
  local root="$1" t="$2" out="$3"; shift 3
  "$root/bin/$t-clang" -O2 -flto=thin -funique-internal-linkage-names -fbasic-block-address-map \
    -fuse-ld=lld -Wl,--lto-basic-block-address-map -Wl,-z,keep-text-section-prefix \
    "$ROOT_DIR/tests/fixtures/dedubb/a.c" "$ROOT_DIR/tests/fixtures/dedubb/b.c" -o "$out" "$@"
}

check_propeller_layout() {
  local root="$1" t="$2" tmp
  case "$t" in x86_64-unknown-linux-*) ;; *) return 0 ;; esac
  [ -x "$root/bin/generate_propeller_profiles" ] || return 0
  tmp="$(mktemp -d)"
  labelled_build "$root" "$t" "$tmp/app" $( [ "$(triple_libc "$t")" = musl ] && echo -static )
  if ! perf record -q -o "$tmp/perf.data" -e cycles:u -j any,u -- "$tmp/app" >/dev/null 2>&1; then
    warn "perf LBR unavailable; skipping propeller layout $t"; rm -rf "$tmp"; return
  fi
  if ! "$root/bin/generate_propeller_profiles" --binary="$tmp/app" --profile="$tmp/perf.data" \
       --cc_profile="$tmp/cc.txt" --ld_profile="$tmp/ld.txt" >"$tmp/log" 2>&1; then
    fail "propeller layout $t" "$(tail -3 "$tmp/log")"; rm -rf "$tmp"; return
  fi
  "$root/bin/$t-clang" -O2 -flto=thin -funique-internal-linkage-names -fuse-ld=lld \
    -Wl,--lto-basic-block-sections="$tmp/cc.txt" -Wl,--symbol-ordering-file="$tmp/ld.txt" \
    -Wl,--no-warn-symbol-ordering -Wl,-z,keep-text-section-prefix \
    "$ROOT_DIR/tests/fixtures/dedubb/a.c" "$ROOT_DIR/tests/fixtures/dedubb/b.c" -o "$tmp/app.opt" \
    $( [ "$(triple_libc "$t")" = musl ] && echo -static )
  [ "$("$tmp/app.opt")" = 32 ] && pass "propeller layout $t" || fail "propeller layout $t" "relinked binary wrong"
  rm -rf "$tmp"
}
```
`check_propeller_tool` lands with DeduBB in Task 9, because it needs the DeduBB flags. Wire `check_propeller_layout` into the triple loop.

- [ ] **Step 2:** Stage 95 on linux-amd64 CI. Expected: `ok propeller layout …`, or a skip warning on runners without LBR (spec open question 3). Record which in `docs/notes/build-timings.md`.
- [ ] **Step 3: Commit** `git commit -m "verify: Propeller layout profile round trip (LBR hosts)"`

---

## Phase C — DeduBB (compiler + Propeller)

### Task 7: Vendor `0100-dedubb-codegen.patch` (default on, inert gate) and the patch ledger

**Files:** Create `src/patches/llvm/0100-dedubb-codegen.patch`, `docs/notes/llvm-patches.md`

- [ ] **Step 1: Fetch**: clone `https://github.com/chaitanyaupp18/DeduBB` into a scratch dir, `checkout 07d730dab798a18440cd7b6ecca103794a86dfc2`, take `patches/llvm-project-dedubb.patch`.
- [ ] **Step 2: Scratch tree of touched files at 23.1.2**, `git init` + commit, `git apply` (expect clean, `X86InstrInfo.cpp` offset ~70).
- [ ] **Step 3: Gate** `llvm/lib/CodeGen/UnreachableBlockElim.cpp`:
```cpp
#include "llvm/CodeGen/DeduBBDirectives.h"
...
    if (!Reachable.count(&BB) &&
        !(BB.hasAddressTaken() && !DeduBBDirectives::get().empty())) {
```
- [ ] **Step 4: Regenerate** with header:
```
# requires: LLVM_DEDUBB
# upstream: https://github.com/chaitanyaupp18/DeduBB/blob/07d730dab798a18440cd7b6ecca103794a86dfc2/patches/llvm-project-dedubb.patch
#   base llvm/llvm-project@333edde4e80e (ancestor of llvmorg-23.1.2); Apache-2.0 WITH LLVM-exception
# local: rebased to llvmorg-23.1.2; UnreachableBlockElim change gated on non-empty -dedubb-directives
```
- [ ] **Step 5: Validate on a scratch `llc`** (~15 min, 32 cores): scratch copy of `llvm/llvm` + `cmake` + `third-party` + `libc`, apply, build `llc FileCheck not split-file` (X86;AArch64, tests off), run the 6 `dedubb*.ll` RUN lines plus the 40 `blockaddress`/BB-map X86 tests with a minimal RUN-line runner. Expected 6/6 and 40/40 (reproduces E9 with the gate).
- [ ] **Step 6: Bundle build** (Linux + darwin CI): `clang -mllvm -dedubb-directives=/dev/null -c hello.c` is accepted.
- [ ] **Step 7: Ledger** `docs/notes/llvm-patches.md`: one row per patch (origin, files, why, default, how to drop), plus the bump procedure from `docs/notes/llvm-backports-issue.md` §"Tracking".
- [ ] **Step 8: Commit** `git commit -m "llvm: vendor DeduBB CodeGen+lld patch (07d730d), default on, inert without directives"`

---

### Task 8: `0004-dedubb.patch` for Propeller

**Files:** Create `src/patches/llvm-propeller/0004-dedubb.patch`

- [ ] **Step 1:** On a scratch propeller tree with `0001`–`0003` applied, `git apply --reject` DeduBB `07d730d`'s `patches/llvm-propeller-dedubb.patch`. Expected rejects (E23): `generate_propeller_profiles.cc` hunk 2 and `mini_disassembler.cc` hunk 2.
- [ ] **Step 2: Resolve** exactly as in the spike (spec §4.2):
  - `generate_propeller_profiles.cc`: add `absl/log/log.h`, `absl/strings/str_cat.h`, `absl/strings/string_view.h` after `absl/log/check.h`, and `propeller/tail_call_profile_writer.h` after `propeller_options.pb.h`.
  - `mini_disassembler.cc`: insert before `MayAffectControlFlow`:
    ```cpp
    absl::StatusOr<llvm::MCInst> MiniDisassembler::DisassembleOne(
        llvm::ArrayRef<uint8_t> bytes, uint64_t binary_address, uint64_t& size) {
      llvm::MCInst inst;
      if (!disasm_->getInstruction(inst, size, bytes, binary_address, llvm::nulls())) {
        return absl::FailedPreconditionError(
            llvm::formatv("getInstruction failed at binary address {0:x}", binary_address).str());
      }
      return inst;
    }
    ```
  - Revert hunk 1's `MCContext(triple, *asm_info_, mri_.get(), sti_.get())` to the 23.x reference form `MCContext(triple, *asm_info_, *mri_, *sti_)`.
- [ ] **Step 3:** Regenerate with header `# upstream: https://github.com/chaitanyaupp18/DeduBB/blob/07d730dab798…/patches/llvm-propeller-dedubb.patch (base google/llvm-propeller@e2c7049); Apache-2.0` / `# local: rebased to ddfb8b7; MCContext reference API (LLVM 23)`.
- [ ] **Step 4:** `./build.sh --only 45-propeller`; `generate_propeller_profiles --helpfull | grep dedubb_profile`.
- [ ] **Step 5: Commit** `git commit -m "propeller: DeduBB directive generation (rebased onto ddfb8b7 / LLVM 23)"`

---

### Task 9: DeduBB verification

**Files:** Modify `scripts/verify/checks.sh`

- [ ] **Step 1: Checks**

```bash
check_propeller_tool() {   # DeduBB directives from the shipped tool (no profile needed)
  local root="$1" t="$2" tmp
  [ "$(triple_os "$t")" = linux ] && [ -x "$root/bin/generate_propeller_profiles" ] || return 0
  tmp="$(mktemp -d)"
  labelled_build "$root" "$t" "$tmp/app" $( [ "$(triple_libc "$t")" = musl ] && echo -static ) || { fail "propeller tool $t" "labelled build"; rm -rf "$tmp"; return; }
  "$root/bin/generate_propeller_profiles" --binary="$tmp/app" --dedubb_profile="$tmp/d.txt" >/dev/null 2>&1
  if grep -q '^bbm 0 (DeduBB.master.' "$tmp/d.txt" && grep -q '^bbf 0 (DeduBB.master.' "$tmp/d.txt"; then
    pass "propeller tool $t"; else fail "propeller tool $t" "no bbm/bbf directives"; fi
  rm -rf "$tmp"
}

check_dedubb_codegen() {   # generate -> relink -> fold_fn branches to the master
  local root="$1" t="$2" tmp st=() dis
  [ "$(triple_os "$t")" = linux ] && is_yes "${LLVM_DEDUBB:-yes}" && [ -x "$root/bin/generate_propeller_profiles" ] || return 0
  [ "$(triple_libc "$t")" = musl ] && st=(-static)
  tmp="$(mktemp -d)"
  labelled_build "$root" "$t" "$tmp/app" "${st[@]}"
  "$root/bin/generate_propeller_profiles" --binary="$tmp/app" --dedubb_profile="$tmp/d.txt" >/dev/null 2>&1
  if ! labelled_build "$root" "$t" "$tmp/app.dd" "${st[@]}" -Wl,-mllvm,-dedubb-directives="$tmp/d.txt" 2>"$tmp/err"; then
    fail "dedubb codegen $t" "$(head -3 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  dis="$("$root/bin/llvm-objdump" -d --no-show-raw-insn "$tmp/app.dd")"
  if ! awk '/<fold_fn>:/{f=1;next} f&&/^$/{exit} f' <<< "$dis" | grep -Eq '(jmp|b)[[:space:]].*<DeduBB\.master\.[0-9]+>' &&
     ! awk '/<master_fn>:/{f=1;next} f&&/^$/{exit} f' <<< "$dis" | grep -Eq '(jmp|b)[[:space:]].*<DeduBB\.master\.[0-9]+>'; then
    fail "dedubb codegen $t" "no fold to a DeduBB master"; rm -rf "$tmp"; return
  fi
  [ "$("$tmp/app.dd")" = 32 ] && pass "dedubb codegen $t" || fail "dedubb codegen $t" "wrong output"
  rm -rf "$tmp"
}

check_dedubb_inert() {
  local root="$1" t="$2" tmp
  [ "$t" = x86_64-unknown-linux-gnu ] || return 0
  tmp="$(mktemp -d)"
  labelled_build "$root" "$t" "$tmp/a1" && labelled_build "$root" "$t" "$tmp/a2"
  if ! cmp -s "$tmp/a1" "$tmp/a2" || "$root/bin/llvm-nm" "$tmp/a1" | grep -q 'DeduBB\.'; then
    fail "dedubb inert $t" "non-deterministic or DeduBB symbols without directives"; else pass "dedubb inert $t"; fi
  rm -rf "$tmp"
}
```
(Which of the two identical functions becomes the master is the tool's choice; the check accepts either direction.)
- [ ] **Step 2:** Stage 95 on both Linux hosts → `ok propeller tool`, `ok dedubb codegen` ×4 (aarch64 via Tail Call), `ok dedubb inert`.
- [ ] **Step 3: Commit** `git commit -m "verify: DeduBB via generate_propeller_profiles and patched codegen"`

---

## Phase D — mimalloc shim and MemProf

### Task 10: MemProf backports + issue draft

**Files:** Create `src/patches/llvm/0001-memprof-deterministic-clone-tiebreak.patch`, `0002-memprof-histogram-tail-granule.patch`; update `docs/notes/llvm-patches.md`

- [ ] **Step 1: Fetch with provenance**
```bash
for pr in 222126:0001-memprof-deterministic-clone-tiebreak 208911:0002-memprof-histogram-tail-granule; do
  n=${pr%%:*}; f=src/patches/llvm/${pr#*:}.patch
  sha=$(gh pr view "$n" --repo llvm/llvm-project --json mergeCommit --jq .mergeCommit.oid)
  { echo "# upstream: https://github.com/llvm/llvm-project/pull/$n ($sha)"; echo "# local: none"; \
    gh pr diff "$n" --repo llvm/llvm-project; } > "$f"
done
```
- [ ] **Step 2:** Scratch-copy apply / re-apply / unapply (as in Task 1), confirming no hunk overlap with `0100` (`0100` doesn't touch `MemProfContextDisambiguation.cpp` or `memprof_allocator.cpp`).
- [ ] **Step 3:** Ledger rows. The maintainer files `docs/notes/llvm-backports-issue.md` as a GitHub issue on elide-dev/toolchain (do **not** run `gh issue create`). Link the issue number in the ledger once it exists.
- [ ] **Step 4: Commit** `git commit -m "llvm: backport MemProf deterministic cloning (#222126) and histogram fix (#208911)"`

---

### Task 11: compiler-rt memprof runtime (x86_64 gnu)

**Files:** Modify `scripts/lib/platform.sh`, `scripts/stages/30-runtimes.sh`, `tests/unit/platform.test.sh`, `tests/stages/30-runtimes.check.sh`

- [ ] **Step 1: Test** `assert_ok memprof_supported x86_64-unknown-linux-gnu`; `assert_fails` for musl, aarch64 gnu, darwin.
- [ ] **Step 2:** `memprof_supported() { [ "$1" = x86_64-unknown-linux-gnu ]; }` (comment cites `AllSupportedArchDefs.cmake:96`, `config-ix.cmake:842`, `memprof_rtl.cpp:181`).
- [ ] **Step 3: Stage 30**: `runtimes_common_args` takes `memprof` (default `OFF`) instead of hard-coding it. In `build_cxx_runtimes`:
```bash
  local memprof=OFF memprof_args=()
  if memprof_supported "$t"; then
    memprof=ON
    memprof_args=(-DSANITIZER_CXX_ABI=none
      "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld -rtlib=compiler-rt -unwindlib=none")
  fi
  mapfile -t args < <(runtimes_common_args "$t" "$memprof")
  cmake -S "$ROOT_DIR/llvm/runtimes" -B "$b" "${args[@]}" "${memprof_args[@]}" \
```
- [ ] **Step 4: Stage check**: for `memprof_supported` triples assert `libclang_rt.memprof.a`, `memprof_cxx.a`, `memprof-preinit.a`, `memprof.so`; for the others assert no `memprof` files.
- [ ] **Step 5:** `./build.sh --only 30-runtimes && bash tests/stages/30-runtimes.check.sh`; `llvm-readelf -V …/libclang_rt.memprof.so` max `GLIBC_2.34` (E20).
- [ ] **Step 6: Commit** `git commit -m "feat(runtimes): compiler-rt memprof for x86_64-unknown-linux-gnu"`

---

### Task 12: `libmimalloc-shim` component

**Files:** Create `src/mimalloc-shim/core.cc`, `hotcold.cc`, `mimalloc-shim.h`, `mimalloc-shim.pc.in`, `abi-v1.symbols`; modify `scripts/stages/35-mimalloc.sh`, `tests/stages/35-mimalloc.check.sh`

**Interfaces (spec §5.3, frozen as v1):** `mimalloc-shim.h`:
```c
#ifndef MIMALLOC_SHIM_H
#define MIMALLOC_SHIM_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define MISHIM_ABI_VERSION 1
typedef enum { MISHIM_DEFAULT = 0, MISHIM_HOT = 1, MISHIM_COLD = 2 } mishim_temp;
typedef struct { size_t cold_arena_mb, hot_arena_mb; int hot_large_pages;
                 unsigned cold_max, hot_min; int disable; } mishim_config;
typedef struct { size_t allocs[3], bytes[3], fallbacks; } mishim_stats;
int         mishim_abi_version(void);
int         mishim_configure(const mishim_config *c);   /* 0 ok, -1 if partitions already exist */
void       *mishim_malloc(size_t size, mishim_temp t, size_t token_class);
void       *mishim_aligned_alloc(size_t align, size_t size, mishim_temp t, size_t token_class);
mishim_temp mishim_partition_of(const void *p, size_t *token_class_out);
void        mishim_get_stats(mishim_stats *out);
#ifdef __cplusplus
}
#endif
#endif
```
`abi-v1.symbols` (sorted, checked by the stage test against `llvm-nm --defined-only -g`):
```
_ZnamRKSt9nothrow_t12__hot_cold_t
_ZnamSt11align_val_t12__hot_cold_t
_ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t
_Znam12__hot_cold_t
_ZnwmRKSt9nothrow_t12__hot_cold_t
_ZnwmSt11align_val_t12__hot_cold_t
_ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t
_Znwm12__hot_cold_t
mishim_abi_version
mishim_aligned_alloc
mishim_configure
mishim_get_stats
mishim_malloc
mishim_partition_of
```
(Sort with `LC_ALL=C sort` when generating; the list above is illustrative.)

- [ ] **Step 1: `core.cc`**. Partition table and policy (build modes: default = real; `-DMISHIM_FORWARD` = everything to the default allocator):

```cpp
// libmimalloc-shim core: partitions (token_class x temperature) on mimalloc first-class heaps.
#include <atomic>
#include <cerrno>
#include <cstdlib>
#include "mimalloc-shim.h"
#if !defined(MISHIM_FORWARD)
#include <mimalloc.h>
#endif

namespace mishim {
constexpr size_t kMaxClasses = 16;
struct Partition { std::atomic<mi_heap_t*> heap{nullptr}; std::atomic<mi_arena_id_t> arena{nullptr}; };
#if !defined(MISHIM_FORWARD)
static Partition g_part[kMaxClasses][3];
#endif
static std::atomic<int> g_frozen{0};      // set once any partition exists
static mishim_config g_cfg = {256, 256, 0, 63, 240, 0};
static std::atomic<size_t> g_allocs[3], g_bytes[3], g_fallbacks;
static std::atomic<int> g_env_read{0};

static void read_env_once() {
  if (g_env_read.exchange(1)) return;
  auto num = [](const char* n, size_t d) { const char* e = getenv(n); return e ? (size_t)strtoul(e, nullptr, 10) : d; };
  g_cfg.cold_arena_mb   = num("MISHIM_COLD_ARENA_MB", g_cfg.cold_arena_mb);
  g_cfg.hot_arena_mb    = num("MISHIM_HOT_ARENA_MB", g_cfg.hot_arena_mb);
  g_cfg.hot_large_pages = (int)num("MISHIM_HOT_LARGE_PAGES", g_cfg.hot_large_pages);
  g_cfg.cold_max        = (unsigned)num("MISHIM_COLD_MAX", g_cfg.cold_max);
  g_cfg.hot_min         = (unsigned)num("MISHIM_HOT_MIN", g_cfg.hot_min);
  g_cfg.disable         = (int)num("MISHIM_DISABLE", g_cfg.disable);
  if (num("MISHIM_STATS", 0)) atexit([] { /* print g_allocs/g_bytes/g_fallbacks to stderr */ });
}

mishim_temp temp_of_hint(unsigned hint) {
  read_env_once();
  if (g_cfg.disable) return MISHIM_DEFAULT;
  if (hint <= g_cfg.cold_max) return MISHIM_COLD;
  if (hint >= g_cfg.hot_min) return MISHIM_HOT;
  return MISHIM_DEFAULT;
}

#if !defined(MISHIM_FORWARD)
static mi_heap_t* heap_for(mishim_temp t, size_t cls) {
  if (t == MISHIM_DEFAULT && cls == 0) return nullptr;           // main heap: plain mi_malloc path
  Partition& p = g_part[cls % kMaxClasses][t];
  if (mi_heap_t* h = p.heap.load(std::memory_order_acquire)) return h;
  size_t mb = t == MISHIM_HOT ? g_cfg.hot_arena_mb : g_cfg.cold_arena_mb;
  mi_arena_id_t id = nullptr; mi_heap_t* h = nullptr;
  if (mb && mi_reserve_os_memory_ex(mb << 20, false, t == MISHIM_HOT && g_cfg.hot_large_pages, true, &id) == 0)
    h = mi_heap_new_in_arena(id);
  if (!h) { id = nullptr; h = mi_heap_new(); }
  mi_heap_t* expected = nullptr;
  if (!p.heap.compare_exchange_strong(expected, h, std::memory_order_acq_rel)) { mi_heap_delete(h); return expected; }
  p.arena.store(id, std::memory_order_release);
  g_frozen.store(1, std::memory_order_release);
  return h;
}
#endif

// Returns nullptr on failure; callers apply C or C++ OOM semantics.
void* alloc(size_t n, size_t align, mishim_temp t, size_t cls) {
#if !defined(MISHIM_FORWARD)
  if (mi_heap_t* h = heap_for(t, cls)) {
    void* q = align ? mi_heap_malloc_aligned(h, n, align) : mi_heap_malloc(h, n);
    if (q) { g_allocs[t].fetch_add(1, std::memory_order_relaxed); g_bytes[t].fetch_add(n, std::memory_order_relaxed); return q; }
    g_fallbacks.fetch_add(1, std::memory_order_relaxed);         // arena full: fall back to default
  }
  return align ? mi_malloc_aligned(n, align) : mi_malloc(n);
#else
  (void)t; (void)cls;
  return align ? aligned_alloc(align, (n + align - 1) / align * align) : malloc(n);
#endif
}
}  // namespace mishim

extern "C" {
int mishim_abi_version(void) { return MISHIM_ABI_VERSION; }
int mishim_configure(const mishim_config* c) {
  if (mishim::g_frozen.load(std::memory_order_acquire)) return -1;
  mishim::g_env_read.store(1); mishim::g_cfg = *c; return 0;
}
void* mishim_malloc(size_t n, mishim_temp t, size_t cls) {
  void* p = mishim::alloc(n, 0, t, cls); if (!p) errno = ENOMEM; return p;
}
void* mishim_aligned_alloc(size_t a, size_t n, mishim_temp t, size_t cls) {
  void* p = mishim::alloc(n, a, t, cls); if (!p) errno = ENOMEM; return p;
}
mishim_temp mishim_partition_of(const void* p, size_t* cls_out) {
#if !defined(MISHIM_FORWARD)
  for (size_t c = 0; c < mishim::kMaxClasses; c++)
    for (int t = 1; t < 3; t++) {
      mi_arena_id_t id = mishim::g_part[c][t].arena.load(std::memory_order_acquire);
      if (id && mi_arena_contains(id, p)) { if (cls_out) *cls_out = c; return (mishim_temp)t; }
    }
#endif
  if (cls_out) *cls_out = 0;
  (void)p; return MISHIM_DEFAULT;
}
void mishim_get_stats(mishim_stats* o) {
  for (int i = 0; i < 3; i++) { o->allocs[i] = mishim::g_allocs[i]; o->bytes[i] = mishim::g_bytes[i]; }
  o->fallbacks = mishim::g_fallbacks;
}
}
```
(`mi_malloc` is mimalloc's normal allocation. On gnu with `MI_OVERRIDE=ON` and on musl-with-mimalloc it is the same allocator as `malloc`. The `(c, DEFAULT)` main-heap case returns `nullptr` from `heap_for` on purpose.)

- [ ] **Step 2: `hotcold.cc`**. The 8 overloads, each: `t = temp_of_hint((uint8_t)h)`; `p = alloc(n, align, t, 0)`. On `nullptr`: nothrow variants return `nullptr`; throwing variants loop on `std::get_new_handler()` and then `throw std::bad_alloc()`. Declare `enum class __hot_cold_t : uint8_t {};` at global scope. Export only through these definitions: hide `mishim::*` internals with `-fvisibility=hidden` and `__attribute__((visibility("default")))` on the public symbols.

- [ ] **Step 3: Stage 35**: add `build_mimalloc_shim "$t"` at the end of each triple's iteration:

```bash
build_mimalloc_shim() {
  local t="$1" prefix b mode=() f
  prefix="$(target_prefix "$t")"; b="$(component_build_dir mimalloc-shim "$t")"; fresh_dir "$b"
  case "$(triple_libc "$t")" in
    musl) is_yes "$MUSL_USE_MIMALLOC" || mode=(-DMISHIM_FORWARD) ;;
    darwin) mode=(-DMISHIM_FORWARD) ;;
  esac
  for f in core hotcold; do
    # shellcheck disable=SC2046
    "$TOOLCHAIN_ROOT/bin/$t-clang++" -c -O2 -fPIC -std=c++17 -fvisibility=hidden \
      -flto=thin -ffat-lto-objects $(arch_flags "$t") "${mode[@]}" \
      -I"$prefix/include" -I"$ROOT_DIR/src/mimalloc-shim" \
      "$ROOT_DIR/src/mimalloc-shim/$f.cc" -o "$b/$f.o"
  done
  rm -f "$prefix/lib/libmimalloc-shim.a"
  "$TOOLCHAIN_ROOT/bin/llvm-ar" rcs "$prefix/lib/libmimalloc-shim.a" "$b/core.o" "$b/hotcold.o"
  cp "$ROOT_DIR/src/mimalloc-shim/mimalloc-shim.h" "$prefix/include/"
  mkdir -p "$prefix/lib/pkgconfig"
  sed "s|@LIBS@|-lmimalloc-shim$( [ "$(triple_libc "$t")" = gnu ] && echo ' -lmimalloc')|" \
    "$ROOT_DIR/src/mimalloc-shim/mimalloc-shim.pc.in" > "$prefix/lib/pkgconfig/mimalloc-shim.pc"
}
```
`mimalloc-shim.pc.in`: `prefix=/usr`, `Name: mimalloc-shim`, `Libs: -L${prefix}/lib @LIBS@`, `Cflags: -I${prefix}/include` (relocated by `relocate_prefix` like other `.pc` files).

- [ ] **Step 4: Stage check** (`35-mimalloc.check.sh`, per triple): archive and header exist; `llvm-nm --defined-only -g` symbol set equals `abi-v1.symbols` (Review Focus 5); musl sysroot has **no** `libmimalloc.a` (single-instance rule, spec §5.5).
- [ ] **Step 5: Commit** `git commit -m "feat: libmimalloc-shim, hot/cold/default heap partitions on mimalloc (v1 ABI)"`

---

### Task 13: Shim tests and verification

**Files:** Create `tests/fixtures/mimalloc-shim-test.cc`; modify `tests/stages/35-mimalloc.check.sh`, `scripts/verify/checks.sh`

- [ ] **Step 1: Test program** (exit 0 = pass; prints the failing assertion). Build with `-DEXPECT_FORWARD` for forward mode:
  - `operator new(64, (__hot_cold_t)1)` → `MISHIM_COLD`; `(…)254` → `MISHIM_HOT`; `(…)128` and `(…)222` → `MISHIM_DEFAULT` (forward mode: all `DEFAULT`)
  - all 8 overloads callable; aligned variants return `align`-aligned pointers (`align_val_t{256}`)
  - nothrow with `SIZE_MAX/2` returns `nullptr`; the throwing variant throws `std::bad_alloc`
  - `std::thread`: allocate cold in thread A, `delete` in thread B, then allocate cold in B
  - `mishim_get_stats` counts the hot and cold allocations made
  - `mishim_configure` returns -1 after the first partition exists
  - `mishim_malloc(32, MISHIM_COLD, 0)` → `COLD`; `free()` works on it
  - (separate process) `MISHIM_DISABLE=1` → everything `DEFAULT`
- [ ] **Step 2: Stage-35 check**: compile with stage-1 `<t>-clang++` (`-static` musl; `-lmimalloc-shim -lmimalloc` gnu) and run on the host (darwin: in its CI job).
- [ ] **Step 3: `check_mimalloc_shim ROOT TRIPLE`** in `checks.sh`: same against the packaged bundle, run from `pkg-config --libs mimalloc-shim` with `PKG_CONFIG_SYSROOT_DIR`/`LIBDIR` from `elide-toolchain env` (proves the `.pc` file).
- [ ] **Step 4: Commit** `git commit -m "verify: libmimalloc-shim partitions, OOM, threads, config, forward mode"`

---

### Task 14: MemProf verification

**Files:** Create `tests/fixtures/memprof.cc`, `memprof-ctx.cc`, `memprof-ctx.yaml`; modify `scripts/verify/checks.sh`

- [ ] **Step 1: Fixtures.** `memprof-ctx.cc` (line numbers are load-bearing for the YAML):
```cpp
#include <cstddef>
__attribute__((noinline)) char *alloc(size_t n) {
  return new char[n];
}
__attribute__((noinline)) char *viaHot(size_t n) {
  return alloc(n);
}
__attribute__((noinline)) char *viaCold(size_t n) {
  return alloc(n);
}
#include "mimalloc-shim.h"
int main() {
  char *a = viaHot(10);
  char *b = viaCold(10);
  int rc = mishim_partition_of(a, nullptr) == MISHIM_DEFAULT ? 0 : 2;
#ifndef EXPECT_FORWARD
  rc |= mishim_partition_of(b, nullptr) == MISHIM_COLD ? 0 : 4;
#endif
  delete[] a; delete[] b;
  return rc;
}
```
`memprof-ctx.yaml`: E3's profile. Two `AllocSites` under `_Z5allocm` at `LineOffset: 1, Column: 10`. Cold: through `_Z7viaColdm` (`1,10`) and `main` (`LineOffset: 2, Column: 13`), `TotalSize 400, AllocCount 1, TotalLifetimeAccessDensity 1, TotalLifetime 1000000`. Notcold: through `_Z6viaHotm` and `main` (`1,13`), `TotalLifetimeAccessDensity 100000, TotalLifetime 1`. Plus `CallSites` for `_Z6viaHotm`, `_Z7viaColdm`, `main`. (`main` is on line 12, so its offsets stay 1 and 2; the notcold hint 128 maps to `DEFAULT` under spec D10.) `memprof.cc`: E10's loop program.
- [ ] **Step 2: Checks** `check_memprof_runtime` (x86_64 gnu: instrument → run → `merge --profiled-binary` → ≥ 2 contexts), `check_memprof_use` (all triples: YAML → match remark → link with `-Wl,-mllvm,-enable-memprof-context-disambiguation -Wl,-mllvm,-optimize-hot-cold-new -Wl,-mllvm,-supports-hot-cold-new $(pkg-config --libs mimalloc-shim)` (+ `-static` musl) → `_Z5allocm.memprof.1` and `_Znam12__hot_cold_t` present → run, exit 0; darwin link + nm only, `-DEXPECT_FORWARD`), `check_memprof_strip` (without `-supports-hot-cold-new`: no `hot_cold` symbol), `check_memprof_absent`. Function bodies follow the previous revision of this plan (git history of this file) with `-lmimalloc-hotcold` replaced by the `.pc` libs.
- [ ] **Step 3:** Stage 95 on all hosts → all `ok`.
- [ ] **Step 4: Commit** `git commit -m "verify: MemProf runtime, profile use through libmimalloc-shim, hint stripping"`

---

## Phase E — Contract and release

### Task 15: Helper `elide-toolchain flags`

**Files:** Modify `src/elide-toolchain`, `tests/unit/helper.test.sh`

**Interface:** `elide-toolchain flags --target T MODE [--format sh|github|json]` emits `ELIDE_CFLAGS`, `ELIDE_LDFLAGS`, `ELIDE_RUSTFLAGS` via the existing `add`/`emit`. Modes and exact flags (spec §3.5, §4.3, §6.2):

| Mode | CFLAGS | LDFLAGS (RUSTFLAGS = `-Clinker-plugin-lto` + each LDFLAG as `-Clink-arg=`) |
|---|---|---|
| `propeller-baseline` | `-flto=thin -funique-internal-linkage-names -fbasic-block-address-map` | `-flto=thin -fuse-ld=lld -Wl,--lto-basic-block-address-map -Wl,-z,keep-text-section-prefix` |
| `propeller-use=CC,LD` | `-flto=thin -funique-internal-linkage-names` | `-flto=thin -fuse-ld=lld -Wl,--lto-basic-block-sections=CC -Wl,--symbol-ordering-file=LD -Wl,--no-warn-symbol-ordering -Wl,-z,keep-text-section-prefix` |
| `dedubb-apply=F` (combinable: `propeller-use=…+dedubb-apply=…`) | baseline CFLAGS | baseline LDFLAGS + `-Wl,-mllvm,-dedubb-directives=F` |
| `memprof-instrument` | `-fmemory-profile -gmlt -fdebug-info-for-profiling -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -fno-optimize-sibling-calls -fno-pie` | `-fmemory-profile -no-pie -Wl,-z,noseparate-code -Wl,--build-id` (Rust: `-Cpasses=memprof-module,function(memprof)`, experimental) |
| `memprof-use=F` | `-flto=thin -gmlt -fdebug-info-for-profiling -fmemory-profile-use=F` | `-flto=thin -fuse-ld=lld -Wl,-mllvm,-enable-memprof-context-disambiguation -Wl,-mllvm,-optimize-hot-cold-new -Wl,-mllvm,-supports-hot-cold-new -lmimalloc-shim` (+ `-lmimalloc` on gnu) |

Errors: `memprof-instrument` off `x86_64-unknown-linux-gnu` (message tells the user to collect there and use anywhere); `propeller-*`/`dedubb-*` on darwin.

- [ ] Steps: tests first (each mode's key flags, the error cases, combined mode), implement in POSIX sh, `tests/run.sh helper`, shellcheck `-s sh`, commit `feat(helper): 'flags' prints Propeller, DeduBB and MemProf consumer flags`.

---

### Task 16: Manifest features

**Files:** Modify `scripts/gen-manifest.py`, `tests/unit/manifest.test.sh`, `check_manifest`

```json
"features": {
  "propeller": { "tool": "bin/generate_propeller_profiles", "rev": "ddfb8b7cbdb8", "profileTypes": ["PERF_LBR", "PERF_SPE"] },
  "dedubb":    { "codegen": true, "source": "chaitanyaupp18/DeduBB@07d730d" },
  "memprof":   { "runtimeTargets": ["x86_64-unknown-linux-gnu"],
                 "backports": ["llvm/llvm-project#222126", "llvm/llvm-project#208911"] },
  "mimallocShim": { "lib": "libmimalloc-shim.a", "abi": 1, "hotColdNew": true, "allocToken": false }
}
```
darwin: `propeller`/`dedubb` absent, `runtimeTargets: []`, shim present (forward mode, `"mode": "forward"`). Steps: test, implement, run, commit `feat(manifest): advertise Propeller, DeduBB, MemProf and shim features`.

---

### Task 17: README, full build, consumer trial

- [ ] **Step 1: README** sections: "Propeller", "DeduBB", "mimalloc shim", "MemProf". Cover the support matrix (spec §1.2), `elide-toolchain flags` modes, the workflows (spec §3.5, §4.3, §6.2), pipeline ordering (spec §7), and the caveats (LBR/SPE requirement; content-hash profile and directive names because of caches; never profile DeduBB/relinked binaries; hints need ThinLTO + the shim; gnu needs `-lmimalloc`; musl static only; GraalVM limits). Update the base spec's bundle layout (§2) with `bin/generate_propeller_profiles`, `libmimalloc-shim.a`, `mimalloc-shim.h`, and stage 45 in the stage table.
- [ ] **Step 2: Full CI build** (three hosts) green with all new checks.
- [ ] **Step 3: Consumer trial** (gate before release): one real consumer (WHIPLASH C++ or Komodo) through Propeller+DeduBB and MemProf+shim. Record `.text` delta, a benchmark A/B (`MISHIM_DISABLE=1`), and an exception/unwind smoke test through folded code in `docs/notes/propeller-dedubb-memprof-trial.md`.
- [ ] **Step 4: Commit** `git commit -m "docs: Propeller, DeduBB, mimalloc shim and MemProf usage"`

---

## Follow-ups (not in this plan)

- `libmimalloc-shim` v2: `token.o`/`token_fast.o` members implementing `__alloc_token_*` (spec §5.4), with an alloc-token verification check.
- aarch64 Propeller profiling via ARM SPE (`--profile_type=PERF_SPE`) on a host that has it.
- Optional experimental `bolt-dedubb` patch (spec §4.5).
- aarch64/darwin MemProf runtime (upstream work).
