# MemProf and DeduBB Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship MemProf (runtime, allocator hot/cold support, backports) and DeduBB (CodeGen+lld and BOLT patches, later the Propeller directive generator) in the elide-toolchain LLVM 23.1.2 bundles, with verification and a documented downstream flag contract.

**Architecture:** LLVM changes are carried as `src/patches/llvm/NNNN-*.patch` and applied to the `llvm` submodule by the existing idempotent `apply_patches` in stages 10, 30 and 40. Stage 30 builds the compiler-rt memprof runtime for `x86_64-unknown-linux-gnu` only. Stage 35 adds `libmimalloc-hotcold.a` (tcmalloc-compatible `__hot_cold_t` `operator new` overloads on mimalloc heaps) to every sysroot. The helper CLI gains `flags` to print consumer flags. Stage 95 gains MemProf and DeduBB checks. Phase 2 adds a Linux-only stage 45 that builds `generate_propeller_profiles` with DeduBB support.

**Tech Stack:** bash, POSIX sh (helper), CMake + Ninja, LLVM 23.1.2, compiler-rt, mimalloc 3.5.4, C++17, Python 3 (manifest).

**Spec:** `docs/superpowers/specs/2026-10-05-memprof-dedubb-design.md`. Evidence and file:line references: `docs/notes/memprof-dedubb-research.md`. Section references (§N) point into the spec, (EN) into the notes' experiment table.

## Global Constraints

- Everything in the base plan's Global Constraints still holds (glibc floor 2.34, macOS min 12.0, relocatable bundle, no `sudo`, writes only under `out/` and `dist/`, bash ≥ 4 for build scripts, POSIX sh for the helper).
- LLVM stays at `llvmorg-23.1.2`. Never edit the `llvm` submodule by hand; every change is a patch under `src/patches/llvm/`.
- Patches never overlap hunks with each other (spec D2). Local fixups are folded into the vendored patch file, with a header comment recording upstream origin and the local change.
- DeduBB must be inert without `-dedubb-directives` (spec D10). `check_dedubb_inert` pins it.
- The bundle never enables `-supports-hot-cold-new` on its own (spec D9).
- Commit messages: plain, no attribution trailers (repository rule for this work).

## Review Focus

1. **Re-running a stage on an already patched `llvm` tree** (`./build.sh --from 40-llvm-stage2` after a full build): every patch must be detected as applied. Pinned by the series unit test in Task 1 and by running stage 40 twice in Task 4.
2. **The shipped compiler's behaviour for consumers who never use DeduBB**: byte-identical output with and without the patch, for code without directives. Pinned by `check_dedubb_inert` (Task 10) and the gate in Task 7.
3. **A gnu consumer that links `-lmimalloc-hotcold` without `-lmimalloc`, or a dynamic musl consumer**: must link and run (gnu: link error that names `mi_*` is acceptable and documented; musl dynamic: silent forwarding). Pinned by `check_memprof_use` variants (Task 6).
4. **Glibc floor**: the new `libclang_rt.memprof.so` must not need `GLIBC_2.35+`. Pinned by the existing `check_glibc_floor` (it scans `lib/**/*.so`), confirmed in Task 4.
5. **`llvm-bolt --dedubb` output loses NX stack** when BOLT adds a segment (spec §4.4, risk 2). `check_dedubb_bolt` asserts `GNU_STACK` is still `RW` on the fixture and documents the flag combination that keeps it.

---

## File Structure

```
src/patches/llvm/0001-memprof-deterministic-clone-tiebreak.patch   # NEW (Task 3)  upstream #222126
src/patches/llvm/0002-memprof-histogram-tail-granule.patch         # NEW (Task 3)  upstream #208911
src/patches/llvm/0100-dedubb-codegen.patch                         # NEW (Task 7)  DeduBB main 07d730d + gate
src/patches/llvm/0101-dedubb-bolt.patch                            # NEW (Task 8)  DeduBB bolt-dedubb 0e20b1f
src/patches/llvm-propeller/0001-find-package-llvm.patch            # REWRITE (Task 12) rebased on ddfb8b7
src/patches/llvm-propeller/0002-mccontext-asminfo-pointer.patch    # DELETE (Task 12) obsolete
src/patches/llvm-propeller/0003-dedubb.patch                       # NEW (Task 12)
src/mimalloc-hotcold.cc                                            # NEW (Task 5)
src/mimalloc-hotcold.h                                             # NEW (Task 5)
scripts/lib/common.sh                                              # MODIFY (Task 1) apply_patches '# requires:' gating
scripts/lib/platform.sh                                            # MODIFY (Task 4) memprof_supported
scripts/stages/10-llvm-stage1.sh, 30-runtimes.sh, 40-llvm-stage2.sh   # MODIFY (Tasks 2, 4)
scripts/stages/35-mimalloc.sh                                      # MODIFY (Task 5)
scripts/stages/45-propeller.sh                                     # NEW (Task 12, phase 2)
scripts/verify/checks.sh                                           # MODIFY (Tasks 6, 10, 12)
scripts/gen-manifest.py                                            # MODIFY (Task 11)
src/elide-toolchain                                                # MODIFY (Task 9) `flags` subcommand
vars.sh                                                            # MODIFY (Task 2) LLVM_DEDUBB, LLVM_DEDUBB_BOLT
versions.env                                                       # MODIFY (Task 12) propeller dep pins
tests/unit/common.test.sh, platform.test.sh, helper.test.sh, manifest.test.sh   # MODIFY
tests/stages/30-runtimes.check.sh, 35-mimalloc.check.sh, 40-llvm-stage2.check.sh # MODIFY
tests/fixtures/memprof.cc, memprof-ctx.cc, memprof-ctx.yaml        # NEW (Task 6)
tests/fixtures/dedubb/a.c, b.c, directives.txt                     # NEW (Task 10)
docs/notes/llvm-patches.md                                         # NEW (Task 3) patch ledger
README.md                                                          # MODIFY (Task 13)
```

---

## Phase A — Patch plumbing

### Task 1: `apply_patches` gating and series idempotency

**Files:**
- Modify: `scripts/lib/common.sh`
- Modify: `tests/unit/common.test.sh`

**Interfaces:**
- Produces: `apply_patches COMPONENT DIR` unchanged signature. New behaviour: if a patch's first line is `# requires: VAR`, the patch is skipped (with a log line) unless `is_yes "${!VAR:-}"`. Consumed by Tasks 2, 7, 8.

- [ ] **Step 1: Write the failing tests** (append before `finish` in `tests/unit/common.test.sh`)

