# Propeller, DeduBB, elidealloc shim and MemProf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Revive llvm-propeller as a shipped tool, ship DeduBB on top of it (compiler + Propeller path), add `libelidealloc-shim` as a first-class, allocator-agnostic allocator component (mimalloc backend #1) (MemProf hot/cold now, allocation tokens later), and ship MemProf (runtime + backports) in the elide-toolchain LLVM 23.1.2 bundles, with verification and a documented downstream flag contract.

**Architecture:** LLVM changes are `src/patches/llvm/NNNN-*.patch`, applied to the `llvm` submodule by `apply_patches` in stages 10/30/40. Stage 00 un-applies them before its clean-tree check. A new Linux-only stage `45-propeller` builds `generate_propeller_profiles` against the stage-2 LLVM build tree, using offline-cached deps and its own patch series (find_package LLVM, libelf→LLVM Object, offline deps, DeduBB). Stage 30 adds the compiler-rt memprof runtime for `x86_64-unknown-linux-gnu`. Stage 35 adds `libelidealloc-shim.a` to every sysroot. The helper gains `flags`. Stage 95 gains Propeller, DeduBB, shim and MemProf checks.

**Tech Stack:** bash, POSIX sh (helper), CMake + Ninja, LLVM 23.1.2, llvm-propeller (`ddfb8b7`), abseil/protobuf/googletest/quipper, compiler-rt, mimalloc 3.5.4, C++17/20, Python 3 (manifest).

