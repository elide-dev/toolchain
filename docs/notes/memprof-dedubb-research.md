# MemProf and DeduBB: research notes

**Date:** 2026-10-05
**Feeds:** `docs/superpowers/specs/2026-10-05-memprof-dedubb-design.md`,
`docs/superpowers/plans/2026-10-05-memprof-dedubb.md`

Every claim below is tagged with how it was established:

- **[src]**: read in the source tree at the cited file:line.
- **[exp]**: reproduced by an experiment on this machine (scratch dirs only; nothing was
  written into `out/` or the submodules). Commands are summarized under "Experiments".
- **[web]**: read from the cited URL on 2026-10-05.
- **[unverified]**: inferred or remembered, not checked. Treat as uncertain.

## 0. Baseline

| Item | Value |
|---|---|
| LLVM submodule | `llvmorg-23.1.2` = `85ac560262434c9ccfc0c183ec22d4138ed647fb` (tag object `2d56740342c3`) [src: `.git/modules/llvm/HEAD`, `gh api git/tags`] |
| `release/23.x` branch point | `fb423ba07c3f` (2026-07-14, "[ThinLTO] Error on missing ValueInfo for function definition"); 23.1.2 is 358 commits ahead of it [web: GitHub compare `main...llvmorg-23.1.2`] |
| `cmake/Modules/LLVMVersion.cmake` | 23.1.2 [src] |
| Existing bundle used for experiments | `/home/sam/workspace/toolchains/native/out/linux-amd64/elide-toolchain` (read-only) |
| mimalloc | 3.5.4, `f8401befa675` (`MI_MALLOC_VERSION 30504`, `mimalloc/include/mimalloc.h:11`) [src] |
| llvm-propeller submodule | `ddfb8b7cbdb8` (2026-09-24), disabled; no component recipe exists in `scripts/components/` [src] |
| rustc used | `1.101.0-nightly (c36f14571 2026-10-01)`, LLVM 23.1.1 [exp: `rustc +nightly -vV`] |

## 1. MemProf

### 1.1 What 23.1.2 ships, out of the box

All of the compiler side is present and works in the existing bundle with no patches.

| Piece | Where | Status |
|---|---|---|
| `-fmemory-profile[=<dir>]`, `-fmemory-profile-use=<path>` | `clang/include/clang/Options/Options.td:2553-2562` | [src] [exp] accepted by the bundle's clang |
| `-fmemory-profile-use` conflicts with `-fmemory-profile` and `-fprofile-generate` (driver error) | `clang/lib/Driver/ToolChains/Clang.cpp:5578-5595` | [src] |
| `-fmemory-profile-use` composes with `-fprofile-use`, CS-IRPGO use and sample PGO (the path is threaded into every `PGOOptions`) | `clang/lib/CodeGen/BackendUtil.cpp:845-875` | [src] |
| Instrumentation passes added by clang (not by the PassBuilder pipeline) | `clang/lib/CodeGen/BackendUtil.cpp:1117-1124` (`MemProfilerPass`, `ModuleMemProfilerPass`) | [src] |
| `MemProfUsePass` runs in the pre-link (PGO) pipeline, before inlining | `llvm/lib/Passes/PassBuilderPipelines.cpp:1256, 1316-1317` | [src] |
| Non-LTO builds strip MemProf metadata/attributes | `llvm/lib/Passes/PassBuilderPipelines.cpp:1778-1782` | [src] |
| ThinLTO backend: `MemProfRemoveInfo` unless the index says `withSupportsHotColdNew`; then `MemProfContextDisambiguation` applies the thin-link decisions | `llvm/lib/Passes/PassBuilderPipelines.cpp:1956-1966`; full LTO `2041-2044, 2215` | [src] |
| `-supports-hot-cold-new` sets the combined-index flag in the LTO link | `llvm/lib/LTO/LTO.cpp:1367-1373`; option `llvm/lib/Transforms/IPO/MemProfContextDisambiguation.cpp:219-221` | [src] |
| `-enable-memprof-context-disambiguation` (off by default) | `MemProfContextDisambiguation.cpp:213-215` | [src] |
| `-optimize-hot-cold-new` (off by default), hint values cold=1, notcold=128, hot=254, ambiguous=222 | `llvm/lib/Transforms/Utils/SimplifyLibCalls.cpp:54-106`; rewrite in `optimizeNew` `:1786-1800` | [src] [exp] observed `movl $0x80,%esi` / `movl $0x1,%esi` before `_Znam12__hot_cold_t` |
| Only `operator new` variants (and `__size_returning_new`) are hinted; `malloc`, `__rust_alloc` are not | `llvm/lib/Transforms/Instrumentation/MemProfUse.cpp:182-205` | [src] |
| Hot/cold `operator new` LibFuncs (`_Znwm12__hot_cold_t`, …, `__size_returning_new_hot_cold`) | `llvm/include/llvm/Analysis/TargetLibraryInfo.td:165-270` | [src] |
| User documentation (flags, `--profiled-binary`, `-fno-pie -no-pie -Wl,-z,noseparate-code -Wl,--build-id`, YAML profiles) | `llvm/docs/MemProf.md:29-93, 259-294` | [src] |
| Static data partitioning (`-fpartition-static-data-sections`, `-Wl,-z,keep-data-section-prefix`) | `llvm/docs/MemProf.md:124-157`; `Options.td:4980` | [src] (not exercised) |
| `llvm-profdata merge <raw> --profiled-binary <bin>`, `show --memory`, YAML → indexed | `llvm/docs/MemProf.md:60-70, 259-275` | [exp] |
| `opt --print-passes` lists `memprof`, `memprof-module`, `memprof-use<profile-filename=S>`, `memprof-context-disambiguation`, `memprof-remove-attributes` | — | [exp] |