```bash
# apply_patches — a dependent two-patch series re-applies as a no-op (spec D2: patches must
# not overlap hunks; this pins the property for adjacent-but-disjoint hunks).
work="$ROOT_DIR/out/test-tmp/series"; rm -rf "$work"; mkdir -p "$work/src" "$work/patches/demo"
printf 'a\nb\nc\nd\ne\nf\ng\n' > "$work/src/f.txt"
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
PATCHES_DIR="$work/patches" apply_patches demo "$work/src"
assert_eq "$(head -1 "$work/src/f.txt")$(tail -1 "$work/src/f.txt")" "AG" "series applied"
assert_ok env PATCHES_DIR="$work/patches" bash -c "source '$ROOT_DIR/scripts/lib/common.sh'; ROOT_DIR='$ROOT_DIR' apply_patches demo '$work/src'"

# apply_patches — '# requires: VAR' skips the patch unless VAR is yes.
printf 'x\n' > "$work/src/g.txt"
cat > "$work/patches/demo/0003-gated.patch" <<'EOF'
# requires: DEMO_KNOB
--- a/g.txt
+++ b/g.txt
@@ -1 +1 @@
-x
+X
EOF
DEMO_KNOB=no PATCHES_DIR="$work/patches" apply_patches demo "$work/src"
assert_eq "$(cat "$work/src/g.txt")" "x" "gated patch skipped"
DEMO_KNOB=yes PATCHES_DIR="$work/patches" apply_patches demo "$work/src"
assert_eq "$(cat "$work/src/g.txt")" "X" "gated patch applied"
rm -rf "$ROOT_DIR/out/test-tmp"
```

- [ ] **Step 2: Run** `tests/run.sh common` → Expected: FAIL on "gated patch skipped".

- [ ] **Step 3: Implement** in `apply_patches`, right after `[ -e "$patch" ] || continue`:

```bash
    local req
    req="$(head -n1 "$patch" | sed -n 's/^# requires: *\([A-Za-z_][A-Za-z0-9_]*\) *$/\1/p')"
    if [ -n "$req" ] && ! is_yes "${!req:-}"; then
      log "skipping $(basename "$patch") ($req is not yes)"; continue
    fi
```

- [ ] **Step 4: Run** `tests/run.sh common` → Expected: all pass. Then `tests/run.sh` (shellcheck clean).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/common.sh tests/unit/common.test.sh
git commit -m "feat(common): gate patches on '# requires: VAR'; test series re-apply"
```

---

### Task 2: Apply `src/patches/llvm` in the LLVM stages; knobs

**Files:**
- Modify: `scripts/stages/10-llvm-stage1.sh`, `scripts/stages/30-runtimes.sh`, `scripts/stages/40-llvm-stage2.sh`
- Modify: `vars.sh`
- Create: `src/patches/llvm/.gitkeep`

**Interfaces:**
- Consumes: `apply_patches` (Task 1).
- Produces: knobs `LLVM_DEDUBB` (default `yes`), `LLVM_DEDUBB_BOLT` (default `yes`), read by `# requires:` headers in Tasks 7–8.

- [ ] **Step 1:** In each of the three stages, make `apply_patches llvm "$ROOT_DIR/llvm"` the first line of `stage_main` (stage 10 for both the Linux and darwin paths; stage 30 and 40 Linux only by `stage_applies`).

```bash
stage_main() {
  apply_patches llvm "$ROOT_DIR/llvm"
  if [ "$HOST_OS" = linux ]; then llvm_stage1_linux; else llvm_darwin; fi
}
```

- [ ] **Step 2:** `vars.sh`, after the mimalloc block:

```bash
# LLVM feature patches (src/patches/llvm, '# requires:' headers)
LLVM_DEDUBB=${LLVM_DEDUBB:-yes}
LLVM_DEDUBB_BOLT=${LLVM_DEDUBB_BOLT:-yes}
```

- [ ] **Step 3:** With an empty `src/patches/llvm/` (only `.gitkeep`), run `./build.sh --only 10-llvm-stage1` on a host with a warm build. Expected: no `applying` lines and identical behaviour. (`apply_patches` globs `*.patch`.)

- [ ] **Step 4: Commit**

```bash
git add scripts/stages/10-llvm-stage1.sh scripts/stages/30-runtimes.sh scripts/stages/40-llvm-stage2.sh vars.sh src/patches/llvm/.gitkeep
git commit -m "build: apply src/patches/llvm in LLVM stages; DeduBB knobs"
```

---

### Task 3: MemProf backports and the patch ledger

**Files:**
- Create: `src/patches/llvm/0001-memprof-deterministic-clone-tiebreak.patch`
- Create: `src/patches/llvm/0002-memprof-histogram-tail-granule.patch`
- Create: `docs/notes/llvm-patches.md`

**Interfaces:**
- Produces: two patches applied by Task 2's hook.

- [ ] **Step 1: Fetch the upstream diffs with provenance headers**

```bash
for pr in 222126:0001-memprof-deterministic-clone-tiebreak 208911:0002-memprof-histogram-tail-granule; do
  n=${pr%%:*}; f=src/patches/llvm/${pr#*:}.patch
  sha=$(gh pr view "$n" --repo llvm/llvm-project --json mergeCommit --jq .mergeCommit.oid)
  { echo "# upstream: https://github.com/llvm/llvm-project/pull/$n ($sha)"; echo "# local: none"; \
    gh pr diff "$n" --repo llvm/llvm-project; } > "$f"
done
```

- [ ] **Step 2: Prove they apply forward, re-apply as no-ops, and reverse cleanly** on a scratch copy of only the touched files (never the submodule):

```bash
S=$(mktemp -d); L=$PWD/llvm
for p in src/patches/llvm/000*.patch; do
  grep '^diff --git' "$p" | awk '{print substr($3,3)}' | while read -r f; do
    [ -f "$L/$f" ] && { mkdir -p "$S/$(dirname "$f")"; cp "$L/$f" "$S/$f"; }; done
done
PATCHES_DIR=$PWD/src/patches bash -c "source scripts/lib/common.sh; ROOT_DIR=$PWD apply_patches llvm $S"
PATCHES_DIR=$PWD/src/patches bash -c "source scripts/lib/common.sh; ROOT_DIR=$PWD apply_patches llvm $S"   # 'already applied' x2
grep -n 'NodeId < B->Caller->NodeId' "$S/llvm/lib/Transforms/IPO/MemProfContextDisambiguation.cpp"
```
Expected: first run `applying …` twice, second run `already applied …` twice, grep finds the new comparator.

- [ ] **Step 3: Write `docs/notes/llvm-patches.md`**: one row per patch (file, upstream PR/commit or out-of-tree origin, files touched, why, how to drop it on the next LLVM bump), starting with these two.

- [ ] **Step 4: Commit**

```bash
git add src/patches/llvm/0001-*.patch src/patches/llvm/0002-*.patch docs/notes/llvm-patches.md
git commit -m "llvm: backport MemProf deterministic cloning (#222126) and histogram fix (#208911)"
```

---

## Phase B — MemProf

### Task 4: compiler-rt memprof runtime for x86_64-unknown-linux-gnu

**Files:**
- Modify: `scripts/lib/platform.sh`
- Modify: `scripts/stages/30-runtimes.sh`
- Modify: `tests/unit/platform.test.sh`
- Modify: `tests/stages/30-runtimes.check.sh`

**Interfaces:**
- Produces: `memprof_supported TRIPLE` (exit 0 only for `x86_64-unknown-linux-gnu`); bundle files `lib/clang/23/lib/x86_64-unknown-linux-gnu/libclang_rt.memprof{.a,.so,_cxx.a,-preinit.a}` (+ `.syms`). Consumed by Tasks 6, 9, 11.

- [ ] **Step 1: Failing unit test** (`tests/unit/platform.test.sh`)

```bash
assert_ok memprof_supported x86_64-unknown-linux-gnu
assert_fails memprof_supported x86_64-unknown-linux-musl
assert_fails memprof_supported aarch64-unknown-linux-gnu
assert_fails memprof_supported arm64-apple-darwin
```