**Spec:** `docs/superpowers/specs/2026-10-05-memprof-dedubb-design.md` (§N below). Evidence: `docs/notes/memprof-dedubb-research.md` (EN = experiment N). LLVM patch tracking: [elide-dev/toolchain#4](https://github.com/elide-dev/toolchain/issues/4) (source text `docs/notes/llvm-backports-issue.md`).

## Global Constraints

- Everything in the base plan's Global Constraints holds (glibc floor 2.34, macOS min 12.0, relocatable bundle, no `sudo`, writes only under `out/` and `dist/`, bash ≥ 4 for build scripts, POSIX sh for the helper).
- LLVM stays at `llvmorg-23.1.2`. Submodules are never edited by hand: every change is a patch in `src/patches/<component>/`, and patches never overlap hunks (spec D2).
- No network after stage 00. Propeller's third-party archives are pinned by sha256 in `versions.env` and cached in `out/cache/propeller-deps/`.
- DeduBB is applied by default and must be inert without `-dedubb-directives` (`check_dedubb_inert`).
- The bundle never enables `-supports-hot-cold-new` or `-fsanitize=alloc-token` on its own.
- `libelidealloc-shim` v1 symbols and semantics are frozen once released (spec §5.4).
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
src/elidealloc-shim/{core.cc,hotcold.cc,backend.h,backend-mimalloc.cc,backend-forward.cc,elidealloc-shim.h,elidealloc-shim.pc.in,abi-v1.symbols}   # NEW (T12)
tests/unit/{common,platform,helper,manifest}.test.sh                # MODIFY
tests/stages/{30-runtimes,35-mimalloc,40-llvm-stage2}.check.sh      # MODIFY
tests/stages/45-propeller.check.sh                                  # NEW (T5)
tests/fixtures/dedubb/{a.c,b.c}                                     # NEW (T6)
tests/fixtures/elidealloc-shim-test.cc                                # NEW (T13)
tests/fixtures/{memprof.cc,memprof-ctx.cc,memprof-ctx.yaml}          # NEW (T14)
docs/notes/llvm-patches.md                                          # NEW (T7) patch ledger + bump procedure
docs/notes/llvm-backports-issue.md                                  # EXISTS (source text of elide-dev/toolchain#4)
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

### Task 6: Propeller verification without branch sampling (fixtures + probed live check)

**Files:** Create `tests/fixtures/dedubb/a.c`, `tests/fixtures/dedubb/b.c`, `docs/notes/propeller-fixtures.md`; modify `scripts/verify/checks.sh`, `vars.sh` (`REQUIRE_LBR=${REQUIRE_LBR:-no}`)

CI runners cannot branch-sample (spec §3.3a), so the round trip uses upstream's checked-in perf data from the pinned submodule (`$ROOT_DIR/llvm-propeller/propeller/testdata/`, `TD` below). E25/E26 validated both fixtures.

DeduBB fixtures (also used in Task 9; E24): `a.c` defines `master_fn`, and `b.c` defines `fold_fn` with the identical body `p[0]*3 + p[1]*5 + p[2]`, plus a `main` that prints `master_fn(v)+fold_fn(v)` for `v={1,2,3}` (expected `32`).

- [ ] **Step 1: `check_propeller_golden`** (Linux): profiles from `TD/sample_with_bb_hash.{bin,perfdata}`; the cc profile equals `TD/sample_with_bb_hash_cc_directives.golden.txt` after dropping `^h ` lines on both sides; the ld profile lists `main`.
- [ ] **Step 2: `check_propeller_relink ROOT TRIPLE`** (Linux triples): profiles from `TD/bimodal_sample_v2.bin` + `perfdata.1,perfdata.2`; compile `TD/bimodal_sample_v2.c` with the bundle's `<t>-clang -O2 -fbasic-block-sections=list=cc.txt -fuse-ld=lld -Wl,--symbol-ordering-file=ld.txt -Wl,--no-warn-symbol-ordering -Wl,-z,keep-text-section-prefix` (musl `-static`), and again as ThinLTO (`-flto=thin -Wl,--lto-basic-block-sections=cc.txt`). Evidence: `.text.hot` and `.text.split` sections; `llvm-nm -n` order of `main compute foo bar` matches `ld.txt`; `main.cold` within `.text.split`; runs (host arch only). The failure message points to `docs/notes/propeller-fixtures.md`.
- [ ] **Step 3: `check_propeller_live`**: probe first. `perf_branch_capable TRIPLE`: x86_64 runs `perf record -q -b -e cycles:u -o $tmp -- true`; aarch64 runs `perf record -q -e arm_spe// -o $tmp -- true`. Read `/proc/sys/kernel/perf_event_paranoid`. Not capable → `warn "propeller live $t: skipped (no LBR/SPE; paranoid=N)"`, or `fail` when `REQUIRE_LBR=yes`. Capable → record the DeduBB fixture's labelled build (`-j any,u` / `arm_spe//`), generate cc/ld, relink, same evidence as Step 2. Runs only for the host's own arch.
- [ ] **Step 4: `docs/notes/propeller-fixtures.md`**: the one-time recording procedure for our own fixture on an LBR-capable bare-metal x86 host (`perf record -e cycles:u -j any,u -c 100003`, a few seconds, `perf.data` ≤ 2 MB, check in source + labelled binary + perf.data + bundle version), to use if an LLVM bump breaks Step 2. Also: the future `sandbox-ci-x86` (`linux-amd64-bench`, `cloud-latitude`) probe, and that profile collection is a consumer-side step on consumers' own perf-capable hosts.
- [ ] **Step 5:** stage 95 → `ok propeller golden`, `ok propeller relink …`, and a `WARN … skipped` line for live on CI.
- [ ] **Step 6: Commit** (message: "verify: Propeller round trip from fixtures; capability-probed live check").

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
- [ ] **Step 7: Ledger** `docs/notes/llvm-patches.md`: one row per patch (origin, files, why, default, how to drop), plus the bump procedure from elide-dev/toolchain#4 (§"Tracking"). Each row links #4.
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

## Phase D — elidealloc shim and MemProf

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
- [ ] **Step 3:** Ledger rows linking [elide-dev/toolchain#4](https://github.com/elide-dev/toolchain/issues/4). If the patch set changes from what #4 describes, update `docs/notes/llvm-backports-issue.md` and post a comment on #4.
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

### Task 12: `libelidealloc-shim` component (allocator-agnostic frontend + mimalloc backend #1)

**Files:** Create `src/elidealloc-shim/elidealloc-shim.h`, `core.cc`, `hotcold.cc`, `backend.h`, `backend-mimalloc.cc`, `backend-forward.cc`, `elidealloc-shim.pc.in`, `abi-v1.symbols`; modify `scripts/stages/35-mimalloc.sh`, `tests/stages/35-mimalloc.check.sh`

**Interfaces (spec §5.2a, §5.3; the public part is frozen as v1):**

`elidealloc-shim.h` (installed, public, no backend types):
```c
#ifndef ELIDEALLOC_SHIM_H
#define ELIDEALLOC_SHIM_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define ELIDEALLOC_ABI_VERSION 1
typedef enum { ELIDEALLOC_DEFAULT = 0, ELIDEALLOC_HOT = 1, ELIDEALLOC_COLD = 2 } elidealloc_temp;
typedef struct { size_t cold_reserve_mb, hot_reserve_mb; int hot_large_pages;
                 unsigned cold_max, hot_min; int disable; } elidealloc_config;
typedef struct { size_t allocs[3], bytes[3], fallbacks; } elidealloc_stats;
int             elidealloc_abi_version(void);
const char     *elidealloc_backend_name(void);
int             elidealloc_configure(const elidealloc_config *c);  /* 0 ok, -1 if partitions exist */
void           *elidealloc_malloc(size_t size, elidealloc_temp t, size_t token_class);
void           *elidealloc_aligned_alloc(size_t align, size_t size, elidealloc_temp t, size_t token_class);
elidealloc_temp elidealloc_partition_of(const void *p, size_t *token_class_out);
void            elidealloc_get_stats(elidealloc_stats *out);
#ifdef __cplusplus
}
#endif
#endif
```

`abi-v1.symbols` (exact global defined symbols; the stage check diffs `llvm-nm --defined-only -g --format=just-symbols | LC_ALL=C sort` against it):
```
_ZnamRKSt9nothrow_t12__hot_cold_t
_ZnamSt11align_val_t12__hot_cold_t
_ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t
_Znam12__hot_cold_t
_ZnwmRKSt9nothrow_t12__hot_cold_t
_ZnwmSt11align_val_t12__hot_cold_t
_ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t
_Znwm12__hot_cold_t
elidealloc_abi_version
elidealloc_aligned_alloc
elidealloc_backend_name
elidealloc_configure
elidealloc_get_stats
elidealloc_malloc
elidealloc_partition_of
```
(Regenerate in `LC_ALL=C sort` order when creating the file. Backend symbols live in `namespace elidealloc::backend` with hidden visibility and must not appear.)

`backend.h` (internal, not installed; exactly spec §5.2a):
```cpp
#pragma once
#include <cstddef>
#include "elidealloc-shim.h"
namespace elidealloc::backend {
struct heap;
heap*  heap_create(elidealloc_temp t, size_t token_class, size_t reserve_mb, bool large_pages);
void   heap_destroy(heap* h);
void*  alloc(heap* h, size_t size, size_t align);     // h == nullptr -> default heap
void*  realloc(heap* h, void* p, size_t size);
void   free(void* p);
size_t usable_size(const void* p);
bool   owns(const heap* h, const void* p);
void   heap_stats(const heap* h, size_t* committed, size_t* reserved);
extern const char* const name;
}
```

- [ ] **Step 1: `backend-mimalloc.cc`** (compiled with `-DELIDEALLOC_BACKEND_MIMALLOC`):
```cpp
#include <mimalloc.h>
#include "backend.h"
namespace elidealloc::backend {
struct heap { mi_heap_t* h; mi_arena_id_t arena; };
const char* const name = "mimalloc";
heap* heap_create(elidealloc_temp, size_t, size_t reserve_mb, bool large) {
  mi_arena_id_t id = nullptr; mi_heap_t* h = nullptr;
  if (reserve_mb && mi_reserve_os_memory_ex(reserve_mb << 20, false, large, true, &id) == 0)
    h = mi_heap_new_in_arena(id);
  if (!h) { id = nullptr; h = mi_heap_new(); }
  if (!h) return nullptr;
  heap* r = static_cast<heap*>(mi_malloc(sizeof(heap)));   // tiny, lives for the process
  if (!r) { mi_heap_delete(h); return nullptr; }
  *r = {h, id}; return r;
}
void heap_destroy(heap* r) { mi_heap_delete(r->h); mi_free(r); }
void* alloc(heap* r, size_t n, size_t a) {
  if (!r) return a ? mi_malloc_aligned(n, a) : mi_malloc(n);
  return a ? mi_heap_malloc_aligned(r->h, n, a) : mi_heap_malloc(r->h, n);
}
void* realloc(heap* r, void* p, size_t n) { return r ? mi_heap_realloc(r->h, p, n) : mi_realloc(p, n); }
void free(void* p) { mi_free(p); }
size_t usable_size(const void* p) { return mi_usable_size(p); }
bool owns(const heap* r, const void* p) { return r->arena ? mi_arena_contains(r->arena, p) : mi_heap_contains(r->h, p); }
void heap_stats(const heap*, size_t* c, size_t* rs) { *c = 0; *rs = 0; }   // v1: frontend counters only
}
```
`backend-forward.cc` (`-DELIDEALLOC_BACKEND_FORWARD`): `name = "forward"`; `heap_create` returns `nullptr`; `alloc` → `malloc` / `aligned_alloc(a, round_up(n, a))`; `realloc` → `::realloc`; `free` → `::free`; `usable_size` → `malloc_usable_size` (Linux) / `malloc_size` (darwin); `owns` → `false`.

- [ ] **Step 2: `core.cc`** (frontend; backend-independent). Partition table `std::atomic<backend::heap*> g_part[16][3]`. Lazy CAS creation (`heap_create`; loser `heap_destroy`). Env read once (`ELIDEALLOC_COLD_RESERVE_MB`=256, `ELIDEALLOC_HOT_RESERVE_MB`=256, `ELIDEALLOC_HOT_LARGE_PAGES`=0, `ELIDEALLOC_COLD_MAX`=63, `ELIDEALLOC_HOT_MIN`=240, `ELIDEALLOC_DISABLE`=0, `ELIDEALLOC_STATS`=0 → `atexit` dump). `temp_of_hint(h)`: disabled → DEFAULT; `h ≤ cold_max` → COLD; `h ≥ hot_min` → HOT; else DEFAULT. **222 (ambiguous) and 128 (notcold) → DEFAULT by these defaults (spec D10); do not special-case them.** `alloc(n, align, t, cls)`: `(t==DEFAULT && cls==0)` → `backend::alloc(nullptr, …)`; else partition heap, `nullptr` from it → count a fallback and use the default heap. `elidealloc_partition_of` walks created partitions with `backend::owns`. Relaxed atomic counters for `elidealloc_get_stats`. `elidealloc_configure` fails once any partition exists. Public functions `extern "C"` with `__attribute__((visibility("default")))`; build with `-fvisibility=hidden`.

- [ ] **Step 3: `hotcold.cc`**: `enum class __hot_cold_t : uint8_t {};` at global scope, plus the 8 overloads. Each calls `core::alloc(n, align, temp_of_hint((uint8_t)h), 0)`. On `nullptr`, nothrow variants return `nullptr`; throwing variants loop on `std::get_new_handler()`, then `throw std::bad_alloc()`.

- [ ] **Step 4: Stage 35**: add `build_elidealloc_shim "$t"` at the end of each triple's iteration:
```bash
build_elidealloc_shim() {
  local t="$1" prefix b backend=mimalloc f libs
  prefix="$(target_prefix "$t")"; b="$(component_build_dir elidealloc-shim "$t")"; fresh_dir "$b"
  case "$(triple_libc "$t")" in
    musl) is_yes "$MUSL_USE_MIMALLOC" || backend=forward ;;
    darwin) backend=forward ;;
  esac
  for f in core hotcold "backend-$backend"; do
    # shellcheck disable=SC2046
    "$TOOLCHAIN_ROOT/bin/$t-clang++" -c -O2 -fPIC -std=c++17 -fvisibility=hidden \
      -flto=thin -ffat-lto-objects $(arch_flags "$t") "-DELIDEALLOC_BACKEND_${backend^^}" \
      -I"$prefix/include" -I"$ROOT_DIR/src/elidealloc-shim" \
      "$ROOT_DIR/src/elidealloc-shim/$f.cc" -o "$b/$f.o"
  done
  rm -f "$prefix/lib/libelidealloc-shim.a"
  "$TOOLCHAIN_ROOT/bin/llvm-ar" rcs "$prefix/lib/libelidealloc-shim.a" "$b"/*.o
  cp "$ROOT_DIR/src/elidealloc-shim/elidealloc-shim.h" "$prefix/include/"
  libs="-lelidealloc-shim"; [ "$(triple_libc "$t")" = gnu ] && libs="$libs -lmimalloc"
  mkdir -p "$prefix/lib/pkgconfig"
  sed "s|@LIBS@|$libs|; s|@BACKEND@|$backend|" "$ROOT_DIR/src/elidealloc-shim/elidealloc-shim.pc.in" \
    > "$prefix/lib/pkgconfig/elidealloc-shim.pc"
}
```
`elidealloc-shim.pc.in`: `prefix=/usr`, `backend=@BACKEND@`, `Name: elidealloc-shim`, `Libs: -L${prefix}/lib @LIBS@`, `Cflags: -I${prefix}/include` (relocated by `relocate_prefix` like other `.pc` files). Adding a backend later: new `backend-<x>.cc`, one `case` line here, and a `vars.sh` knob `ELIDEALLOC_BACKEND` to override the per-libc default.

- [ ] **Step 5: Stage check** (`35-mimalloc.check.sh`, per triple): archive, header and `.pc` exist; the exported symbol set equals `abi-v1.symbols` (Review Focus 5); `pkg-config --variable=backend` is `mimalloc` for gnu and musl-with-mimalloc and `forward` otherwise; the musl sysroot has **no** `libmimalloc.a` (single-instance rule, spec §5.5).
- [ ] **Step 6: Commit** `git commit -m "feat: libelidealloc-shim, allocator-agnostic hot/cold/default partitions, mimalloc backend (v1 ABI)"`

---

### Task 13: Shim tests and verification

**Files:** Create `tests/fixtures/elidealloc-shim-test.cc`; modify `tests/stages/35-mimalloc.check.sh`, `scripts/verify/checks.sh`

- [ ] **Step 1: Test program** (exit 0 = pass; prints the failing assertion). Build with `-DEXPECT_FORWARD` when the bundle's `.pc` reports `backend=forward`:
  - `operator new(64, (__hot_cold_t)1)` → `ELIDEALLOC_COLD`; `(…)254` → `ELIDEALLOC_HOT`; `(…)128` and `(…)222` → `ELIDEALLOC_DEFAULT` (forward mode: all `DEFAULT`)
  - all 8 overloads callable; aligned variants return `align`-aligned pointers (`align_val_t{256}`)
  - nothrow with `SIZE_MAX/2` returns `nullptr`; the throwing variant throws `std::bad_alloc`
  - `std::thread`: allocate cold in thread A, `delete` in thread B, then allocate cold in B
  - `elidealloc_get_stats` counts the hot and cold allocations made
  - `elidealloc_configure` returns -1 after the first partition exists
  - `elidealloc_malloc(32, ELIDEALLOC_COLD, 0)` → `COLD`; `free()` works on it
  - `operator new(64, (__hot_cold_t)222)` → `ELIDEALLOC_DEFAULT` (ambiguous stays default, spec D10); with `ELIDEALLOC_HOT_MIN=200` in a child process → `HOT` (thresholds tunable)
  - `elidealloc_backend_name()` matches the `.pc` `backend` variable
  - (separate process) `ELIDEALLOC_DISABLE=1` → everything `DEFAULT`
- [ ] **Step 2: Stage-35 check**: compile with stage-1 `<t>-clang++` (`-static` musl; `-lelidealloc-shim -lmimalloc` gnu) and run on the host (darwin: in its CI job).
- [ ] **Step 3: `check_elidealloc_shim ROOT TRIPLE`** in `checks.sh`: same against the packaged bundle, run from `pkg-config --libs elidealloc-shim` with `PKG_CONFIG_SYSROOT_DIR`/`LIBDIR` from `elide-toolchain env` (proves the `.pc` file).
- [ ] **Step 4: Commit** `git commit -m "verify: libelidealloc-shim partitions, OOM, threads, config, forward mode"`

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
#include "elidealloc-shim.h"
int main() {
  char *a = viaHot(10);
  char *b = viaCold(10);
  int rc = elidealloc_partition_of(a, nullptr) == ELIDEALLOC_DEFAULT ? 0 : 2;
#ifndef EXPECT_FORWARD
  rc |= elidealloc_partition_of(b, nullptr) == ELIDEALLOC_COLD ? 0 : 4;
#endif
  delete[] a; delete[] b;
  return rc;
}
```
`memprof-ctx.yaml`: E3's profile. Two `AllocSites` under `_Z5allocm` at `LineOffset: 1, Column: 10`. Cold: through `_Z7viaColdm` (`1,10`) and `main` (`LineOffset: 2, Column: 13`), `TotalSize 400, AllocCount 1, TotalLifetimeAccessDensity 1, TotalLifetime 1000000`. Notcold: through `_Z6viaHotm` and `main` (`1,13`), `TotalLifetimeAccessDensity 100000, TotalLifetime 1`. Plus `CallSites` for `_Z6viaHotm`, `_Z7viaColdm`, `main`. (`main` is on line 12, so its offsets stay 1 and 2; the notcold hint 128 maps to `DEFAULT` under spec D10.) `memprof.cc`: E10's loop program.
- [ ] **Step 2: Checks** `check_memprof_runtime` (x86_64 gnu: instrument → run → `merge --profiled-binary` → ≥ 2 contexts), `check_memprof_use` (all triples: YAML → match remark → link with `-Wl,-mllvm,-enable-memprof-context-disambiguation -Wl,-mllvm,-optimize-hot-cold-new -Wl,-mllvm,-supports-hot-cold-new $(pkg-config --libs elidealloc-shim)` (+ `-static` musl) → `_Z5allocm.memprof.1` and `_Znam12__hot_cold_t` present → run, exit 0; darwin link + nm only, `-DEXPECT_FORWARD`), `check_memprof_strip` (without `-supports-hot-cold-new`: no `hot_cold` symbol), `check_memprof_absent`. Function bodies follow the previous revision of this plan (git history of this file) with `-lmimalloc-hotcold` replaced by the `.pc` libs.
- [ ] **Step 3:** Stage 95 on all hosts → all `ok`.
- [ ] **Step 4: Commit** `git commit -m "verify: MemProf runtime, profile use through libelidealloc-shim, hint stripping"`

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
| `memprof-use=F` | `-flto=thin -gmlt -fdebug-info-for-profiling -fmemory-profile-use=F` | `-flto=thin -fuse-ld=lld -Wl,-mllvm,-enable-memprof-context-disambiguation -Wl,-mllvm,-optimize-hot-cold-new -Wl,-mllvm,-supports-hot-cold-new -lelidealloc-shim` (+ `-lmimalloc` on gnu) |

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
  "elideallocShim": { "lib": "libelidealloc-shim.a", "abi": 1, "backend": "mimalloc", "hotColdNew": true, "allocToken": false }
}
```
darwin: `propeller`/`dedubb` absent, `runtimeTargets: []`, shim present with `"backend": "forward"`. Steps: test, implement, run, commit `feat(manifest): advertise Propeller, DeduBB, MemProf and shim features`.

---

### Task 17: README, full build, consumer trial

- [ ] **Step 1: README** sections: "Propeller", "DeduBB", "elidealloc shim", "MemProf". Cover the support matrix (spec §1.2), `elide-toolchain flags` modes, the workflows (spec §3.5, §4.3, §6.2), pipeline ordering (spec §7), and the caveats (LBR/SPE requirement; content-hash profile and directive names because of caches; never profile DeduBB/relinked binaries; hints need ThinLTO + the shim; gnu needs `-lmimalloc`; musl static only; GraalVM limits). Update the base spec's bundle layout (§2) with `bin/generate_propeller_profiles`, `libelidealloc-shim.a`, `elidealloc-shim.h`, and stage 45 in the stage table.
- [ ] **Step 2: Full CI build** (three hosts) green with all new checks.
- [ ] **Step 3: Consumer trial** (gate before release): one real consumer (WHIPLASH C++ or Komodo) through Propeller+DeduBB and MemProf+shim. Record `.text` delta, a benchmark A/B (`ELIDEALLOC_DISABLE=1`), and an exception/unwind smoke test through folded code in `docs/notes/propeller-dedubb-memprof-trial.md`.
- [ ] **Step 4: Commit** `git commit -m "docs: Propeller, DeduBB, elidealloc shim and MemProf usage"`

---

## Follow-ups (not in this plan)

- `libelidealloc-shim` v2: `token.o`/`token_fast.o` members implementing `__alloc_token_*` (spec §5.4), with an alloc-token verification check.
- aarch64 Propeller profiling via ARM SPE (`--profile_type=PERF_SPE`) on a host that has it.
- Optional experimental `bolt-dedubb` patch (spec §4.5).
- aarch64/darwin MemProf runtime (upstream work).