### 1.2 Runtime (compiler-rt `memprof`)

| Fact | Where | Status |
|---|---|---|
| Supported arches: **x86_64 only** (in 23.1.2 and still on `main` today) | `compiler-rt/cmake/Modules/AllSupportedArchDefs.cmake:96`; main checked via `gh api contents/...` | [src] [web] |
| Supported OS: **Linux only** (no Darwin) | `compiler-rt/cmake/config-ix.cmake:842-847` | [src] |
| Builds with `COMPILER_RT_BUILD_SANITIZERS=OFF` (pulls in sanitizer_common itself) | `compiler-rt/lib/CMakeLists.txt:12, 34, 68-69` | [src] [exp] |
| Refuses static linking | `compiler-rt/lib/memprof/memprof_rtl.cpp:181` (`DoesNotSupportStaticLinking()`) | [src] [exp] musl `-static` link fails: `undefined hidden symbol: _DYNAMIC` |
| Output file: `__memprof_profile_filename` (from clang's `-fmemory-profile=<dir>` module flag) else `log_path` | `memprof_rtl.cpp:187-192`; `MemProfInstrumentation.cpp:474-492` | [src] [exp] rustc-instrumented binary wrote the raw profile to stdout until `MEMPROF_OPTIONS=log_path=...` was set |
| Driver links `libclang_rt.memprof.a` + `memprof_cxx.a` (static) or `memprof.so` + `memprof-preinit` (shared) | `clang/lib/Driver/ToolChains/CommonArgs.cpp:1641-1643, 1700-1702` | [src] [exp] bundle link fails today: `cannot open .../libclang_rt.memprof.a` |
| Darwin driver only exports the options symbol; it never links a memprof runtime | `clang/lib/Driver/ToolChains/Darwin.cpp:1781-1785` | [src] [exp] `-###` for `arm64-apple-macos12` shows no memprof library |
| The aarch64 driver path asks for `aarch64-unknown-linux-gnu/libclang_rt.memprof.a`, which compiler-rt cannot build | — | [exp] `-###` |
| Shared runtime link in a runtimes build needs `SANITIZER_CXX_ABI=none` and `CMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld -rtlib=compiler-rt -unwindlib=none` against our sysroots (default tries `-lstdc++` and `crtbeginS.o` via `/usr/bin/ld`) | `compiler-rt/CMakeLists.txt:236-265` | [exp] |

### 1.3 Upstream changes after the 23.x branch point (candidates)

Searched `gh api commits?path=...&since=2026-07-14` for `compiler-rt/lib/memprof`,
`MemProfContextDisambiguation.cpp`, `MemProfUse.cpp`, `MemProfInstrumentation.cpp`,
`llvm/lib/ProfileData` [web].

| Commit | PR | Size | What | Applies to 23.1.2? | Recommendation |
|---|---|---|---|---|---|
| `8c7d76bfc1b5` (2026-09-09) | [#222126](https://github.com/llvm/llvm-project/pull/222126) | +75/−76 (1 source file + tests) | Deterministic tie-break in `identifyClones` (DenseSet order made cloning nondeterministic across runs/hosts) | yes, `git apply --check` clean (offset 6) [exp] | **Backport**: reproducible bundles and consumer builds |
| `c0b8c59b65af` (2026-07-16) | [#208911](https://github.com/llvm/llvm-project/pull/208911) | +86/−4 (`memprof_allocator.cpp` + 2 tests) | Clear histogram tail granule on allocation (wrong counts with `-memprof-histogram`) | yes, clean [exp] | Backport (cheap; only matters with histograms) |
| `7f04c2bac295` (2026-09-06) | [#221372](https://github.com/llvm/llvm-project/pull/221372) | +111/−35 (`SetOperations.h`, MemProfCD) | Thin-link compile-time optimization | yes, clean [exp] | Optional; touches a public ADT header |
| `ef84e19e3fd3` (2026-07-09) | #208376 | — | Shadow access-count off-by-one | already in 23.x (before branch point) | none |
| `9a0c255ce1ef` (2026-09-29) | #214134 | large | `!PGOFuncName` → `!guid` metadata | n/a | **Do not** backport (IR/profile-format churn; would diverge from rustc's LLVM 23.1.1) |
| `6d7053ab41bc` (2026-08-27) | #217083 | small | `-memprof-random-hotness-seed` default | n/a | none (testing knob) |

Nothing on `main` adds an aarch64 or Darwin memprof runtime [web].

### 1.4 Allocator: tcmalloc interface vs mimalloc

- The hinted calls are `operator new(size_t, __hot_cold_t)` and its nothrow/aligned/array
  variants, where `__hot_cold_t` is a global-namespace `enum class : uint8_t`
  (Itanium mangling `12__hot_cold_t`). tcmalloc defines them in
  `tcmalloc/new_extension.h` [src: `SimplifyLibCalls.cpp:1782-1785` comment; TLI.td]
  ([web](https://github.com/google/tcmalloc/blob/master/tcmalloc/new_extension.h), not re-read today: [unverified] beyond the comment).
- Without a definition, the final link fails: `ld.lld: error: undefined symbol: operator new[](unsigned long, __hot_cold_t)` [exp]. libc++/libc++abi do not provide them.
- mimalloc 3.5.4 has no hot/cold API. It does have first-class heaps that "can allocate from any thread (and be free'd from any thread)" and "keep allocations in separate pages from each other" (`mimalloc.h:233-260`), and exclusive arenas: `mi_reserve_os_memory_ex(..., exclusive, &arena_id)` + `mi_heap_new_in_arena(arena_id)` + `mi_arena_contains` (`mimalloc.h:344-352`) [src].
- `free()`/`operator delete` of a heap block works through ordinary `mi_free`: on gnu,
  `libmimalloc.a` is `MI_OVERRIDE=ON`; on musl, mimalloc is libc's allocator
  (`scripts/stages/35-mimalloc.sh`) [src]. On darwin the static mimalloc does **not**
  override `free`, so a mimalloc-backed hot/cold `new` there would hand system `free` a
  foreign pointer: the darwin shim must forward to plain `::operator new` [src: stage 35 comment].
- Prototype shim (`operator new(size_t, __hot_cold_t)` → cold heap in an exclusive 256 MiB
  arena when hint < 128, else `::operator new`): cold allocation lands in the cold arena,
  hot does not, cross-thread alloc/free works; gnu (`-lmimalloc`) and musl `-static` [exp].
- musl is static-only downstream (dynamic musl is not a supported configuration), so the
  shim always resolves `mi_*` from `libc.a`'s single `mimalloc.o` member [src: stage 35].

### 1.5 Rust

- rustc has no `-Zmemprof`/memory-profile option. `options.rs` has `profile_generate`,
  `profile_use`, `profile_sample_use`, sanitizers, `llvm_args`; nothing memprof [web:
  `compiler/rustc_session/src/options.rs` on master]. `gh search` for memprof issues/PRs in
  rust-lang/rust: none [web].
- rustc always passes an empty `MemoryProfile` to `PGOOptions`, so `MemProfUsePass` never
  runs in rustc [web: `compiler/rustc_llvm/llvm-wrapper/PassWrapper.cpp:713-735`].
- `-Cpasses=` is parsed with `PB.parsePassPipeline` and appended after the optimization
  pipeline [web: `PassWrapper.cpp:983-990`]. So
  `-Cpasses=memprof-module,function(memprof)` instruments Rust code, approximately where
  clang adds it; with the bundle's runtime the binary ran and produced a raw profile that
  `llvm-profdata merge --profiled-binary` accepted (Rust frames, `IsInlineFrame` entries) [exp].
- Rust allocation sites can never be hinted (calls are `__rust_alloc`/`malloc`, not
  `operator new`) [src: `MemProfUse.cpp:182-205`].
- Rust + C++ with `-Clinker-plugin-lto`, linking through the bundle's clang/lld with the
  three `-Wl,-mllvm` options: the C++ part was cloned (`_Z5allocm.memprof.1`) and hinted,
  and the binary ran [exp].
- `-Cllvm-args=-basic-block-address-map` is accepted by rustc 1.101 nightly and emits
  `.llvm_bb_addr_map` [exp] (relevant to DeduBB/Propeller).

### 1.6 Allocation tokens (`-fsanitize=alloc-token`), for the shim's future interface

What 23.1.2 offers [src: `clang/docs/AllocToken.rst`; `llvm/lib/Transforms/Instrumentation/AllocToken.cpp`]:
- `-fsanitize=alloc-token` rewrites allocation calls to `__alloc_token_<fn>(args..., size_t token_id)`:
  `__alloc_token_malloc`, `_calloc`, `_realloc`, `_aligned_alloc`, `_posix_memalign`, … and C++
  `__alloc_token__Znwm`, `__alloc_token__Znam`, the nothrow/aligned variants, **and the hot/cold
  variants** (`__alloc_token__Znwm12__hot_cold_t`, …, `__size_returning_new_hot_cold`)
  (`AllocToken.cpp:413-461`). `strdup`/`strndup` are excluded (`:463-472`). Replaceable
  `operator new` is covered by default (`-alloc-token-cover-replaceable-new`, `:93-96`).
- Fast ABI `-fsanitize-alloc-token-fast-abi`: the token is in the name, `__alloc_token_<N>_malloc(size)`
  (useful with a small `-falloc-token-max=<N>`) [src: AllocToken.rst; Options.td:2961-2979].
- Token modes: default `typehashpointersplit` (type-name hash; the top half of the ID space
  is for pointer-containing types). Experimental `typehash`, `random`, `increment` via
  `-Xclang -falloc-token-mode=` [src: AllocToken.rst].
- `-fsanitize-alloc-token-extended` also covers custom `malloc`/`alloc_size` functions;
  `__builtin_infer_alloc_token(args…)` gives the token at compile time; `__SANITIZE_ALLOC_TOKEN__` macro;
  `no_sanitize("alloc-token")` and ignorelists [src: AllocToken.rst].
- **No runtime in compiler-rt**: the allocator must provide every `__alloc_token_*` entry point
  [src: no `compiler-rt/lib/*token*`; exp: `-###` links nothing extra].
- Pipeline: `AllocTokenPass` runs **after** LTO pre-link (`if (!isLTOPreLink(LTOPhase))`,
  `PassBuilderPipelines.cpp:1687-1690`), i.e. in the ThinLTO backend (`:1993-1995`) and after
  `SimplifyLibCalls`' hot/cold rewrite. MemProf hints and tokens therefore compose
  into one call `__alloc_token__Znam12__hot_cold_t(size, hint, token)` (E21).
- Frees are not tokenized: `free`/`operator delete` stay as they are, so a token-partitioning
  allocator must free by pointer, which mimalloc's `mi_free` does across heaps.
- Rust: rustc has no alloc-token flag *(not checked beyond the options.rs scan in §1.5)*.
  `__rust_alloc` is not a TLI libfunc, so even LTO-linked Rust is not tokenized.

### 1.7 GraalVM native-image

- Java code is compiled by Graal's own backend; MemProf (an LLVM IR feature) cannot see
  it. The LLVM backend (`-H:CompilerBackend=llvm`) was experimental and has been
  deprecated/removed in recent GraalVM releases [unverified: from memory; check the
  GraalVM version Elide pins].
- C/C++ objects linked into an image (JNI libs, static components) can carry MemProf
  hints only if the image's final link is an lld ThinLTO link with the `-mllvm` options;
  native-image drives the link itself through the `cc` it is given [unverified].

## 2. DeduBB

### 2.1 Identification

**DeduBB = "Binary Code Size Reduction via Post-Link Basic Block Deduplication"**, LCTES '26
(27th ACM SIGPLAN/SIGBED LCTES, pp. 43–56), by Chaitanya Mamatha Ananda, Mahbod Afarin,
Rajiv Gupta (UC Riverside), Sriraman Tallam, Han Shen, Xinliang David Li (Google; the
Propeller authors). Confidence: **high**. The name matches exactly, the user's description
("a patch/feature in LLVM to be wired in downstream") matches the artifact (LLVM CodeGen +
lld + Propeller patches), and it plugs into exactly the Propeller/BOLT stack this bundle is
set up for.

Sources [web]:
- Paper: <https://dl.acm.org/doi/10.1145/3814943.3816169>
- Artifact: <https://zenodo.org/records/20261031> (DOI 10.5281/zenodo.20261031, v1, 2026-05-17, CC-BY-4.0)
- Code: <https://github.com/chaitanyaupp18/DeduBB>
  - `main` @ `07d730dab798a18440cd7b6ecca103794a86dfc2` (2026-10-03): `patches/llvm-project-dedubb.patch` (4725 lines), `patches/llvm-propeller-dedubb.patch` (6567 lines), `optimize_clang.sh`, `examples/`
  - `bolt-dedubb` @ `0e20b1fed23c693cd453e4dad7d72fa7b48c8ddc` (2026-10-05): `patches/llvm-project-bolt-dedubb.patch` (2260 lines): DeduBB as a BOLT pass (`llvm-bolt --dedubb`)
  - `performance` @ `06da3a8`: cold-only folding from a perf profile + Propeller layout + timing
- Licenses: LLVM patch Apache-2.0 WITH LLVM-exception; Propeller patch Apache-2.0.

Upstream status: **not upstream anywhere**. `gh search prs/issues --repo llvm/llvm-project DeduBB`
and `--repo google/llvm-propeller dedubb`: no results; no Discourse RFC found [web].

Candidates considered and rejected (none is called DeduBB):
- `BranchFolding` tail merging (`llvm/lib/CodeGen/BranchFolding.cpp`): intra-function only.
- `MachineOutliner` (`llvm/lib/CodeGen/MachineOutliner.cpp`): outlines repeated sequences into new functions; DeduBB's README benchmarks against it (1 and 2 rounds, PR #90933).
- BOLT `--icf`, lld `--icf=all`: whole-function folding only.
- D30774 "[SimplifyCFG] Merging duplicated basic blocks" (2017, IR-level, intra-function, abandoned): <https://reviews.llvm.org/D30774>.

### 2.2 What it does

Two builds, like Propeller: (1) build with `-fbasic-block-address-map` (ThinLTO:
`-Wl,--lto-basic-block-address-map`); (2) `generate_propeller_profiles --binary=app
--dedubb_profile=dedubb.txt [--dedubb_subsequence]` finds identical blocks/runs across the
whole linked binary and writes directives; (3) rebuild identically plus
`-Wl,-mllvm,-dedubb-directives=dedubb.txt`; new late MachineFunction passes fold each
duplicate into a jump/call to one master [web: README].

Strategies: Tail Call (`jmp` to a master ending in ret/tail call), Save-and-Jump (`leaq
Tail(%rip),%r11; jmp master` … `jmp *%r11`, x86-64 only), Call-Return (`call` master,
master `ret`s; x86-64 only). AArch64: Tail Call only (`AArch64InstrInfo::insertDeduBBTailBranch`
emits `TCRETURNdi`) [src: patch].

Reported: Clang ThinLTO x86-64 at `-Oz --gc-sections --icf=all`: −9.81% `.text`, −6.55%
stripped binary (MachineOutliner: −2.60%/+0.85%; two rounds −7.38%/−2.83%). BOLT variant:
−9.77% code but +5.62% file (in-place rewrite) [web: READMEs].

### 2.3 Patch anatomy (`llvm-project-dedubb.patch`)

New: `llvm/include/llvm/CodeGen/DeduBBDirectives.h` (193), `llvm/lib/CodeGen/DeduBB.cpp`
(965), `llvm/lib/CodeGen/DeduBBCallReturn.cpp` (1413), 5 X86 + 1 AArch64 `.ll` tests.
Modified: `TargetInstrInfo.h` (+~130 lines of virtual hooks), `X86InstrInfo.{h,cpp}`
(+~260), `AArch64InstrInfo.{h,cpp}` (+15), `TargetPassConfig.cpp` (passes added right after
the MachineOutliner slot), `AsmPrinter.cpp` (global hidden `DeduBB.master.N` labels),
`MachineFunction.cpp` (mark master blocks address-taken), `UnreachableBlockElim.cpp`,
`Passes.h`, `InitializePasses.h`, `CodeGen.cpp`, `CMakeLists.txt`;
`lld/ELF/LinkerScript.cpp` (`.text.dedubb` kept by `-z keep-text-section-prefix`) + test;
`clang/tools/driver/CMakeLists.txt` (`CLANG_DEDUBB_DIRECTIVES` cache var to DeduBB clang itself) [src: patch].

Behaviour without `-dedubb-directives`: the passes return immediately; AsmPrinter and
`CreateMachineBasicBlock` check `DeduBBDirectives::get().empty()`. **One unconditional
change**: `UnreachableBlockElim` no longer deletes an unreachable block that has its
address taken (`!Reachable.count(&BB) && !BB.hasAddressTaken()`), for every compilation
[src: patch]. Safety logic present in the patch: `LiveRegUnits`/`LivePhysRegs` checks for the
link register, skips blocks with CFI/labels/EH pads/inline asm, red-zone functions,
stack-argument calls, and Save-and-Jump under `cf-protection-branch` (IBT) [src: patch
lines ~240-262, 1006, 1141-1160, 2045-2125].

Base: `llvm/llvm-project@333edde4e80e` (2026-07-08, "[BPF] Return small aggregates
directly in registers (#206876)"), an **ancestor** of `llvmorg-23.1.2` (tag is 1353 commits
ahead; branch point is 6 days later) [web: GitHub compare].

Against 23.1.2 [exp]:
- `git apply --check`: **clean**; one hunk offset (`X86InstrInfo.cpp`, +70 lines).
- `-fsyntax-only` of every patched TU (`DeduBB.cpp`, `DeduBBCallReturn.cpp`,
  `TargetPassConfig.cpp`, `MachineFunction.cpp`, `UnreachableBlockElim.cpp`, `CodeGen.cpp`,
  `AsmPrinter.cpp`, `X86InstrInfo.cpp`, `AArch64InstrInfo.cpp`, `lld/ELF/LinkerScript.cpp`)
  against 23.1.2 headers + the stage-2 build's generated headers: **all OK**.
- `bolt-dedubb` patch: `git apply` clean (one offset, `BinaryFunction.h` +15); syntax check
  of `DeduBB.cpp`, `BinaryPassManager.cpp`, `RewriteInstance.cpp`, `X86MCPlusBuilder.cpp`: **all OK**.
- The two LLVM patches touch disjoint files (`bolt/` vs `llvm/`, `lld/`, `clang/`).
- Built `llc` from 23.1.2 + the CodeGen patch and ran the patch's own `.ll` tests:
  **6/6 pass** (E9).

### 2.4 Propeller side

- DeduBB's Propeller patch is based on `google/llvm-propeller@e2c70493656` (2026-05-04,
  "Integrate LLVM at llvm/llvm-project@665984f5b327"); our pin `ddfb8b7cbdb8` is 22 commits
  ahead [web]. Against our pin, two hunks are rejected (E23): the include block of
  `generate_propeller_profiles.cc` and the context of the new `DisassembleOne(ArrayRef…)`
  overload in `mini_disassembler.cc`. A third hunk must be **dropped**, not rebased: it switches
  `MCContext`'s constructor to the older pointer API of DeduBB's LLVM base, while 23.1.2 (and our
  propeller pin) use references. All three fixes are mechanical.
- The repo's own `src/patches/llvm-propeller/0001-find-package-llvm.patch` and
  `0002-mccontext-asminfo-pointer.patch` **no longer apply** to the pinned `ddfb8b7` in
  either direction (`CMake/LLVM/LLVM.cmake` now pins LLVM `db9b595ae3b3` and
  `mini_disassembler.cc` already uses `*asm_info_, *mri_, *sti_`) [exp]. They are stale.
- Propeller's CMake downloads LLVM, abseil, protobuf, googletest and quipper at configure
  time (`CMake/*/CMakeLists.txt.in`, `CMake/Protobuf/Protobuf.cmake:27-28`) [src].
- `generate_propeller_profiles` with DeduBB handles x86 and aarch64/arm ELF (`Triple::` switch,
  4-byte AArch64 patch size); subsequence/CR/SJ estimation is x86-64 only [src: patch ~1313-1322, 3189-3225].

### 2.5 Propeller revival spike (2026-10-05)

Goal: build the pinned `llvm-propeller` (`ddfb8b7`, which is upstream HEAD as of today) against
the bundle's LLVM 23.1.2, read-only against `out/` (E22–E24).

- Propeller pins LLVM `db9b595ae3b3` (2026-05-27) in `CMake/LLVM/LLVM.cmake`; that is an
  ancestor of 23.1.2 (6659 commits behind the tag) [web].
- Replaced `CMake/LLVM/LLVM.cmake` with a 15-line `find_package(LLVM CONFIG)` module
  (`LLVM_DIR=out/linux-amd64/build/llvm-stage2/lib/cmake/llvm`, plus
  `${LLVM_MAIN_SRC_DIR}/lib/Target/{X86,AArch64}` include dirs). Compiler: stage-1
  `x86_64-unknown-linux-gnu-clang++` (cfg: glibc 2.34 sysroot, libc++, lld). So it is
  ABI-compatible with the stage-2 static LLVM libraries.
- Configure-time downloads (network): abseil `20260107.1`, protobuf `33.4`, googletest,
  quipper (`google/perf_data_converter@f9eb05fcce80`) [src: `CMake/*`].
- System libraries (`CMakeLists.txt:33-35`): `libz` → sysroot zlib-ng (compat) OK; `libcrypto` →
  sysroot aws-lc OK (quipper uses MD5/EVP, `binary_data_utils.cc:7-8`); **`libelf` is not in
  our sysroots**. quipper's `dso.cc` uses it only to read ELF build-id notes (`dso.cc:7-128`).
  The spike used the host's `libelf.a` plus a one-line `__isoc23_strtol` shim (host libelf is
  built against glibc ≥ 2.38).
- Result: **every propeller, absl, protobuf and quipper TU compiled against 23.1.2 unmodified**;
  `generate_propeller_profiles` linked (36 MB, max symbol version `GLIBC_2.34`) and runs.
- With DeduBB's Propeller patch (3 mechanical fixes, §2.4): builds, and
  `--binary=<-fbasic-block-address-map ThinLTO binary> --dedubb_profile=out.txt --dedubb_subsequence`
  emitted `bbm`/`bbf` for the 2-function fixture (`fold_fn`/`master_fn`, BB 0, `block_insts=7`)
  and 25 directives for DeduBB's `examples/test{1,2}.cpp`.
- Not exercised: the layout path (`--profile=perf.data --cc_profile --ld_profile`). This
  WSL2 host has no LBR (`perf record -j any,u`: "PMU Hardware or event type doesn't support
  branch stack sampling"). Also not exercised: the DeduBB fold step, which needs a patched clang/lld.

### 2.6 CI branch-sampling capability (infra finding, 2026-10-05)

GCE runners: c4d (AMD Turin, amd64) has no guest PMU; c4a (Axion, arm64) offers PMU
STANDARD only via delete+recreate (local SSDs), and SPE is unconfirmed. The runners will not
change. A possible future option is the self-hosted `sandbox-ci-x86` (`linux-amd64-bench`,
`cloud-latitude`, likely bare-metal AMD with LBRv2/BRS), not yet probed.

## 3. Pipeline facts relevant to both

- lld adds `-mllvm` strings (e.g. `-dedubb-directives=<path>`) to the ThinLTO cache key,
  but not the file contents (`llvm/lib/LTO/LTO.cpp:176-196`; `lld/ELF/LTO.cpp:63`) [src].
  Changing a profile/directive file at the same path can reuse stale cache entries.
- `DeduBB.master.N` symbols are global hidden [src: patch AsmPrinter hunk]; two
  independently DeduBB'd relocatable inputs in one link would collide [unverified, by reading].
- cflags profile: `-fcf-protection=full` and `-fbasic-block-sections=all` are parked in
  `cflags/labs.disabled.txt`; linux-arm64 uses `-mbranch-protection=standard` [src].

## Experiments (all in the session scratchpad)

| # | What | Result |
|---|---|---|
| E1 | `x86_64-unknown-linux-gnu-clang++ -fmemory-profile -c` | compiles; object has `__memprof_init`, `__memprof_shadow_memory_dynamic_address` refs |
| E2 | link with `-fmemory-profile` (bundle as shipped) | fails: no `libclang_rt.memprof.a` |
| E3 | YAML profile (2 contexts, hot vs cold through a shared `alloc()` wrapper) → `llvm-profdata merge` → `-fmemory-profile-use -flto=thin` → lld with the 3 `-mllvm` options + a test `__hot_cold_t` shim | remarks `created clone _Z5allocm.memprof.1`; `_Z5allocm` calls `_Znam12__hot_cold_t` with 128, the clone with 1; runs |
| E4 | same without `-supports-hot-cold-new` | no `hot_cold` symbols (attributes stripped) |
| E5 | same with `-supports-hot-cold-new` but no shim | `undefined symbol: operator new[](unsigned long, __hot_cold_t)` |
| E6 | same, musl `-static` | clone + run OK |
| E7 | `--target=arm64-apple-macos12 -fmemory-profile-use` IR | `!memprof` metadata present |
| E8 | scratch runtimes build of compiler-rt memprof for x86_64 gnu and musl (stage-1 clang, bundle sysroots, `SANITIZER_CXX_ABI=none`, lld shared link flags) | builds both; installs `libclang_rt.memprof{,_cxx,-preinit}.a` (+ `.syms`) |
| E9 | patched `llc` (23.1.2 `llvm/` + DeduBB CodeGen patch, X86;AArch64, stage-1 clang), the patch's 6 `dedubb*.ll` tests via a minimal RUN-line runner | **6/6 pass** (21 RUN lines, incl. `-verify-machineinstrs`). 40 existing `test/CodeGen/X86` tests that use `blockaddress` / BB sections / BB address map also pass (regression probe for the unconditional `UnreachableBlockElim` change). Not run: full `check-llvm`, lld test, any end-to-end binary fold |
| E10 | gnu: instrument (`-fmemory-profile -fno-pie -no-pie -Wl,-z,noseparate-code -Wl,--build-id`) → run → `memprof.profraw.<pid>` → `merge --profiled-binary` → use → link | works end to end; 6 match remarks; `_Znam12__hot_cold_t` emitted |
| E11 | musl `-static` instrumented link | fails: `undefined hidden symbol: _DYNAMIC` (runtime needs dynamic) |
| E12 | musl dynamic instrumented binary (host's musl loader) | runs, profile merges and is consumed (dynamic musl is not a supported downstream configuration; recorded only as runtime evidence) |
| E13 | gnu-collected profile used for a musl compile | same 6 matches |
| E14 | mimalloc hot/cold shim prototype, gnu + musl static | cold → cold arena, hot → default, cross-thread OK |
| E15 | rustc `-Cpasses=memprof-module,function(memprof)` + bundle runtime | instruments, runs, profile merges |
| E16 | rustc `-Clinker-plugin-lto` + C++ static lib with MemProf use | clone + hint applied in the lld ThinLTO link; runs |
| E17 | rustc `-Cllvm-args=-basic-block-address-map` | accepted; `.llvm_bb_addr_map` emitted |
| E18 | gnu instrumented build compiled and linked with `-flto=thin` | instrumentation survives the ThinLTO link; profile (2 contexts) merges; use step gets 6 matches |
| E19 | `--target=arm64-apple-macos12 -fbasic-block-address-map` | `unsupported option` (BB address maps are ELF-only); accepted for `aarch64-unknown-linux-gnu` |
| E21 | `-fsanitize=alloc-token` (C, non-LTO; fast ABI with `-falloc-token-max=4`; ThinLTO + MemProf hints) | `__alloc_token_malloc`/`_calloc`; `__alloc_token_3_malloc`/`__alloc_token_0_calloc`; pre-link objects carry only `!alloc_token` metadata; final link needs exactly `__alloc_token__Znam12__hot_cold_t` |
| E22 | llvm-propeller `ddfb8b7` against stage-2 LLVM 23.1.2 (find_package, stage-1 gnu cfg compiler) | all TUs compile; link needs libelf (host `libelf.a` + `__isoc23_strtol` shim); binary runs, `GLIBC_2.34` floor |
| E23 | DeduBB Propeller patch onto `ddfb8b7` | 2 rejected hunks + 1 hunk to drop (MCContext pointer API); fixed by hand; builds |
| E24 | spike `generate_propeller_profiles --dedubb_profile` on fixtures | correct `bbm`/`bbf` directives (2-function fixture; 25 for DeduBB examples) |
| E25 | spike tool on upstream `sample_with_bb_hash.{bin,perfdata}` | cc/ld profiles equal upstream golden except the optional `h` hash lines; no PMU needed |
| E26 | spike tool on upstream `bimodal_sample_v2.{bin,perfdata.1,.2}`, relink `bimodal_sample_v2.c` with the bundle clang (non-LTO + ThinLTO) | symbol order `main, compute, foo, bar` = ld profile; `.text.hot` + `.text.split`; `main.cold` in `.text.split`; runs |
| E20 | scratch `libclang_rt.memprof.so` (gnu) | needs only `libc.so.6`, `libm.so.6`; highest symbol version `GLIBC_2.34` (passes the floor check) |