- [ ] **Step 2: Implement** in `scripts/lib/platform.sh`:

```bash
# memprof_supported TRIPLE — compiler-rt's memprof runtime: x86_64 Linux only
# (compiler-rt AllSupportedArchDefs.cmake:96, config-ix.cmake:842), and static linking is
# refused (memprof_rtl.cpp:181), which rules out musl.
memprof_supported() { [ "$1" = x86_64-unknown-linux-gnu ]; }
```
Run `tests/run.sh platform` → pass.

- [ ] **Step 3: Stage 30.** `runtimes_common_args` takes an optional second argument and stops hard-coding `MEMPROF=OFF`:

```bash
runtimes_common_args() {
  local t="$1" memprof="${2:-OFF}" s="$STAGE1_DIR/bin" af
  ...
    -DCOMPILER_RT_BUILD_MEMPROF="$memprof" -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_GWP_ASAN=OFF
}
```
In `build_cxx_runtimes`:

```bash
  local memprof=OFF memprof_args=()
  if memprof_supported "$t"; then
    memprof=ON
    # The always-built libclang_rt.memprof.so must link against our sysroot: no libstdc++
    # (SANITIZER_CXX_ABI=none) and lld + compiler-rt crt instead of the host ld/crtbeginS.o.
    memprof_args=(-DSANITIZER_CXX_ABI=none
      "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld -rtlib=compiler-rt -unwindlib=none")
  fi
  mapfile -t args < <(runtimes_common_args "$t" "$memprof")
  ...
  cmake -S "$ROOT_DIR/llvm/runtimes" -B "$b" "${args[@]}" "${memprof_args[@]}" \
```

- [ ] **Step 4: Stage check** (`tests/stages/30-runtimes.check.sh`, inside the triple loop):

```bash
  rd="$BUNDLE_DIR/lib/clang/$LLVM_MAJOR/lib/$t"
  if memprof_supported "$t"; then
    for f in libclang_rt.memprof.a libclang_rt.memprof_cxx.a libclang_rt.memprof-preinit.a libclang_rt.memprof.so; do assert_file "$rd/$f"; done
  else
    assert_eq "$(ls "$rd" | grep -c memprof || true)" "0" "no memprof runtime for $t"
  fi
```

- [ ] **Step 5: Build and check**

Run: `./build.sh --from 30-runtimes --only 30-runtimes && bash tests/stages/30-runtimes.check.sh`
Expected: `0 failed`. Then confirm the floor:
`out/linux-amd64/stage1/bin/llvm-readelf -V out/linux-amd64/elide-toolchain/lib/clang/23/lib/x86_64-unknown-linux-gnu/libclang_rt.memprof.so | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1` → `GLIBC_2.34` or lower (E20 saw 2.34).

- [ ] **Step 6: Re-run idempotency** (Review Focus 1): `./build.sh --only 40-llvm-stage2` twice on a tree that has Task 3's patches. Expected: second run logs `already applied` for every patch.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/platform.sh scripts/stages/30-runtimes.sh tests/unit/platform.test.sh tests/stages/30-runtimes.check.sh
git commit -m "feat(runtimes): build compiler-rt memprof for x86_64-unknown-linux-gnu"
```

---

### Task 5: `libmimalloc-hotcold.a` (tcmalloc-compatible hot/cold `operator new`)

**Files:**
- Create: `src/mimalloc-hotcold.cc`, `src/mimalloc-hotcold.h`
- Modify: `scripts/stages/35-mimalloc.sh`
- Modify: `tests/stages/35-mimalloc.check.sh`

**Interfaces:**
- Produces, per triple: `<sysroot>/usr/lib/libmimalloc-hotcold.a`, `<sysroot>/usr/include/mimalloc-hotcold.h`. Exported symbols: the 8 `operator new(…, __hot_cold_t)` overloads (`_Znwm12__hot_cold_t`, `_Znam12__hot_cold_t`, `_ZnwmRKSt9nothrow_t12__hot_cold_t`, `_ZnamRKSt9nothrow_t12__hot_cold_t`, `_ZnwmSt11align_val_t12__hot_cold_t`, `_ZnamSt11align_val_t12__hot_cold_t`, `_ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t`, `_ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t`), `elide_hotcold_is_cold`, `elide_hotcold_cold_bytes`. Consumed by Tasks 6, 9.

- [ ] **Step 1: Header** `src/mimalloc-hotcold.h`

```c
/* mimalloc-hotcold.h: hot/cold operator new for MemProf-optimized builds (elide-toolchain).
 * Link -lmimalloc-hotcold (gnu: also -lmimalloc) and pass -Wl,-mllvm,-supports-hot-cold-new. */
#ifndef MIMALLOC_HOTCOLD_H
#define MIMALLOC_HOTCOLD_H
#include <stdbool.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
bool elide_hotcold_is_cold(const void *p);   /* p was served from the cold arena */
size_t elide_hotcold_cold_bytes(void);       /* approximate bytes served cold so far */
#ifdef __cplusplus
}
#endif
#endif
```

- [ ] **Step 2: Implementation** `src/mimalloc-hotcold.cc` (prototype validated in E14; this version adds weak linkage per spec D8, the env knob, and stats):

```cpp
// tcmalloc-compatible __hot_cold_t operator new overloads on mimalloc (spec §3.4).
// HOTCOLD_FORWARD_ONLY: darwin (static mimalloc does not override free) -> plain new.
// HOTCOLD_WEAK_MI: musl (mi_* live in libc.a's single mimalloc.o; dynamic libc.so does not
//                  export them, so the weak refs are null there and we forward).
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <new>
#include "mimalloc-hotcold.h"

enum class __hot_cold_t : uint8_t {};

#if !defined(HOTCOLD_FORWARD_ONLY)
#include <mimalloc.h>
#if defined(HOTCOLD_WEAK_MI)
#pragma weak mi_reserve_os_memory_ex
#pragma weak mi_heap_new_in_arena
#pragma weak mi_heap_new
#pragma weak mi_heap_delete
#pragma weak mi_heap_malloc
#pragma weak mi_heap_malloc_aligned
#pragma weak mi_arena_contains
#define MI_AVAILABLE() (&mi_heap_malloc != nullptr)
#else
#define MI_AVAILABLE() true
#endif

namespace {
std::atomic<mi_heap_t *> g_cold{nullptr};
std::atomic<mi_arena_id_t> g_arena{nullptr};
std::atomic<size_t> g_cold_bytes{0};

mi_heap_t *cold_heap() {
  mi_heap_t *h = g_cold.load(std::memory_order_acquire);
  if (h) return h;
  size_t mb = 256;
  if (const char *e = std::getenv("ELIDE_HOTCOLD_ARENA_MB")) mb = std::strtoul(e, nullptr, 10);
  mi_arena_id_t id = nullptr;
  mi_heap_t *nh = nullptr;
  if (mb && mi_reserve_os_memory_ex(mb << 20, false, false, true, &id) == 0) nh = mi_heap_new_in_arena(id);
  if (!nh) { id = nullptr; nh = mi_heap_new(); }
  mi_heap_t *expected = nullptr;
  if (!g_cold.compare_exchange_strong(expected, nh, std::memory_order_acq_rel)) {
    mi_heap_delete(nh);           // lost the race; live blocks (none) move to the main heap
    return expected;
  }
  g_arena.store(id, std::memory_order_release);
  return nh;
}

void *cold_new(size_t n, size_t align, bool nothrow) {
  for (;;) {
    mi_heap_t *h = cold_heap();
    void *p = h ? (align ? mi_heap_malloc_aligned(h, n, align) : mi_heap_malloc(h, n)) : nullptr;
    if (p) { g_cold_bytes.fetch_add(n, std::memory_order_relaxed); return p; }
    if (h) return nullptr;        // arena exhausted: caller falls back to the default heap
    std::new_handler nh = std::get_new_handler();
    if (!nh) { if (nothrow) return nullptr; throw std::bad_alloc(); }
    nh();
  }
}
inline bool is_cold(__hot_cold_t h) { return static_cast<uint8_t>(h) < 128 && MI_AVAILABLE(); }
} // namespace

