# Propeller, DeduBB, MemProf and the elidealloc shim — Design

**Date:** 2026-10-05 (revised the same day after user decisions)
**Status:** Draft for review
**Builds on:** `docs/superpowers/specs/2026-10-04-universal-native-toolchain-design.md` (binding; "the base spec" below)
**Evidence:** `docs/notes/memprof-dedubb-research.md` (sources, file:line, experiments E1–E24). Claims marked *(unverified)* there are uncertain here too.
**LLVM patch tracking:** [elide-dev/toolchain#4](https://github.com/elide-dev/toolchain/issues/4) (source text: `docs/notes/llvm-backports-issue.md`)

## 1. Intent

Ship four things in the elide-toolchain bundles (LLVM 23.1.2) so downstream projects
(Elide/WHIPLASH, Bali/crema-jit, Komodo) can turn them on in their own builds:

1. **Propeller, revived**: `generate_propeller_profiles` from the `llvm-propeller` submodule,
   built against the bundle's own LLVM and shipped in `bin/` on Linux. It is the profile tool for
   basic-block layout (Propeller proper) and the directive generator DeduBB needs.
2. **DeduBB**: LCTES '26 post-link basic-block deduplication
   (<https://dl.acm.org/doi/10.1145/3814943.3816169>, code at
   <https://github.com/chaitanyaupp18/DeduBB>), delivered **through the compiler + Propeller
   path only**: vendored LLVM CodeGen+lld patch, applied by default and inert without a
   directive file, plus the DeduBB extension of `generate_propeller_profiles`.
3. **`libelidealloc-shim`**: a first-class, allocator-agnostic component in every sysroot. It turns
   compiler-provided allocation hints into heap partitions through a small backend interface
   (mimalloc is backend #1, selected at build time): today MemProf's
   hot/cold `operator new` hints, tomorrow LLVM allocation tokens (`-fsanitize=alloc-token`),
   behind an interface designed now so the token work does not break consumers.
4. **MemProf**: the compiler-rt runtime (x86_64 gnu) and two upstream backports. MemProf's
   hints act through the shim.

### 1.1 What "DeduBB" refers to

*"DeduBB: Binary Code Size Reduction via Post-Link Basic Block Deduplication"*, by Mamatha
Ananda, Afarin, Gupta (UC Riverside) and Tallam, Shen, Li (Google, the Propeller authors).
**Confidence: high** (exact name; it is an LLVM patch wired in through build flags; it is built
on Propeller). Not upstream anywhere: no PR, issue or RFC. Research notes §2.1 lists the
rejected candidates.

### 1.2 Verdict

| | Propeller | DeduBB | elidealloc shim | MemProf |
|---|---|---|---|---|
| State in 23.1.2 / today | Compiler side upstream (`-fbasic-block-address-map`, `-fbasic-block-sections=list=`, lld `--lto-basic-block-*`). The tool is not built: no recipe, and `src/patches/llvm-propeller/*` are stale | Not upstream | Doesn't exist. mimalloc 3.5.4 has the needed heap/arena API | Compiler side complete and working (E3, E10). Runtime x86_64-Linux-only upstream and not built |
| Feasibility evidence | **Spike: pinned propeller builds unmodified against our stage-2 LLVM 23.1.2** with a find_package CMake module; `libelf` is the only missing dependency (E22) | LLVM patch: clean apply, compiles, 6/6 lit tests (E9). Propeller patch: 3 mechanical fixes, builds, **emits correct directives** (E23, E24) | Prototype with a cold heap works on gnu and musl static (E14). Hot/cold + token composition confirmed at the IR/link level (E21) | End to end on gnu x86_64 with a scratch runtime (E8, E10, E18) |
| Ships | `bin/generate_propeller_profiles` (Linux bundles) | Patched clang/lld (default on, inert); DeduBB flags in `generate_propeller_profiles` | `libelidealloc-shim.a` + `elidealloc-shim.h` in every sysroot | `libclang_rt.memprof*` for `x86_64-unknown-linux-gnu` |
| Triples that benefit | x86_64 Linux (LBR); aarch64 Linux via SPE *(unverified)*; darwin none (ELF only) | x86_64 Linux (all strategies); aarch64 Linux (Tail Call only); darwin none | All (darwin forwards only, §5.6) | Profile on x86_64 gnu; use on every triple |
| Rust | Linker-plugin-LTO Rust code is laid out like C/C++ | Same (codegen happens in lld) | Rust `__rust_alloc` is never hinted or tokenized | Only through linker-plugin LTO with C++ (E16) |
| GraalVM native-image | Java code: no (Graal's own backend) | no | JNI/C parts only | JNI/C parts only |

## 2. Decisions

| # | Topic | Decision | Why |
|---|---|---|---|
| D1 | LLVM patch carrier | `src/patches/llvm/NNNN-*.patch`, applied with `apply_patches llvm "$ROOT_DIR/llvm"` at the top of stages 10, 30 and 40 (idempotent; `--from` resumes work). Stage 00 first calls a new `unapply_patches` for `glibc`, `llvm`, `llvm-propeller`, because its clean-tree check (`check_submodules`) would otherwise die on our own patches after the first build | Same mechanism glibc uses. CI resets submodule work trees before each build (`job.build.yml:73-75`) |
| D2 | Patch hygiene | One self-contained file per feature or backport. **No two patches overlap hunks** (`apply_patches` detects "already applied" with `git apply --reverse --check`). Local fixups are folded into the vendored file with a provenance header. Optional `# requires: VAR` first line gates a patch on a `vars.sh` knob | Re-runs stay no-ops (unit test) |
| D3 | Backports | `0001` = llvm/llvm-project#222126 (`8c7d76bfc1b5`, deterministic MemProf clone tie-break), `0002` = #208911 (`c0b8c59b65af`, memprof histogram tail granule). **Accepted; tracked in [elide-dev/toolchain#4](https://github.com/elide-dev/toolchain/issues/4)** (source text `docs/notes/llvm-backports-issue.md`) | Reproducible MemProf builds; correct histogram profiles |
| D4 | Propeller pin | Keep `llvm-propeller` at `ddfb8b7cbdb8`, which is upstream HEAD (2026-09-24). Bump only through `scripts/bump-submodules.sh` and re-run the stage 45 check | It already builds against 23.1.2 (E22). Pinning to a tag isn't possible: upstream has none |
| D5 | Propeller patches | Replace the stale set. `0001-find-package-llvm.patch`: rewrite `CMake/LLVM/LLVM.cmake` to `find_package(LLVM CONFIG)` (spike version). `0002-quipper-libelf-to-llvm-object.patch`: replace quipper's libelf build-id reader with LLVM `Object`. `0003-offline-deps.patch`: point the abseil/protobuf/googletest/quipper download URLs at a verified local cache. `0004-dedubb.patch`: DeduBB's Propeller patch rebased (§4.2). Delete the old `0002-mccontext-asminfo-pointer.patch` (obsolete for 23.x) | No libelf in our sysroots, and shipping a static LGPL libelf (elfutils builds only with GCC) is worse than a ~100-line rewrite onto LLVM `Object`, which we already link. Builds must not hit the network after stage 00 |
| D6 | Where Propeller builds | New Linux-only stage **`45-propeller`**, after `40-llvm-stage2`, linking the **stage-2 build tree's** static LLVM libraries (`out/<host>/build/llvm-stage2/lib/cmake/llvm`). Compiled with the stage-1 gnu cfg compiler (glibc 2.34 sysroot, static libc++), so the tool meets the glibc floor. Not on darwin | Spike configuration (E22). Stage 40 never wipes its build dir except on rerun, and 45 must run after it. `--from 45` requires an intact stage-40 build dir (checked) |
| D7 | Propeller deps | abseil `20260107.1`, protobuf `33.4`, googletest (version from propeller's `CMake/Googletest`), quipper `f9eb05fcce80`. Each archive is pinned with sha256 in `versions.env` and fetched by stage 00 into `out/cache/propeller-deps/` | Offline, reproducible builds. Same pattern as the kernel tarball |
| D8 | DeduBB carrier | `src/patches/llvm/0100-dedubb-codegen.patch`: DeduBB `main` @ `07d730dab798`'s LLVM patch rebased to 23.1.2 (one offset), plus a local gate that makes the `UnreachableBlockElim` change apply only with directives. **Applied by default** (`LLVM_DEDUBB=yes`; header `# requires: LLVM_DEDUBB`). The `bolt-dedubb` BOLT pass is **not** carried (§4.5) | User decision. Inert by default (`check_dedubb_inert`) |
| D9 | Shim name and shape | **`libelidealloc-shim.a`**, header **`elidealloc-shim.h`**, pkg-config `elidealloc-shim`, C API prefix `elidealloc_`, env prefix `ELIDEALLOC_`, versioned by `ELIDEALLOC_ABI_VERSION`. **Allocator-agnostic**: a frontend (hint/token policy, public ABI) over a small build-time-selected backend interface (§5.2a). Backend #1 = mimalloc (`ELIDEALLOC_BACKEND=mimalloc`), plus a `forward` backend (libc `malloc`). Built for every triple in stage 35, after mimalloc/musl phase 2. Fat ThinLTO objects (base spec §3.3a) | The name doesn't tie the ABI to mimalloc, so we can swap the allocator later without renaming anything consumers see |
| D10 | Heap mapping | Three temperature partitions: **default** (mimalloc's main heap, which plain `malloc`/`new` already use), **hot**, **cold**. Each non-default partition is a mimalloc first-class heap bound to its own exclusive arena. Hint → partition: `hint ≤ 63` cold, `hint ≥ 240` hot, otherwise default (thresholds overridable). LLVM's hints are cold=1, notcold=128, ambiguous=222, hot=254. **222 (ambiguous) stays in default** | User decision: hot and cold both segregated. Ambiguous means the profile saw both hot and cold contexts that cloning could not separate; routing it to the hot heap would mix cold objects into the hot partition and dilute its locality, while the default heap keeps stock allocator behaviour. Thresholds stay tunable via `ELIDEALLOC_COLD_MAX`/`ELIDEALLOC_HOT_MIN` |
| D11 | Token readiness | Token entry points (`__alloc_token_*`, default ABI and fast ABI) live in a **separate archive member** of the same library, so they are linked only when referenced. Partition key = `(token class, temperature)`; v1 ships class 0 only. Adding token classes later changes neither v1 symbols nor behaviour for non-token builds | Consumers that never use tokens can't observe the change (§5.4) |
| D12 | Shim per libc (mimalloc backend) | gnu: strong `mi_*` references, link with `-lmimalloc` (`MI_OVERRIDE=ON`). musl (static-only downstream): `mi_*` come from `libc.a`'s single `mimalloc.o`, so there is one mimalloc instance; never link a second mimalloc. If musl is built with `MUSL_USE_MIMALLOC=no`, the shim uses the `forward` backend. darwin: `forward` backend (static mimalloc doesn't override `free` there) | §5.5 |
| D13 | MemProf runtime scope | `compiler-rt` memprof only for `x86_64-unknown-linux-gnu` (stage 30 pass 2: `COMPILER_RT_BUILD_MEMPROF=ON`, `SANITIZER_CXX_ABI=none`, `CMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld -rtlib=compiler-rt -unwindlib=none"`, E8). Not musl (runtime refuses static linking, `memprof_rtl.cpp:181`), aarch64 or darwin (unsupported upstream) | Profiles from gnu x86_64 apply to every triple (E13) |
| D14 | Downstream contract | Helper `elide-toolchain flags --target T <mode>` printing `ELIDE_CFLAGS/LDFLAGS/RUSTFLAGS` for `propeller-baseline`, `propeller-use=<cc>,<ld>`, `dedubb-apply=<file>`, `memprof-instrument`, `memprof-use=<file>` | The base spec makes the helper the stable contract (§5.3) |

## 3. Propeller

### 3.1 Upstream status

The compiler and linker side is in 23.1.2: `-fbasic-block-address-map` (ELF only, E19),
`-fbasic-block-sections=list=<file>`, `-funique-internal-linkage-names`, lld
`--lto-basic-block-address-map`, `--lto-basic-block-sections=<file>`,
`--symbol-ordering-file`, `-z keep-text-section-prefix`. The profile tool is the
`google/llvm-propeller` project. It pins its own LLVM (`db9b595ae3b3`, an ancestor of 23.1.2)
and fetches abseil, protobuf, googletest and quipper at configure time. Our old
`src/patches/llvm-propeller/*` apply to neither the pinned tree nor in reverse.

### 3.2 Spike result (E22–E24)

- `ddfb8b7` with the spike's find_package `LLVM.cmake` against
  `out/linux-amd64/build/llvm-stage2` (read-only), compiled with the stage-1 gnu cfg compiler:
  **all propeller, abseil, protobuf and quipper sources compile unmodified against 23.1.2**.
- Link: everything resolves except `libelf` (host `libelf.a` + `__isoc23_strtol` shim in the
  spike). The binary is 36 MB, max `GLIBC_2.34`, and runs.
- The DeduBB-extended build generates correct directives (§4.2).
- Layout path **without hardware sampling** (E25, E26): on upstream's checked-in fixtures
  (`llvm-propeller/propeller/testdata/sample_with_bb_hash.{bin,perfdata}`), the spike tool's
  cc/ld profiles match upstream's golden `sample_with_bb_hash_cc_directives.golden.txt`, apart
  from the optional `h` (BB hash) lines that golden mode adds. With
  `bimodal_sample_v2.{c,bin,perfdata.1,perfdata.2}`, the generated profiles relinked
  `bimodal_sample_v2.c` **with our clang** (non-LTO via `-fbasic-block-sections=list=` and
  ThinLTO via `--lto-basic-block-sections=`). Evidence: symbol order `main, compute, foo, bar`
  equals the ld profile, `.text.hot` and `.text.split` sections exist, and `main.cold` is in
  `.text.split`.
- Live LBR/SPE recording was not possible here (WSL2), and the CI runners can't do it either (§3.6).

### 3.3 Build (stage 45, Linux)

```
stage 00: fetch propeller deps into out/cache/propeller-deps (sha256 from versions.env)
stage 45: apply_patches llvm-propeller "$ROOT_DIR/llvm-propeller"
          cmake -S llvm-propeller -B build/propeller -G Ninja
            -DCMAKE_CXX_COMPILER=$STAGE1_DIR/bin/<gnu triple>-clang++   (cfg: sysroot, libc++, lld)
            -DLLVM_DIR=$BUILD_DIR/llvm-stage2/lib/cmake/llvm
            -DBUILD_TESTING=OFF
            -DPROPELLER_DEPS_DIR=$CACHE_DIR/propeller-deps                  (0003 patch)
            -DLIBZ_LIBRARIES=<gnu sysroot>/usr/lib/libz.a
            -DLIBCRYPTO_LIBRARIES=<gnu sysroot>/usr/lib/libcrypto.a          (aws-lc)
            -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++ <sysroot>/usr/lib/libzstd.a"
          ninja generate_propeller_profiles   ->  install into $BUNDLE_DIR/bin
```
The target is the gnu triple, so the tool runs on the bundle's own host floor. The same binary
serves both libcs: it reads ELF binaries and perf data, not target libraries. Propeller's unit
tests (`BUILD_TESTING=ON`) run in the stage-45 check, not in packaging.

### 3.3a Verification without branch sampling in CI

The GCE CI runners cannot do branch sampling. c4d (AMD Turin) exposes no PMU to the guest.
c4a (Axion, arm64) allows only PMU STANDARD, only via delete+recreate (local SSDs), and SPE is
unconfirmed. **We are not changing the runners.** So building, shipping and verifying
Propeller must not need LBR or SPE:

1. **Golden fixture (tool correctness).** `generate_propeller_profiles` on
   `sample_with_bb_hash.{bin,perfdata}` from the pinned `llvm-propeller` submodule's
   `propeller/testdata/`. Expected: cc/ld profiles equal upstream's goldens after dropping `h`
   lines. The fixtures ship with the submodule, so the repo checks nothing new in. Upstream
   regenerates them with the tool, so a propeller bump keeps them consistent.
2. **Round-trip fixture (profile → tool → relink → layout evidence).**
   `bimodal_sample_v2.{bin,perfdata.1,perfdata.2}` → cc/ld profiles → compile and relink
   `bimodal_sample_v2.c` with the **bundle's** clang/lld, non-LTO and ThinLTO. Assert: lld's
   symbol order follows the ld profile, `.text.hot` and `.text.split` exist under
   `-z keep-text-section-prefix`, `<fn>.cold` symbols sit in `.text.split`, and the program
   runs. This works because the cc profile names functions and BB IDs, and our clang assigns
   the same IDs to this small source as upstream's compiler did (E26).
   *If an LLVM bump changes BB numbering* (the evidence assertions fail), fall back to our
   own fixture: `tests/fixtures/propeller/` with a source, the labelled binary built by the
   bundle, and a short `perf.data`, recorded **once** on an LBR-capable host using the
   procedure in `docs/notes/propeller-fixtures.md` (perf `-c 100003`, a few seconds, ≤ 2 MB).
3. **Live check (capability-probed, optional).** `check_propeller_live` first probes: x86_64
   `perf record -b -e cycles:u -o <tmp> -- true`; arm64 `perf record -e arm_spe// -o <tmp> -- true`;
   and reports `/proc/sys/kernel/perf_event_paranoid`. If capable, it records the fixture,
   generates profiles, relinks, and checks the same evidence. Otherwise it prints
   `warn "propeller live <triple>: skipped (no LBR/SPE; paranoid=N)"`. **`REQUIRE_LBR=yes`**
   (vars.sh, default `no`) turns the skip into a failure.
4. **Future option (documented, not planned):** the self-hosted runner `sandbox-ci-x86`
   (labels `linux-amd64-bench`, `cloud-latitude`; likely bare-metal Latitude.sh, AMD) may
   support AMD LBRv2/BRS. Once SSH access exists, probe it with item 3's commands. If capable,
   a `REQUIRE_LBR=yes` job there would cover live collection.

**Consumer note:** profile collection (`perf record` with LBR/SPE) is a **consumer-side
step** on the consumer's own perf-capable hosts (bare metal or PMU-passthrough VMs), with
their real workloads. The bundle ships the tool and compiler support. It never collects
profiles itself, and CI does not need to.

### 3.4 What ships

`bin/generate_propeller_profiles` (Linux bundles). The project builds no other executables
at this pin (`propeller/CMakeLists.txt:76`). The manifest records the pin and the patch list.

### 3.5 Downstream workflow (Propeller layout)

```sh
# 1) labelled build (ThinLTO: maps are emitted in the lld LTO backend)
CFLAGS="-flto=thin -funique-internal-linkage-names -fbasic-block-address-map"
LDFLAGS="-flto=thin -fuse-ld=lld -Wl,--lto-basic-block-address-map"
# 2) profile on representative load
perf record -e cycles:u -j any,u -o perf.data -- ./app <workload>        # x86_64 LBR
#    aarch64: ARM SPE, --profile_type=PERF_SPE (unverified)
# 3) convert
generate_propeller_profiles --binary=./app --profile=perf.data \
  --cc_profile=cc.<sha>.txt --ld_profile=ld.<sha>.txt
# 4) optimized relink, same sources and flags otherwise
CFLAGS="-flto=thin -funique-internal-linkage-names"
LDFLAGS="-flto=thin -fuse-ld=lld -Wl,--lto-basic-block-sections=cc.<sha>.txt \
  -Wl,--symbol-ordering-file=ld.<sha>.txt -Wl,--no-warn-symbol-ordering -Wl,-z,keep-text-section-prefix"
```
Non-LTO builds pass `-fbasic-block-sections=list=cc.txt` on every compile instead. Rust
linker-plugin-LTO crates take part automatically (lld does their codegen). `rustc
-Cllvm-args=-basic-block-address-map` emits maps for non-LTO crates (E17), but applying a
cluster file to them needs rustc's own LLVM (out of scope). Content-hash the profile names:
lld's ThinLTO cache key includes `-mllvm`/`--lto-*` strings, not file contents.

## 4. DeduBB (compiler + Propeller)

### 4.1 Upstream status and patch

Not upstream. `0100-dedubb-codegen.patch` (4725 lines; base `llvm/llvm-project@333edde4e80e`,
an ancestor of `llvmorg-23.1.2`) applies cleanly and compiles, and its 6 lit tests pass on a
23.1.2 `llc` together with 40 related X86 tests (E9). Risk: **medium**. It is research
code (one author, unreviewed), but it is defensive: liveness checks on the link register,
skips CFI/EH/inline-asm/red-zone/stack-argument cases, and Save-and-Jump is off under IBT.
Inert without directives once the `UnreachableBlockElim` gate is added (D8). Arch support:
x86-64 all strategies; AArch64 Tail Call only; darwin none.

### 4.2 Propeller-side patch

`src/patches/llvm-propeller/0004-dedubb.patch`: DeduBB `main` @ `07d730d`'s
`patches/llvm-propeller-dedubb.patch` (6567 lines, mostly new files), rebased onto `ddfb8b7`.
The spike needed (E23):
1. the include block of `generate_propeller_profiles.cc` (adds `absl/log/log.h`,
   `absl/strings/str_cat.h`, `absl/strings/string_view.h`, `propeller/tail_call_profile_writer.h`);
2. the new `MiniDisassembler::DisassembleOne(ArrayRef<uint8_t>, uint64_t, uint64_t&)`
   placed before `MayAffectControlFlow`, using `llvm::formatv` like the surrounding code;
3. **dropping** the hunk that changes `MCContext(...)` to pointer arguments (DeduBB's older
   LLVM); 23.1.2 takes references.
Result: builds, and `--dedubb_profile` emits correct directives on fixtures (E24).

### 4.2a DeduBB needs no runtime profile

DeduBB is **static**. `generate_propeller_profiles --binary=<bin> --dedubb_profile=<out>` reads
only the linked binary: its code bytes plus the `.llvm_bb_addr_map` section from
`-fbasic-block-address-map`. It finds identical blocks and runs and writes directives. No
perf data is involved (E24: directives from `--binary` alone). The only profile-dependent
option is the optional `--dedubb_cold_only` (fold only blocks the profile shows never ran),
which takes `--profile`. CI therefore verifies DeduBB **fully** without hardware sampling:
labelled build → directives → relink with `-dedubb-directives` → fold evidence (fold site
branches to `DeduBB.master.N`, master in `.text.dedubb*`) → the program runs correctly.

### 4.3 Downstream workflow

```sh
# 1) baseline = Propeller step 1's labelled build (no profile needed for DeduBB)
LDFLAGS+=" -Wl,-z,keep-text-section-prefix"
# 2) directives (whole program; add --dedubb_cold_only --profile=perf.data to keep hot code intact)
generate_propeller_profiles --binary=./app --dedubb_profile=dedubb.<sha>.txt --dedubb_subsequence
# 3) relink, identical except:
LDFLAGS+=" -Wl,-mllvm,-dedubb-directives=dedubb.<sha>.txt"
```
Combined with Propeller layout: one `generate_propeller_profiles` run with `--profile`,
`--cc_profile`, `--ld_profile`, `--dedubb_profile --dedubb_cold_only`, then one relink that
passes all of them. This is what the DeduBB `performance` branch does *(not reproduced here)*.
Rules: apply only at a final link (`DeduBB.master.N` symbols are global-hidden and would
collide across separately DeduBB'd inputs). Both builds must be bit-identical apart from the
flags. Under ThinLTO only the link step needs the directives. Never collect profiles from a
DeduBB binary.

### 4.4 Build and ship

No CMake options needed. Stages 10/30/40 apply `0100`. Darwin compiles it too (inert; BB
address maps are ELF-only). Shipped: patched clang/lld (hidden `-mllvm -dedubb-directives`,
`.text.dedubb` placement under `-z keep-text-section-prefix`), and the DeduBB flags in
`generate_propeller_profiles` (`--dedubb_profile`, `--dedubb_subsequence`,
`--dedubb_cold_only`, `--dedubb_intra_module_only`, `--dedubb_call_return`, …).

### 4.5 BOLT

The DeduBB authors' `bolt-dedubb` branch implements the same folding as a BOLT pass
(`llvm-bolt --dedubb`). It is **not carried**. It produces larger files (in-place rewrite)
and can drop the `PT_GNU_STACK` NX marking. If wanted later, it applies cleanly to 23.1.2 and
compiles (research notes §2.3), as an experimental opt-in patch.

## 5. `libelidealloc-shim` (first-class allocator component)

### 5.1 Purpose

The compiler can emit two kinds of allocation hint that need a cooperating allocator, and
LLVM ships no runtime for either:
- **MemProf** (23.1.2, ThinLTO): `operator new(size_t, __hot_cold_t)` family, tcmalloc ABI,
  hint 0–255.
- **Allocation tokens** (23.1.2, `-fsanitize=alloc-token`): `__alloc_token_<fn>(…, size_t token)`
  for `malloc`/`calloc`/`realloc`/`aligned_alloc`/`posix_memalign`/`memalign`/`valloc`/`pvalloc`
  and every `operator new` variant, **including the hot/cold ones**. The pass runs after the
  hot/cold rewrite, so both compose into `__alloc_token__Znam12__hot_cold_t(size, hint, token)`
  (E21). Fast ABI: `__alloc_token_<N>_<fn>(…)`.

The shim maps both onto partitioned heaps of the selected backend (mimalloc today). Without it, MemProf links fail (E5) and token builds
fail. With it, hot and cold objects land in separate pages and address ranges.

### 5.2 Heap model

```
partition key  = (token_class, temperature)        token_class ∈ [0, ELIDEALLOC_MAX_CLASSES=16)
temperature    ∈ {DEFAULT, HOT, COLD}               v1: token_class is always 0
(0, DEFAULT)   = mimalloc main heap (what plain malloc / operator new already use): no change
(c, HOT|COLD)  = mi_heap_new_in_arena(arena[c][t]), arena reserved exclusive on first use
(c>0, DEFAULT) = token-class heap (v2), exclusive arena per class
```
- (mimalloc backend) Heaps are mimalloc 3.x first-class heaps: allocate and free from any thread, separate pages
  (`mimalloc.h:233-260`). Arenas: `mi_reserve_os_memory_ex(size, commit=false,
  allow_large=<hot only, opt-in>, exclusive=true)` + `mi_heap_new_in_arena`, so
  `elidealloc_partition_of(p)` is an `mi_arena_contains` lookup.
- Creation is lazy and lock-free (atomic CAS publish; the loser `mi_heap_delete`s its heap).
- Exhaustion: if a partition's arena is full, allocate from `(c, DEFAULT)` (counted in stats).
  OOM keeps C++ semantics (`new_handler` loop, `bad_alloc` or `nullptr` for nothrow) and C
  semantics (`NULL`, `errno=ENOMEM`).
- Free path: unchanged. `free`/`operator delete` → `mi_free`, which handles any heap. On gnu
  this needs `libmimalloc.a` (`MI_OVERRIDE=ON`) to be the process allocator; on musl it is libc's.
- Hint thresholds: `cold ≤ ELIDEALLOC_COLD_MAX (63)`, `hot ≥ ELIDEALLOC_HOT_MIN (240)`. Defaults
  bracket LLVM's 1/128/222/254, so `notcold` (128) and `ambiguous` (222) stay default. Decision
  for 222: ambiguous contexts mixed hot and cold behaviour that cloning couldn't split. Putting
  them in the hot heap would pollute it with cold objects, while the default heap is exactly stock
  behaviour. Revisit only with measurements (env thresholds make that a runtime experiment).
- Configuration: environment, read once at the first hinted allocation: `ELIDEALLOC_COLD_RESERVE_MB`
  (default 256), `ELIDEALLOC_HOT_RESERVE_MB` (256), `ELIDEALLOC_HOT_LARGE_PAGES` (0),
  `ELIDEALLOC_COLD_MAX`, `ELIDEALLOC_HOT_MIN`, `ELIDEALLOC_DISABLE` (1 = forward everything; for A/B
  benchmarking without relinking), `ELIDEALLOC_STATS` (1 = print per-partition counters at exit).
  Programmatic override: `elidealloc_configure(const elidealloc_config*)` before the first allocation.

### 5.2a Backend interface (allocator-agnostic)

The frontend (`core.cc`, `hotcold.cc`, later `token*.cc`) owns policy: hint → temperature,
token → class, OOM semantics, stats, configuration, the public ABI. It never calls an
allocator directly. Allocators sit behind one internal C++ interface, compiled in statically
(no vtable, no runtime switching), chosen by `-DELIDEALLOC_BACKEND_<NAME>` in stage 35:

```cpp
// src/elidealloc-shim/backend.h — internal, not installed, not part of the ABI.
namespace elidealloc::backend {
struct heap;                                            // opaque per-partition handle
// Create a partition heap. reserve_mb: dedicated address range (0 = none); large_pages: hint.
// Returns nullptr if the backend cannot create one (frontend then uses the default heap).
heap*  heap_create(elidealloc_temp t, size_t token_class, size_t reserve_mb, bool large_pages);
void   heap_destroy(heap* h);                           // only for a lost creation race
void*  alloc(heap* h, size_t size, size_t align);       // h == nullptr → default heap; align 0 = natural
void*  realloc(heap* h, void* p, size_t size);          // stays in h when it must move
void   free(void* p);                                   // any pointer from any heap, any thread
size_t usable_size(const void* p);
bool   owns(const heap* h, const void* p);              // for elidealloc_partition_of
void   heap_stats(const heap* h, size_t* committed, size_t* reserved); // best effort, for ELIDEALLOC_STATS
constexpr const char* name = "...";                     // reported by elidealloc_backend_name()
}
```
Backend requirements: partition heaps usable and freeable from any thread; `free` accepts
any pointer the process allocator handed out (the shim never wraps `free`/`operator delete`,
so the backend **must** also be the process allocator, or forward mode is used).

| Backend | Selected when | Mapping |
|---|---|---|
| `mimalloc` (#1) | gnu (with `-lmimalloc`), musl built with `MUSL_USE_MIMALLOC=yes` | `heap_create` = `mi_reserve_os_memory_ex(exclusive)` + `mi_heap_new_in_arena` (fallback `mi_heap_new`); `alloc` = `mi_heap_malloc[_aligned]` / `mi_malloc[_aligned]`; `realloc` = `mi_heap_realloc`; `free` = `mi_free`; `usable_size` = `mi_usable_size`; `owns` = `mi_arena_contains` |
| `forward` | darwin; musl without mimalloc; `ELIDEALLOC_DISABLE=1` at runtime (frontend short-circuit) | `heap_create` → nullptr; everything goes to libc `malloc`/`aligned_alloc`/`realloc`/`free`/`malloc_usable_size` |
| future (e.g. a hardened or partition-native allocator) | new `-DELIDEALLOC_BACKEND_X` | implement the 8 functions; public ABI and env vars unchanged |

`elidealloc_backend_name()` (v1 API) lets consumers and tests see which backend a binary got.

### 5.3 Interface (v1, shipped now)

C++ (tcmalloc-compatible), in the `hotcold.o` archive member:
```cpp
enum class __hot_cold_t : uint8_t {};      // global namespace, mangles as 12__hot_cold_t
void* operator new  (size_t, __hot_cold_t);                               // _Znwm12__hot_cold_t
void* operator new[](size_t, __hot_cold_t);                               // _Znam12__hot_cold_t
void* operator new  (size_t, const std::nothrow_t&, __hot_cold_t) noexcept;
void* operator new[](size_t, const std::nothrow_t&, __hot_cold_t) noexcept;
void* operator new  (size_t, std::align_val_t, __hot_cold_t);
void* operator new[](size_t, std::align_val_t, __hot_cold_t);
void* operator new  (size_t, std::align_val_t, const std::nothrow_t&, __hot_cold_t) noexcept;
void* operator new[](size_t, std::align_val_t, const std::nothrow_t&, __hot_cold_t) noexcept;
```
C API (`elidealloc-shim.h`, `core.o` member):
```c
#define ELIDEALLOC_ABI_VERSION 1
typedef enum { ELIDEALLOC_DEFAULT = 0, ELIDEALLOC_HOT = 1, ELIDEALLOC_COLD = 2 } elidealloc_temp;
typedef struct { size_t cold_reserve_mb, hot_reserve_mb; int hot_large_pages;
                 unsigned cold_max, hot_min; int disable; } elidealloc_config;
int         elidealloc_abi_version(void);                    /* == ELIDEALLOC_ABI_VERSION of the library */
int         elidealloc_configure(const elidealloc_config *c);    /* 0 ok; -1 if heaps already exist */
void       *elidealloc_malloc(size_t size, elidealloc_temp t, size_t token_class);
void       *elidealloc_aligned_alloc(size_t align, size_t size, elidealloc_temp t, size_t token_class);
elidealloc_temp elidealloc_partition_of(const void *p, size_t *token_class_out);
typedef struct { size_t allocs[3], bytes[3], fallbacks; } elidealloc_stats;
void        elidealloc_get_stats(elidealloc_stats *out);         /* relaxed counters, class 0 */
const char *elidealloc_backend_name(void);                   /* "mimalloc" | "forward" | … */
```
Nothing in the public header names the backend's types. `*_reserve_mb` means "dedicated
address range per partition", which any backend can honour or ignore.
`elidealloc_malloc` lets non-C++ code (C, Rust FFI, crema-jit's own allocator paths) pick a
partition explicitly. This is the only way C and Rust allocations can benefit today.

### 5.4 Interface (v2, tokens, designed now, built later)

- New archive members `token.o` (default ABI) and `token_fast.o` (fast ABI, IDs 0–15
  generated by macro). Each defines the `__alloc_token_*` entry points for the libfuncs in
  research notes §1.6: `malloc`, `calloc`, `realloc`, `aligned_alloc`, `posix_memalign`,
  `memalign`, `valloc`, `pvalloc`, `_Znwm`/`_Znam` and their nothrow/aligned variants, the 8
  hot/cold variants (token after the hint), and `__size_returning_new*` if tcmalloc
  compatibility is ever needed.
- Mapping: `token_class = token % elidealloc_token_classes`, where `elidealloc_token_classes` defaults to
  `min(16, ELIDEALLOC_TOKEN_CLASSES)`. Consumers pass `-falloc-token-max=<N>` to match. The
  `typehashpointersplit` mode puts pointer-containing types in the top half, so `N=2` yields
  "pointerful vs pointer-free" isolation. `realloc` keeps the token's class
  (`mi_heap_realloc`).
- Compatibility rules: v1 symbols and semantics never change. v2 only adds members that are
  linked when referenced. `ELIDEALLOC_ABI_VERSION` becomes 2. A consumer built against v1
  headers links against a v2 library unchanged. Token mode is experimental upstream
  (AllocToken.rst), so the shim does not interpret token bits beyond `% classes`.

### 5.5 Per-libc linkage (musl detail)

- **musl (static):** stage 35 links mimalloc into `libc.a` (`mimalloc.o` + glue). `malloc`
  itself is mimalloc's. The shim references `mi_heap_new_in_arena`, `mi_heap_malloc`,
  `mi_reserve_os_memory_ex`, `mi_arena_contains`, …; they resolve from that same member,
  which `malloc` references always pull in. There is one allocator instance and one set of
  arenas. musl's internal allocations (stdio buffers, `getaddrinfo`, …) use the main heap
  (`DEFAULT`). The shim must not be combined with a separately linked `libmimalloc.a` (there
  is none in the musl sysroot; the stage-35 check asserts that). The musl shim is built with
  `-DELIDEALLOC_BACKEND_MIMALLOC`; if `MUSL_USE_MIMALLOC=no`, stage 35 builds it with
  `-DELIDEALLOC_BACKEND_FORWARD` instead (all hints ignored, API returns `DEFAULT`).
- **gnu:** `libmimalloc.a` is a multi-member archive (`heap.c.o`, `arena.c.o`, …), so the shim
  uses strong references, and consumers link `-lelidealloc-shim -lmimalloc`. Without
  `-lmimalloc` the link fails with undefined `mi_*`. That failure is intentional: hinting
  without mimalloc as the process allocator would hand glibc `free` foreign pointers.
- **darwin:** `-DELIDEALLOC_BACKEND_FORWARD`. Static mimalloc doesn't override `free` on macOS.

### 5.6 Build, ship, test

Stage 35, per triple: compile `src/elidealloc-shim/{core,hotcold}.cc` plus the selected backend
`src/elidealloc-shim/backend-{mimalloc,forward}.cc` (v2 adds `token*.cc`) with
the target clang (`-O2 -fPIC -std=c++17 -flto=thin -ffat-lto-objects`), archive into
`<sysroot>/usr/lib/libelidealloc-shim.a`, install `elidealloc-shim.h` and a `elidealloc-shim.pc`.
Tests: `tests/fixtures/elidealloc-shim-test.cc` (all 8 overloads land in the expected partition,
nothrow on absurd sizes returns null, alignment honoured, cross-thread alloc/free, stats,
`ELIDEALLOC_DISABLE=1` forwards, `elidealloc_configure` after first use fails). It runs in the stage-35
check (stage-1 compiler) and in stage 95 against the packaged bundle. darwin runs the
forward-mode variant of the test.

## 6. MemProf

### 6.1 Status and changes

The compiler side works unpatched (§1.2). What we add: backports (D3), the runtime (D13), the
shim (§5). Only `operator new` call sites are hinted (`MemProfUse.cpp:182-205`). C `malloc`
and Rust allocation sites never are. Those can still use `elidealloc_malloc` explicitly, and in v2
tokens.

### 6.2 Downstream wiring (C/C++)

```sh
# instrument (x86_64 gnu; ThinLTO optional, E18)
CFLAGS="-fmemory-profile -gmlt -fdebug-info-for-profiling -fno-omit-frame-pointer \
  -mno-omit-leaf-frame-pointer -fno-optimize-sibling-calls -fno-pie"
LDFLAGS="-fmemory-profile -no-pie -Wl,-z,noseparate-code -Wl,--build-id"
# run -> memprof.profraw.<pid> (or -fmemory-profile=<dir>, MEMPROF_OPTIONS=log_path=<prefix>)
llvm-profdata merge memprof.profraw.* --profiled-binary ./app.instr -o app.<sha>.memprofdata
# use (any triple; same debug-info flags as instrumenting)
CFLAGS="-flto=thin -gmlt -fdebug-info-for-profiling -fmemory-profile-use=app.<sha>.memprofdata"
LDFLAGS="-flto=thin -fuse-ld=lld -Wl,-mllvm,-enable-memprof-context-disambiguation \
  -Wl,-mllvm,-optimize-hot-cold-new -Wl,-mllvm,-supports-hot-cold-new -lelidealloc-shim"
#   gnu: + -lmimalloc      musl: -static
```
Evidence: `-Rpass=memprof` (matches), `-Wl,-mllvm,-pass-remarks=memprof-context-disambiguation`
(clones), `ELIDEALLOC_STATS=1` (bytes per partition). The bundle never passes
`-supports-hot-cold-new` by itself.

### 6.3 Rust and GraalVM

- Rust: no rustc MemProf flag. Rust allocation sites can't be hinted. C++ parts of a
  `-Clinker-plugin-lto` binary get the full treatment (E16): pass the LDFLAGS above as
  `-Clink-arg=`s. Experimental Rust instrumentation: `-Cpasses=memprof-module,function(memprof)`
  plus the instrument link flags (E15). Uninstrumented accessors make memory look cold (risk 4).
- GraalVM: Java code no. JNI/C parts only, and only if native-image's final link is an lld
  ThinLTO link carrying the flags *(unverified)*.

## 7. Pipeline ordering

All profiling builds are plain (non-DeduBB, non-Propeller-relinked) binaries.

1. IRPGO: `-fprofile-generate` → run → `pgo.profdata`.
2. MemProf profile (x86_64 gnu): `-fprofile-use=pgo.profdata -fmemory-profile` → run → `mem.memprofdata`.
3. Optional CSPGO: `-fprofile-use=pgo.profdata -fcs-profile-generate -fmemory-profile-use=mem.memprofdata` → merge → `merged.profdata`.
4. Labelled final build: `-fprofile-use=merged.profdata -fmemory-profile-use=mem.memprofdata`
   + Propeller step-1 flags + MemProf link flags + `-lelidealloc-shim`.
5. perf (LBR/SPE) on 4 → `generate_propeller_profiles --profile … --cc_profile --ld_profile
   --dedubb_profile --dedubb_cold_only`.
6. Relink 4 with the cluster/symbol-order files and `-dedubb-directives`.

Interactions: MemProf clones differ at the hinted call, so ICF can't merge them, but DeduBB
can fold their identical blocks back. Propeller layout and DeduBB come from one tool run. Do
not stack BOLT on a DeduBB binary. Save-and-Jump masters have no CFI and end in `jmp *%r11`.

## 8. Verification (stage checks and `scripts/verify/checks.sh`)

| Check | Triples | Asserts |
|---|---|---|
| `tests/stages/45-propeller.check.sh` | Linux | binary exists; `--help` lists `--dedubb_profile`; glibc floor ≤ 2.34; no `libelf`/`libstdc++` in `NEEDED`; propeller unit tests pass (build tree) |
| `check_propeller_tool` | Linux | DeduBB fixture built with Propeller step-1 flags → `--dedubb_profile` yields `bbm` and `bbf` for `master_fn`/`fold_fn` |
| `check_propeller_golden` | Linux | upstream `sample_with_bb_hash` fixture → cc/ld profiles equal goldens (without `h` lines); no PMU needed |
| `check_propeller_relink` | Linux (x86_64 host fixtures; the relink compiles for each triple) | upstream `bimodal_sample_v2` perf data → profiles → relink with bundle clang (non-LTO + ThinLTO) → symbol order follows the ld profile, `.text.hot`/`.text.split` present, `main.cold` in `.text.split`, runs |
| `check_propeller_live` | Linux | probe LBR (`perf record -b`) / SPE (`arm_spe//`) + `perf_event_paranoid`; if capable, live record → profiles → relink → same evidence; else warn-skip; `REQUIRE_LBR=yes` makes the skip a failure |
| `check_dedubb_codegen` | Linux (4 triples) | generate directives with the shipped tool, relink with `-dedubb-directives` → `fold_fn` branches to `DeduBB.master.0`; output correct |
| `check_dedubb_inert` | x86_64 gnu | two builds without directives are byte-identical and contain no `DeduBB.` symbols |
| `check_elidealloc_shim` | all | `elidealloc-shim-test` passes (forward-mode expectations on darwin and for musl without mimalloc) |
| `check_memprof_runtime` | x86_64 gnu | instrument → run → `merge --profiled-binary` → ≥ 2 contexts |
| `check_memprof_use` | all | YAML profile → match remark → clone `_Z5allocm.memprof.1` + `_Znam12__hot_cold_t` → runs; cold object in COLD and notcold in DEFAULT (`elidealloc_partition_of`); darwin link-only |
| `check_memprof_strip` | one | without `-supports-hot-cold-new`: no `hot_cold` symbols |
| `check_memprof_absent` | non-x86_64-gnu | no `libclang_rt.memprof*` |

Unit tests: `apply_patches` series and `# requires:` gating; `memprof_supported`;
helper `flags` modes; manifest `features` block.

## 9. Risks

1. **DeduBB is unreviewed research code** in the default compiler. Mitigation: inert without
   directives (`check_dedubb_inert`), knob `LLVM_DEDUBB=no`, consumer trial before release.
2. **Unwinding through DeduBB masters** relies on the patch's CFI reasoning. Exceptions,
   perf call graphs and crash reporters need testing on a real consumer.
3. **Propeller build weight and drift**: four third-party deps (protobuf builds `protoc`)
   add build time (*unmeasured; first CI run decides*). Propeller has no tags, so bumps are
   commit-based and its `CMake/` changes can break `0001`/`0003`.
4. **MemProf cold misclassification** for memory accessed only by uninstrumented code (Rust,
   JIT code, JNI). Effect is performance only.
5. **Hot heap cost**: first-class-heap allocation goes through a heap lookup that plain
   `malloc` skips. Routing hot objects may cost cycles on the hottest path. Measure with
   `ELIDEALLOC_DISABLE=1` A/B. If it's a loss, set `ELIDEALLOC_HOT_MIN=256` (disables hot).
6. **No LBR/SPE on CI** (confirmed for the GCE runners): live collection stays untested in CI. Mitigated by fixture-based round trips (§3.3a). DeduBB is static and fully tested.
7. **Bundle growth**: memprof runtime ~5 MB (gnu x86_64), propeller tool ~36 MB unstripped
   (*stripped size unmeasured*).

## 10. Open questions for the user

1. For token classes (v2): what isolation goal comes first: security (pointerful vs
   pointer-free, `N=2`) or locality (more classes)?
2. Which GraalVM version does Elide pin? It bounds what native-image can participate in.

Resolved 2026-10-05: shim name `libelidealloc-shim` (allocator-agnostic); ambiguous hint 222
stays in the default heap (D10); backports accepted and tracked in elide-dev/toolchain#4; CI runners
cannot branch-sample and won't be changed, so Propeller CI verification uses fixtures (§3.3a).

## 11. Out of scope

- An aarch64, darwin or musl MemProf runtime; dynamic musl (not a supported downstream configuration).
- BOLT `--dedubb` (§4.5), DeduBB'ing the bundle's own tools.
- rustc changes (MemProf use, tokens, applying cluster files to non-LTO crates).
- Building the v2 token members (designed here, implemented in a follow-up).
- Upstreaming DeduBB.

## 12. Implementation decisions (2026-10-05)

Recorded while implementing the plan. Each one refines or deviates from the text above.

1. **quipper without libcrypto and libz.** Besides the libelf → LLVM `Object` rewrite (D5),
   quipper's only crypto use (`Md5Prefix`, OpenSSL EVP MD5) now uses `llvm::MD5`, and nothing in
   propeller or quipper needs zlib. Patch `0002-quipper-llvm-object-no-libelf-libcrypto.patch`
   drops all three `find_library` calls, so stage 45 depends only on the stage-2 LLVM and
   `out/<host>/llvm-deps` (zstd, zlib for LLVMSupport). It can run directly after stage 40,
   before the stage-50 components. Quipper is patched after download through
   `PROPELLER_QUIPPER_PATCHES` (`src/patches/llvm-propeller/quipper/*.patch`, applied with
   `patch -p1`; stage 45 requires `patch`).
2. **Stage 00 un-applies before its clean check.** `unapply_patches` reverses `glibc`, `llvm` and
   `llvm-propeller` series (last first) before the dirty-submodule check that `main` added. Stages
   10/30/40 (llvm) and 45 (llvm-propeller) apply them again.
3. **Feature checks in their own file.** All stage-95 checks for this work live in
   `scripts/verify/checks-pgo.sh` (`run_feature_checks`), sourced by `checks.sh` with a one-line
   hook. That keeps the shared file's diff minimal while other work (sanitizer variants) also
   touches it.
4. **MemProf runtime flags appended.** Stage 30 appends `-DCOMPILER_RT_BUILD_MEMPROF=ON
   -DSANITIZER_CXX_ABI=none -DCMAKE_SHARED_LINKER_FLAGS=…` after `runtimes_common_args`
   (later `-D` wins) instead of changing that function's signature, for the same merge reason.
5. **Shim details.** Backends are selected by compiling `backend-<name>.cc` (no `-D` macro
   needed). The public header also declares the eight `__hot_cold_t` overloads, so C++ code
   can pass hints explicitly. Hints that map to DEFAULT, and partition allocations that fail, go to
   the **stock** `::operator new` / `malloc` (not the backend's default heap). That keeps user
   replacements of `operator new` and stock OOM behaviour. Throwing OOM is therefore the process
   allocator's business (gnu's mimalloc `operator new` override aborts without a new_handler), and
   the test checks only the nothrow variants. `elidealloc_backend TRIPLE` lives in
   `scripts/lib/platform.sh` so stage 35, its stage check, and the manifest agree.
6. **Frozen ABI check.** "Exported" means GLOBAL, DEFAULT-visibility, defined symbols in the
   archive's native symbol tables (`llvm-readelf -sW` per member). Internals are built
   `-fvisibility=hidden`, so they are GLOBAL HIDDEN and excluded.
7. **Propeller relink fixture is x86_64-only.** The upstream `bimodal_sample_v2` perf data
   carries x86-64 BB IDs, so `check_propeller_relink` runs for the x86_64 triples (both libcs).
   aarch64 bundles still run `check_propeller_golden`, `check_propeller_tool` and DeduBB end to end.
8. **DeduBB check reads the fold site from the directives** (`bbf` record's function) and
   requires a direct branch to the `DeduBB.master.0` address, so it doesn't depend on which of the
   two identical functions the tool picks as the master.
9. **Manifest knobs.** `gen-manifest.py` reads `BUILD_PROPELLER`, `LLVM_DEDUBB` and
   `MUSL_USE_MIMALLOC` from the environment (90-package passes them) to fill `features`.