extern "C" bool elide_hotcold_is_cold(const void *p) {
  mi_arena_id_t id = g_arena.load(std::memory_order_acquire);
  return MI_AVAILABLE() && id && mi_arena_contains(id, p);
}
extern "C" size_t elide_hotcold_cold_bytes(void) { return g_cold_bytes.load(std::memory_order_relaxed); }

#define COLD_OR(n, al, nt, fallback) \
  do { if (is_cold(h)) { if (void *p_ = cold_new((n), (al), (nt))) return p_; } return fallback; } while (0)
#else
extern "C" bool elide_hotcold_is_cold(const void *) { return false; }
extern "C" size_t elide_hotcold_cold_bytes(void) { return 0; }
#define COLD_OR(n, al, nt, fallback) do { (void)h; return fallback; } while (0)
#endif

void *operator new(size_t n, __hot_cold_t h) { COLD_OR(n, 0, false, ::operator new(n)); }
void *operator new[](size_t n, __hot_cold_t h) { COLD_OR(n, 0, false, ::operator new[](n)); }
void *operator new(size_t n, const std::nothrow_t &t, __hot_cold_t h) noexcept { COLD_OR(n, 0, true, ::operator new(n, t)); }
void *operator new[](size_t n, const std::nothrow_t &t, __hot_cold_t h) noexcept { COLD_OR(n, 0, true, ::operator new[](n, t)); }
void *operator new(size_t n, std::align_val_t a, __hot_cold_t h) { COLD_OR(n, size_t(a), false, ::operator new(n, a)); }
void *operator new[](size_t n, std::align_val_t a, __hot_cold_t h) { COLD_OR(n, size_t(a), false, ::operator new[](n, a)); }
void *operator new(size_t n, std::align_val_t a, const std::nothrow_t &t, __hot_cold_t h) noexcept { COLD_OR(n, size_t(a), true, ::operator new(n, a, t)); }
void *operator new[](size_t n, std::align_val_t a, const std::nothrow_t &t, __hot_cold_t h) noexcept { COLD_OR(n, size_t(a), true, ::operator new[](n, a, t)); }
```
Note: `cold_new` returning NULL when the arena is full makes the macro fall through to the default allocation, which keeps the throw/nothrow semantics of `::operator new`.

- [ ] **Step 3: Stage 35.** Add `build_hotcold "$t"` at the end of the per-triple loop:

```bash
build_hotcold() {
  local t="$1" prefix defs=() b
  prefix="$(target_prefix "$t")"
  b="$(component_build_dir mimalloc-hotcold "$t")"; fresh_dir "$b"
  case "$(triple_libc "$t")" in
    musl) defs=(-DHOTCOLD_WEAK_MI) ;;
    darwin) defs=(-DHOTCOLD_FORWARD_ONLY) ;;
  esac
  # shellcheck disable=SC2046
  "$TOOLCHAIN_ROOT/bin/$t-clang++" -c -O2 -fPIC -std=c++17 -flto=thin -ffat-lto-objects \
    $(arch_flags "$t") "${defs[@]}" -I"$prefix/include" -I"$ROOT_DIR/src" \
    "$ROOT_DIR/src/mimalloc-hotcold.cc" -o "$b/mimalloc-hotcold.o"
  "$TOOLCHAIN_ROOT/bin/llvm-ar" rcs "$prefix/lib/libmimalloc-hotcold.a" "$b/mimalloc-hotcold.o"
  cp "$ROOT_DIR/src/mimalloc-hotcold.h" "$prefix/include/"
}
```
(`$TOOLCHAIN_ROOT/bin/$t-clang++` exists on Linux after stage 30's `install_frontends "$STAGE1_DIR"`; on darwin `TOOLCHAIN_ROOT=$BUNDLE_DIR` after stage 10. If the stage-1 front-end is not yet named that way, use the `clang++ --target=$t --sysroot=…` form as `build_musl_phase2` does.)

- [ ] **Step 4: Stage check** (`tests/stages/35-mimalloc.check.sh`, inside the loop):

```bash
  assert_file "$p/lib/libmimalloc-hotcold.a"
  assert_file "$p/include/mimalloc-hotcold.h"
  syms="$("$nm" "$p/lib/libmimalloc-hotcold.a" 2>/dev/null)"
  assert_contains "$syms" "_Znam12__hot_cold_t" "hot/cold new[] exported ($t)"
  assert_contains "$syms" "_ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t" "aligned nothrow variant ($t)"
```

- [ ] **Step 5: Build and check**: `./build.sh --only 35-mimalloc && bash tests/stages/35-mimalloc.check.sh` → `0 failed`. The bitcode check (base Task 19a) will see a fat ThinLTO member; it must pass unchanged.

- [ ] **Step 6: Commit**

```bash
git add src/mimalloc-hotcold.cc src/mimalloc-hotcold.h scripts/stages/35-mimalloc.sh tests/stages/35-mimalloc.check.sh
git commit -m "feat(mimalloc): libmimalloc-hotcold, tcmalloc-compatible hot/cold operator new"
```

---

### Task 6: MemProf verification checks

**Files:**
- Create: `tests/fixtures/memprof.cc`, `tests/fixtures/memprof-ctx.cc`, `tests/fixtures/memprof-ctx.yaml`
- Modify: `scripts/verify/checks.sh`

**Interfaces:**
- Produces: `check_memprof_runtime ROOT TRIPLE`, `check_memprof_use ROOT TRIPLE`, `check_memprof_strip ROOT TRIPLE`, `check_memprof_absent ROOT TRIPLE`, wired into `run_all_checks`.

- [ ] **Step 1: Fixtures.** `tests/fixtures/memprof-ctx.cc`: line numbers are load-bearing (the YAML's `LineOffset`/`Column` refer to them; do not reformat):

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
extern "C" bool elide_hotcold_is_cold(const void *p);
int main() {
  char *a = viaHot(10);
  char *b = viaCold(10);
  int rc = elide_hotcold_is_cold(a) ? 2 : 0;
#ifdef EXPECT_COLD
  rc |= elide_hotcold_is_cold(b) ? 0 : 4;
#endif
  delete[] a; delete[] b;
  return rc;
}
```
`tests/fixtures/memprof-ctx.yaml`: copy `docs/notes/memprof-dedubb-research.md` E3's profile, i.e. two `AllocSites` under `_Z5allocm`. The cold context runs through `_Z7viaColdm` and `main` at `LineOffset: 2, Column: 13` (TotalSize 400, AllocCount 1, TotalLifetimeAccessDensity 1, TotalLifetime 1000000). The notcold context runs through `_Z6viaHotm` and `main` at `LineOffset: 1, Column: 13` (TotalLifetimeAccessDensity 100000, TotalLifetime 1). Add `CallSites` records for `_Z6viaHotm`, `_Z7viaColdm` (`LineOffset: 1, Column: 10`) and `main` (both lines). `main` starts on line 12 here, so the offsets stay 1 and 2. Re-derive them if the file changes.
`tests/fixtures/memprof.cc`: the hot/cold loop program used in E10 (100000 short-lived 64-byte `new[]`s via one wrapper, 4 via another).

- [ ] **Step 2: Checks** (append to `checks.sh`):

```bash
memprof_use_flags() { printf '%s\n' -O2 -gmlt -fdebug-info-for-profiling -flto=thin; }
memprof_hint_ldflags() {
  printf '%s\n' -fuse-ld=lld -Wl,-mllvm,-enable-memprof-context-disambiguation \
    -Wl,-mllvm,-optimize-hot-cold-new -Wl,-mllvm,-supports-hot-cold-new -lmimalloc-hotcold
}

# check_memprof_runtime ROOT TRIPLE — instrument, run, index (x86_64 gnu only; spec D4).
check_memprof_runtime() {
  local root="$1" t="$2" tmp n
  memprof_supported "$t" || return 0
  tmp="$(mktemp -d)"
  if ! "$root/bin/$t-clang++" -O2 -gmlt -fdebug-info-for-profiling -fmemory-profile \
      -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -fno-optimize-sibling-calls -fno-pie -no-pie \
      -Wl,-z,noseparate-code -Wl,--build-id "$ROOT_DIR/tests/fixtures/memprof.cc" -o "$tmp/instr" 2>"$tmp/err"; then
    fail "memprof runtime $t" "$(head -3 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  (cd "$tmp" && ./instr) || { fail "memprof runtime $t" "instrumented binary failed"; rm -rf "$tmp"; return; }
  if ! "$root/bin/llvm-profdata" merge "$tmp"/memprof.profraw.* --profiled-binary "$tmp/instr" -o "$tmp/p.memprofdata" 2>"$tmp/err"; then
    fail "memprof runtime $t" "merge: $(head -3 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  n="$("$root/bin/llvm-profdata" show --memory "$tmp/p.memprofdata" | sed -n 's/^#   Total contexts: //p')"
  if [ "${n:-0}" -ge 2 ]; then pass "memprof runtime $t"; else fail "memprof runtime $t" "contexts=$n"; fi
  rm -rf "$tmp"
}

# check_memprof_use ROOT TRIPLE — YAML profile -> clone + hot/cold call + allocator shim (all triples).
check_memprof_use() {
  local root="$1" t="$2" tmp f=() l=() extra=() exp=()
  tmp="$(mktemp -d)"
  mapfile -t f < <(memprof_use_flags); mapfile -t l < <(memprof_hint_ldflags)
  case "$(triple_libc "$t")" in gnu) extra=(-lmimalloc); exp=(-DEXPECT_COLD) ;; musl) extra=(-static); exp=(-DEXPECT_COLD) ;; esac
  "$root/bin/llvm-profdata" merge "$ROOT_DIR/tests/fixtures/memprof-ctx.yaml" -o "$tmp/p.memprofdata" || { fail "memprof use $t" "yaml merge"; rm -rf "$tmp"; return; }
  if ! "$root/bin/$t-clang++" "${f[@]}" "${exp[@]}" -fmemory-profile-use="$tmp/p.memprofdata" -Rpass=memprof \
      -c "$ROOT_DIR/tests/fixtures/memprof-ctx.cc" -o "$tmp/c.o" 2>"$tmp/rem"; then
    fail "memprof use $t" "$(head -3 "$tmp/rem")"; rm -rf "$tmp"; return
  fi
  grep -q 'matched alloc context' "$tmp/rem" || { fail "memprof use $t" "no MemProf match remark"; rm -rf "$tmp"; return; }
  if ! "$root/bin/$t-clang++" "${f[@]}" "$tmp/c.o" -o "$tmp/c" "${l[@]}" "${extra[@]}" 2>"$tmp/err"; then
    fail "memprof use $t" "link: $(head -3 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  "$root/bin/llvm-nm" "$tmp/c" | grep -q '_Z5allocm\.memprof\.1' || { fail "memprof use $t" "no context clone"; rm -rf "$tmp"; return; }
  "$root/bin/llvm-nm" "$tmp/c" | grep -q '_Znam12__hot_cold_t' || { fail "memprof use $t" "no hot/cold new"; rm -rf "$tmp"; return; }
  if [ "$(triple_os "$t")" = linux ] && ! "$tmp/c"; then fail "memprof use $t" "fixture exit $? (cold arena check)"; rm -rf "$tmp"; return; fi
  pass "memprof use $t"; rm -rf "$tmp"
}

# check_memprof_strip ROOT TRIPLE — without -supports-hot-cold-new nothing is hinted.
check_memprof_strip() {
  local root="$1" t="$2" tmp f=()
  tmp="$(mktemp -d)"; mapfile -t f < <(memprof_use_flags)
  "$root/bin/llvm-profdata" merge "$ROOT_DIR/tests/fixtures/memprof-ctx.yaml" -o "$tmp/p.memprofdata"
  "$root/bin/$t-clang++" "${f[@]}" -fmemory-profile-use="$tmp/p.memprofdata" -c "$ROOT_DIR/tests/fixtures/memprof-ctx.cc" -o "$tmp/c.o"
  printf 'extern "C" bool elide_hotcold_is_cold(const void*){return false;}\n' > "$tmp/s.cc"
  "$root/bin/$t-clang++" "${f[@]}" -fuse-ld=lld "$tmp/c.o" "$tmp/s.cc" -o "$tmp/c" 2>/dev/null
  if "$root/bin/llvm-nm" "$tmp/c" 2>/dev/null | grep -q hot_cold; then fail "memprof strip $t" "hints without -supports-hot-cold-new"; else pass "memprof strip $t"; fi
  rm -rf "$tmp"
}

check_memprof_absent() {
  local root="$1" t="$2"
  memprof_supported "$t" && return 0
  if ls "$root/lib/clang/$LLVM_MAJOR/lib/$t"/libclang_rt.memprof* >/dev/null 2>&1; then
    fail "memprof absent $t" "unexpected memprof runtime"; else pass "memprof absent $t"; fi
}
```
Wire into `run_all_checks` inside the triple loop: `check_memprof_runtime`, `check_memprof_use`, `check_memprof_absent`; and once per host (first triple): `check_memprof_strip`.

- [ ] **Step 3: Run** `./build.sh --only 90-package && ./build.sh --only 95-verify` on linux-amd64. Expected: `ok memprof runtime x86_64-unknown-linux-gnu`, `ok memprof use …` for both triples, `ok memprof strip …`, and on linux-arm64 `ok memprof absent …`.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/memprof.cc tests/fixtures/memprof-ctx.cc tests/fixtures/memprof-ctx.yaml scripts/verify/checks.sh
git commit -m "verify: MemProf runtime, profile use, hint stripping and allocator shim"
```

---

## Phase C — DeduBB

### Task 7: Vendor the DeduBB CodeGen + lld patch (with the inertness gate)

**Files:**
- Create: `src/patches/llvm/0100-dedubb-codegen.patch`
- Modify: `docs/notes/llvm-patches.md`

**Interfaces:**
- Produces: hidden LLVM option `-dedubb-directives=<file>`; passes `DeduBB`/`DeduBBCallReturn`; `.text.dedubb` output-section prefix in lld; `TargetInstrInfo::supportsDeduBB()` hooks (X86 full, AArch64 Tail Call). Consumed by Tasks 9, 10.

- [ ] **Step 1: Fetch the pinned upstream patch**

```bash
S=$(mktemp -d)
git clone -q https://github.com/chaitanyaupp18/DeduBB.git "$S/dedubb"
git -C "$S/dedubb" checkout -q 07d730dab798a18440cd7b6ecca103794a86dfc2
cp "$S/dedubb/patches/llvm-project-dedubb.patch" "$S/orig.patch"
```

- [ ] **Step 2: Build a scratch tree of the touched files at 23.1.2 and apply**

```bash
mkdir -p "$S/t" && cd "$S/t"
grep '^diff --git' ../orig.patch | awk '{print substr($3,3)}' | sort -u | while read -r f; do
  [ -f "$OLDPWD/llvm/$f" ] && { mkdir -p "$(dirname "$f")"; cp "$OLDPWD/llvm/$f" "$f"; }; done
git init -q . && git add -A && git commit -qm base
git apply ../orig.patch          # expect: clean, X86InstrInfo.cpp offset ~70 (research notes §2.3)
```

- [ ] **Step 3: Apply the inertness gate.** In `llvm/lib/CodeGen/UnreachableBlockElim.cpp`, change the patched condition so it only differs from upstream when directives exist:

```cpp
    if (!Reachable.count(&BB) &&
        !(BB.hasAddressTaken() && !DeduBBDirectives::get().empty())) {
```
and add `#include "llvm/CodeGen/DeduBBDirectives.h"` to that file's includes.

- [ ] **Step 4: Regenerate the vendored patch with provenance**

```bash
git add -A
{ echo "# requires: LLVM_DEDUBB"
  echo "# upstream: https://github.com/chaitanyaupp18/DeduBB/blob/07d730dab798a18440cd7b6ecca103794a86dfc2/patches/llvm-project-dedubb.patch"
  echo "#   base llvm/llvm-project@333edde4e80e (ancestor of llvmorg-23.1.2); Apache-2.0 WITH LLVM-exception"
  echo "# local: rebased to llvmorg-23.1.2; UnreachableBlockElim change gated on non-empty -dedubb-directives"
  git diff --cached HEAD; } > "$OLDPWD/src/patches/llvm/0100-dedubb-codegen.patch"
cd "$OLDPWD"
```

- [ ] **Step 5: Validate on a scratch LLVM build (one-off, ~15 min on 32 cores)**: build `llc FileCheck not split-file` from a scratch copy of `llvm/llvm` + `cmake` + `third-party` + `libc` with `0100` applied, `-DLLVM_TARGETS_TO_BUILD="X86;AArch64" -DLLVM_INCLUDE_TESTS=OFF`. Run the six `llvm/test/CodeGen/{X86,AArch64}/dedubb*.ll` RUN lines with `%s`/`%t` substituted and `bin/` on `PATH`, plus the 40 `test/CodeGen/X86/*.ll` files that mention `blockaddress` or BB address maps.
Expected: 6/6 and 40/40 pass. This reproduces E9 with the gate added.

- [ ] **Step 6: Full bundle build**: `./build.sh --from 10-llvm-stage1` (Linux) and the darwin CI job. Expected: both build. `bash tests/stages/40-llvm-stage2.check.sh` passes. `clang -mllvm -dedubb-directives=/dev/null -c hello.c` is accepted (an empty directive file is valid).

- [ ] **Step 7: Ledger + commit**

```bash
git add src/patches/llvm/0100-dedubb-codegen.patch docs/notes/llvm-patches.md
git commit -m "llvm: vendor DeduBB CodeGen+lld patch (07d730d), inert without directives"
```

---

### Task 8: Vendor the DeduBB BOLT pass

**Files:**
- Create: `src/patches/llvm/0101-dedubb-bolt.patch`
- Modify: `docs/notes/llvm-patches.md`, `tests/stages/40-llvm-stage2.check.sh`

**Interfaces:**
- Produces: `llvm-bolt --dedubb` and the options listed in spec §4.3. Consumed by Task 10.

- [ ] **Step 1:** Same procedure as Task 7 Steps 1–2 and 4, from branch `bolt-dedubb` @ `0e20b1fed23c693cd453e4dad7d72fa7b48c8ddc`, file `patches/llvm-project-bolt-dedubb.patch` (expected: clean, `BinaryFunction.h` offset 15). Header first line: `# requires: LLVM_DEDUBB_BOLT`. No local changes. Confirm it touches only `bolt/` (disjoint from 0100): `grep '^diff --git' src/patches/llvm/0101-*.patch | grep -v ' a/bolt/'` prints nothing.

- [ ] **Step 2: Stage check** (`tests/stages/40-llvm-stage2.check.sh`, Linux):

```bash
if is_yes "$LLVM_DEDUBB_BOLT"; then
  assert_contains "$("$BUNDLE_DIR/bin/llvm-bolt" --help-hidden 2>&1)" "--dedubb" "llvm-bolt has DeduBB"
fi
```

- [ ] **Step 3: Build** `./build.sh --from 40-llvm-stage2 --only 40-llvm-stage2` and run the check → pass.

- [ ] **Step 4: Commit**

```bash
git add src/patches/llvm/0101-dedubb-bolt.patch docs/notes/llvm-patches.md tests/stages/40-llvm-stage2.check.sh
git commit -m "llvm: vendor DeduBB BOLT pass (bolt-dedubb 0e20b1f) behind LLVM_DEDUBB_BOLT"
```

---

## Phase D — Contract, verification, packaging

### Task 9: Helper `elide-toolchain flags`

**Files:**
- Modify: `src/elide-toolchain`
- Modify: `tests/unit/helper.test.sh`

**Interfaces:**
- Produces: `elide-toolchain flags --target T MODE [--format sh|github|json]`, where MODE ∈ `memprof-instrument`, `memprof-use=FILE`, `dedubb-baseline`, `dedubb-apply=FILE`, `bolt-dedubb`. Emits `ELIDE_CFLAGS`, `ELIDE_CXXFLAGS`, `ELIDE_LDFLAGS`, `ELIDE_RUSTFLAGS` through the existing `add`/`emit` helpers. Errors: `memprof-instrument` on a triple without the runtime ("memprof runtime is x86_64-unknown-linux-gnu only; collect there and use the profile on $T"); `dedubb-*` on darwin; `bolt-dedubb` off x86_64 Linux.

- [ ] **Step 1: Failing tests** (`tests/unit/helper.test.sh`, using its fake-bundle fixture):

```bash
out="$("$fake/bin/elide-toolchain" flags --target x86_64-unknown-linux-gnu memprof-use=/p/app.memprofdata)"
assert_contains "$out" "-fmemory-profile-use=/p/app.memprofdata"
assert_contains "$out" "-Wl,-mllvm,-supports-hot-cold-new"
assert_contains "$out" "-lmimalloc-hotcold -lmimalloc"
assert_contains "$out" "ELIDE_RUSTFLAGS='-Clinker-plugin-lto"
out="$("$fake/bin/elide-toolchain" flags --target x86_64-unknown-linux-musl memprof-use=/p/a)"
assert_not_contains "$out" "-lmimalloc "
assert_fails "$fake/bin/elide-toolchain" flags --target aarch64-unknown-linux-gnu memprof-instrument
assert_fails "$fake/bin/elide-toolchain" flags --target arm64-apple-darwin dedubb-baseline
out="$("$fake/bin/elide-toolchain" flags --target x86_64-unknown-linux-gnu dedubb-apply=/d/x.txt)"
assert_contains "$out" "-Wl,-mllvm,-dedubb-directives=/d/x.txt"
assert_contains "$out" "-Wl,--lto-basic-block-address-map"
```

- [ ] **Step 2: Implement** `cmd_flags` in POSIX sh with the exact flag sets from spec §3.5, §3.6, §4.4:
  - `memprof-instrument`: CFLAGS `-fmemory-profile -gmlt -fdebug-info-for-profiling -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -fno-optimize-sibling-calls -fno-pie`; LDFLAGS `-fmemory-profile -no-pie -Wl,-z,noseparate-code -Wl,--build-id`; RUSTFLAGS `-Cpasses=memprof-module,function(memprof) -Cforce-frame-pointers=yes -Cdebuginfo=line-tables-only -Crelocation-model=static -Clink-arg=-fmemory-profile -Clink-arg=-no-pie -Clink-arg=-Wl,--build-id` (the README marks the Rust part experimental).
  - `memprof-use=F`: CFLAGS `-flto=thin -gmlt -fdebug-info-for-profiling -fmemory-profile-use=F`; LDFLAGS `-flto=thin -fuse-ld=lld -Wl,-mllvm,-enable-memprof-context-disambiguation -Wl,-mllvm,-optimize-hot-cold-new -Wl,-mllvm,-supports-hot-cold-new -lmimalloc-hotcold` + (`gnu`: `-lmimalloc`); RUSTFLAGS `-Clinker-plugin-lto -Clink-arg=-fuse-ld=lld` + each LDFLAG as `-Clink-arg=`.
  - `dedubb-baseline`: CFLAGS `-flto=thin -fbasic-block-address-map`; LDFLAGS `-flto=thin -fuse-ld=lld -Wl,--lto-basic-block-address-map -Wl,-z,keep-text-section-prefix`; RUSTFLAGS `-Clinker-plugin-lto` + link args.
  - `dedubb-apply=F`: baseline + LDFLAGS `-Wl,-mllvm,-dedubb-directives=F`.
  - `bolt-dedubb`: LDFLAGS `-Wl,--emit-relocs`; prints a comment line with the `llvm-bolt … --dedubb` command.

- [ ] **Step 3:** `tests/run.sh helper` → pass; `shellcheck -s sh src/elide-toolchain` clean.

- [ ] **Step 4: Commit**

```bash
git add src/elide-toolchain tests/unit/helper.test.sh
git commit -m "feat(helper): 'flags' prints MemProf and DeduBB consumer flags"
```

---

### Task 10: DeduBB verification checks

**Files:**
- Create: `tests/fixtures/dedubb/a.c`, `tests/fixtures/dedubb/b.c`, `tests/fixtures/dedubb/directives.txt`
- Modify: `scripts/verify/checks.sh`

**Interfaces:**
- Produces: `check_dedubb_codegen ROOT TRIPLE`, `check_dedubb_inert ROOT TRIPLE`, `check_dedubb_bolt ROOT TRIPLE`.

- [ ] **Step 1: Fixtures.** Two single-block functions in two TUs (cross-module Tail Call fold of BB 0, mirroring `llvm/test/CodeGen/X86/dedubb.ll` from the patch):

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
`tests/fixtures/dedubb/directives.txt`
```
m a.c
f master_fn
bbm 0 (DeduBB.master.0)
m b.c
f fold_fn
bbf 0 (DeduBB.master.0)
```
Expected program output: `32`.

- [ ] **Step 2: Checks**

```bash
dedubb_build() { # ROOT TRIPLE OUT [extra link flags...]
  local root="$1" t="$2" out="$3"; shift 3
  "$root/bin/$t-clang" -O2 -flto=thin -fbasic-block-address-map -fuse-ld=lld \
    -Wl,--lto-basic-block-address-map -Wl,-z,keep-text-section-prefix \
    "$ROOT_DIR/tests/fixtures/dedubb/a.c" "$ROOT_DIR/tests/fixtures/dedubb/b.c" -o "$out" "$@"
}

check_dedubb_codegen() {
  local root="$1" t="$2" tmp dis st=()
  [ "$(triple_os "$t")" = linux ] && is_yes "${LLVM_DEDUBB:-yes}" || return 0
  [ "$(triple_libc "$t")" = musl ] && st=(-static)
  tmp="$(mktemp -d)"
  if ! dedubb_build "$root" "$t" "$tmp/app" "${st[@]}" -Wl,-mllvm,-dedubb-directives="$ROOT_DIR/tests/fixtures/dedubb/directives.txt" 2>"$tmp/err"; then
    fail "dedubb codegen $t" "$(head -3 "$tmp/err")"; rm -rf "$tmp"; return
  fi
  dis="$("$root/bin/llvm-objdump" -d --no-show-raw-insn "$tmp/app")"
  if ! grep -q '<DeduBB.master.0>:' <<< "$dis" || ! awk '/<fold_fn>:/{f=1;next} f&&/^$/{exit} f' <<< "$dis" | grep -Eq '(jmp|b)[[:space:]].*<DeduBB.master.0>'; then
    fail "dedubb codegen $t" "fold_fn does not branch to DeduBB.master.0"; rm -rf "$tmp"; return
  fi
  [ "$("$tmp/app")" = 32 ] || { fail "dedubb codegen $t" "wrong output"; rm -rf "$tmp"; return; }
  pass "dedubb codegen $t"; rm -rf "$tmp"
}

check_dedubb_inert() {
  local root="$1" t="$2" tmp
  [ "$t" = x86_64-unknown-linux-gnu ] || return 0
  tmp="$(mktemp -d)"
  dedubb_build "$root" "$t" "$tmp/a1" && dedubb_build "$root" "$t" "$tmp/a2"
  if ! cmp -s "$tmp/a1" "$tmp/a2" || "$root/bin/llvm-nm" "$tmp/a1" | grep -q 'DeduBB\.'; then
    fail "dedubb inert $t" "non-deterministic or DeduBB symbols without directives"
  else pass "dedubb inert $t"; fi
  rm -rf "$tmp"
}

check_dedubb_bolt() {
  local root="$1" t="$2" tmp
  case "$t" in x86_64-unknown-linux-*) ;; *) return 0 ;; esac
  is_yes "${LLVM_DEDUBB_BOLT:-yes}" || return 0
  tmp="$(mktemp -d)"
  dedubb_build "$root" "$t" "$tmp/app" -Wl,--emit-relocs || { fail "dedubb bolt $t" "link"; rm -rf "$tmp"; return; }
  if ! "$root/bin/llvm-bolt" "$tmp/app" -o "$tmp/app.bolt" --dedubb >"$tmp/log" 2>&1; then
    fail "dedubb bolt $t" "$(tail -3 "$tmp/log")"; rm -rf "$tmp"; return
  fi
  [ "$("$tmp/app.bolt")" = 32 ] || { fail "dedubb bolt $t" "wrong output"; rm -rf "$tmp"; return; }
  if ! "$root/bin/llvm-readelf" -lW "$tmp/app.bolt" | grep -E 'GNU_STACK' | grep -q 'RW '; then
    fail "dedubb bolt $t" "PT_GNU_STACK lost its non-executable marking (spec risk 2)"; rm -rf "$tmp"; return
  fi
  pass "dedubb bolt $t"; rm -rf "$tmp"
}
```
Wire all three into `run_all_checks`' triple loop.

- [ ] **Step 3: Run** stage 95 on linux-amd64 and linux-arm64. Expected: `ok dedubb codegen` for all four Linux triples (aarch64 via Tail Call), `ok dedubb inert`, and `ok dedubb bolt` for the two x86_64 triples. If `dedubb bolt` fails only on the GNU_STACK assertion, record the BOLT flags that keep NX (try `--use-gnu-stack=0`) in the README and in this check, and tell the user. Do not drop the assertion.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/dedubb scripts/verify/checks.sh
git commit -m "verify: DeduBB CodeGen fold, inertness and BOLT pass"
```

---

### Task 11: Manifest feature block

**Files:**
- Modify: `scripts/gen-manifest.py`, `tests/unit/manifest.test.sh`, `scripts/verify/checks.sh` (`check_manifest`)

**Interfaces:**
- Produces in `manifest.json`:

```json
"features": {
  "memprof": { "runtimeTargets": ["x86_64-unknown-linux-gnu"], "hotColdLib": "libmimalloc-hotcold.a",
               "backports": ["llvm/llvm-project#222126", "llvm/llvm-project#208911"] },
  "dedubb":  { "codegen": true, "bolt": true, "propellerTool": false,
               "source": "chaitanyaupp18/DeduBB@07d730d (codegen), @0e20b1f (bolt)" }
}
```
Values derive from `memprof_supported` over the bundle triples, the knobs, and the presence of `src/patches/llvm/01*.patch` and (phase 2) `bin/generate_propeller_profiles`.

- [ ] **Step 1:** test first (`manifest.test.sh` asserts the keys for a fake linux-amd64 bundle and that darwin has `runtimeTargets: []`); **Step 2:** implement; **Step 3:** `tests/run.sh manifest` passes; **Step 4: commit** `feat(manifest): advertise MemProf and DeduBB features`.

---

### Task 12 (phase 2): `generate_propeller_profiles` with DeduBB

**Files:**
- Rewrite: `src/patches/llvm-propeller/0001-find-package-llvm.patch`
- Delete: `src/patches/llvm-propeller/0002-mccontext-asminfo-pointer.patch` (pinned `ddfb8b7` already uses the reference API; the patch fails in both directions)
- Create: `src/patches/llvm-propeller/0003-dedubb.patch`
- Create: `scripts/stages/45-propeller.sh`, `tests/stages/45-propeller.check.sh`
- Modify: `versions.env` (pins + sha256 for abseil, protobuf, googletest, quipper archives as referenced by propeller's `CMake/*`)
- Modify: `scripts/verify/checks.sh` (`check_propeller_tool`)

**Interfaces:**
- Produces: `bin/generate_propeller_profiles` (Linux bundles). Static against the gnu 2.34 sysroot and static libc++; links the stage-2 LLVM libraries via `find_package(LLVM)` (requires stage 40 to install LLVM's CMake package and static libs, or point at the stage-2 build tree).

- [ ] **Step 1: Rebase `0001-find-package-llvm.patch`** onto `ddfb8b7`'s `CMake/LLVM/LLVM.cmake`, which now starts with `set(_LLVM_HASH db9b595ae3b3…)`. Keep the two modes (external `LLVM_DIR` vs download) from the old patch.
- [ ] **Step 2: Rebase DeduBB's Propeller patch** (DeduBB `main`, `patches/llvm-propeller-dedubb.patch`, base `e2c7049`). Expected conflicts (dry run, research notes §2.4): the include block of `propeller/generate_propeller_profiles.cc` and one hunk in `propeller/profile_generator.cc`. Fix by hand, regenerate with a provenance header.
- [ ] **Step 3: Pre-fetch deps** into `out/cache/propeller-deps/` with sha256 verification, and point propeller's `*_download_url` variables at `file://` URLs. The build must not touch the network after stage 00.
- [ ] **Step 4: Stage 45** (Linux, `stage_applies` linux): `apply_patches llvm-propeller "$ROOT_DIR/llvm-propeller"`; configure with stage-1 clang via the gnu cfg, `-DLLVM_DIR=<stage-2 build>/lib/cmake/llvm`, `-DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++`-equivalent for libc++ (`-stdlib=libc++ -static-libstdc++` maps to static libc++ with clang); build target `generate_propeller_profiles`; install into `bin/`.
- [ ] **Step 5: Check**: `generate_propeller_profiles --binary=<dedubb fixture built with dedubb_build> --dedubb_profile=out.txt` produces at least one `bbm` and one `bbf` line naming `master_fn`/`fold_fn`. The glibc-floor check covers the new binary.
- [ ] **Step 6: Commit** `feat: stage 45 builds generate_propeller_profiles with DeduBB (phase 2)`.

---

### Task 13: README, full build, CI

**Files:**
- Modify: `README.md`, `docs/superpowers/specs/2026-10-04-universal-native-toolchain-design.md` (bundle layout §2 lists the new files; stage table mentions memprof and patches)

- [ ] **Step 1: README**: new section "Memory profiling (MemProf)" and "Code-size deduplication (DeduBB)". Cover: the per-triple support matrix (spec §1.2), the `elide-toolchain flags` modes, the end-to-end recipes from spec §3.5/§3.6/§4.4, the PGO ordering from spec §5, and the caveats (MemProf hints need ThinLTO + `-lmimalloc-hotcold`; dynamic musl forwards; never profile DeduBB/BOLT binaries; BOLT NX-stack caveat; content-hash profile and directive names because of caches; GraalVM limits).
- [ ] **Step 2: Full build on all three CI hosts** (`on.pr.yml`). Expected: green, including the new checks; darwin passes `check_memprof_use` (link-only) and skips DeduBB.
- [ ] **Step 3: Consumer trial (gate before enabling in a release)**: build one real consumer (WHIPLASH's C++ parts or Komodo) through both routes. Record `.text` deltas, a benchmark run, and an exception/unwind smoke test through folded code in `docs/notes/memprof-dedubb-trial.md`.
- [ ] **Step 4: Commit** `docs: MemProf and DeduBB usage; bundle layout update`.

---

## Out of scope for this plan (tracked follow-ups)

- aarch64/darwin MemProf runtime; musl memprof runtime (blocked on the dynamic-musl side finding, research notes §4).
- Hinting `malloc`/Rust allocations; any rustc changes.
- DeduBB'ing the bundle's own clang (`CLANG_DEDUBB_DIRECTIVES`).
- Fixing dynamic musl with mimalloc-in-libc (separate bug; see research notes §4).
