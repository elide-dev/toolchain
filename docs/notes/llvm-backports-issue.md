<!-- Source text of https://github.com/elide-dev/toolchain/issues/4 (filed by the maintainer, 2026-10-05). Keep in sync: edit here, then update or comment on #4. -->

# Title

Track LLVM 23.1.2 local patches: MemProf backports (#222126, #208911) and vendored DeduBB

# Body

The elide-toolchain LLVM is `llvmorg-23.1.2` (`85ac560262434c9ccfc0c183ec22d4138ed647fb`) plus the
patches in `src/patches/llvm/`. `apply_patches llvm` applies them to the `llvm` submodule at the start
of stages 10, 30 and 40. This issue records each patch: what it is, why we carry it, how it
changes behaviour relative to stock 23.1.2, and when to drop it. Design:
`docs/superpowers/specs/2026-10-05-memprof-dedubb-design.md`; evidence:
`docs/notes/memprof-dedubb-research.md`.

## Upstream backports

### `0001-memprof-deterministic-clone-tiebreak.patch`

- **Upstream:** llvm/llvm-project#222126, commit `8c7d76bfc1b5` ("[MemProf] Use NodeId to break ties deterministically in identifyClones"), merged to `main` 2026-09-09; not in any 23.x release.
- **Size:** +75/−76: `llvm/lib/Transforms/IPO/MemProfContextDisambiguation.cpp` (comparators) plus 7 test files.
- **What it changes:** in the MemProf thin-link clone analysis, ties between caller edges were broken by the first element of a `DenseSet` of context IDs. That order depends on hash-table layout, so it can differ between runs and hosts. The patch breaks ties by caller/callee `NodeId`.
- **Why:** reproducible consumer builds. Without it, the same profile and sources can produce different function clones and hint assignments on different machines.
- **Behaviour vs stock 23.1.2:** only when MemProf context disambiguation runs (`-fmemory-profile-use` + ThinLTO + `-enable-memprof-context-disambiguation`). Among equally ranked clone candidates a different one may be chosen, so output differs from stock 23.1.2 but becomes deterministic. Builds that don't use MemProf are unaffected.
- **Conflicts:** applies cleanly to 23.1.2 (hunk offset 6).

### `0002-memprof-histogram-tail-granule.patch`

- **Upstream:** llvm/llvm-project#208911, commit `c0b8c59b65af` ("[compiler-rt][memprof] clear histogram tail granule on allocation"), merged 2026-07-16, two days after the `release/23.x` branch point; not in 23.1.2.
- **Size:** +86/−4: `compiler-rt/lib/memprof/memprof_allocator.cpp` plus 2 runtime tests.
- **What it changes:** the memprof runtime now clears the last (partial) shadow granule of an allocation, so stale counts from a previous allocation do not leak into access histograms.
- **Why:** correct profiles when consumers profile with `-mllvm -memprof-histogram`.
- **Behaviour vs stock 23.1.2:** runtime only (`libclang_rt.memprof*`, shipped for `x86_64-unknown-linux-gnu`), and only with histogram mode. Default profiles are unchanged.
- **Conflicts:** applies cleanly.

Considered, not carried: #221372 (`7f04c2bac295`, thin-link compile-time optimization; touches the public `llvm/ADT/SetOperations.h`) and #214134 (`9a0c255ce1ef`, `!PGOFuncName` → `!guid` metadata; profile/IR churn that would diverge from rustc nightly's LLVM 23.1.1).

## Vendored out-of-tree patches (DeduBB)

DeduBB is "Binary Code Size Reduction via Post-Link Basic Block Deduplication" (LCTES '26,
<https://dl.acm.org/doi/10.1145/3814943.3816169>). It is not upstream in LLVM or in google/llvm-propeller.

### `0100-dedubb-codegen.patch` (LLVM CodeGen + lld)

- **Source:** <https://github.com/chaitanyaupp18/DeduBB>, branch `main`, commit `07d730dab798a18440cd7b6ecca103794a86dfc2`, file `patches/llvm-project-dedubb.patch`. Upstream base `llvm/llvm-project@333edde4e80e` (2026-07-08), an ancestor of `llvmorg-23.1.2`. License Apache-2.0 WITH LLVM-exception.
- **Size:** 4725 lines. New `llvm/lib/CodeGen/DeduBB.cpp` (965), `DeduBBCallReturn.cpp` (1413), `llvm/include/llvm/CodeGen/DeduBBDirectives.h` (193); hooks in `TargetInstrInfo.h`, `X86InstrInfo.*`, `AArch64InstrInfo.*`; edits to `TargetPassConfig.cpp`, `AsmPrinter.cpp`, `MachineFunction.cpp`, `UnreachableBlockElim.cpp`; `lld/ELF/LinkerScript.cpp` (`.text.dedubb` under `-z keep-text-section-prefix`); a clang driver CMake cache variable; 6 lit tests.
- **Local changes:** rebased to 23.1.2 (one hunk offset in `X86InstrInfo.cpp`). The one unconditional behaviour change, where `UnreachableBlockElim` keeps address-taken unreachable blocks, is gated on a non-empty `-dedubb-directives`.
- **Default:** applied by default (`LLVM_DEDUBB=yes` in `vars.sh`; patch header `# requires: LLVM_DEDUBB`). **Inert without a directive file:** every DeduBB pass returns immediately when `-mllvm -dedubb-directives=` is unset, and AsmPrinter/MachineFunction hooks check for an empty directive set. Stage 95 `check_dedubb_inert` pins this.
- **Validation:** applies cleanly to 23.1.2, all patched TUs compile, the patch's 6 lit tests pass on a 23.1.2 `llc`, and 40 related `test/CodeGen/X86` tests pass.

### `src/patches/llvm-propeller/0003-dedubb.patch` (directive generator)

- **Source:** same repo and commit, `patches/llvm-propeller-dedubb.patch` (6567 lines, mostly new files: `tail_call_dedupper`, `save_and_jump_dedupper`, `call_return_dedupper`, `subsequence_dedupper`, writers and tests). Base `google/llvm-propeller@e2c70493656`. Apache-2.0.
- **Local changes:** rebased onto our propeller pin `ddfb8b7cbdb8` (two hunks rejected: the include block of `generate_propeller_profiles.cc` and the `DisassembleOne` overload context in `mini_disassembler.cc`; one hunk dropped because it reverts `MCContext` to the pre-23 pointer API). The spike rebase builds against 23.1.2 and generates correct directives (research notes §2.5).
- **Default:** built into the shipped `generate_propeller_profiles`. New flags (`--dedubb_profile`, `--dedubb_subsequence`, `--dedubb_cold_only`, …) do nothing unless passed.

Not carried: the `bolt-dedubb` branch's BOLT pass (`0e20b1fed23c`). We ship DeduBB through the compiler and Propeller path only.

## Tracking and dropping on the next LLVM bump

For each bump of the `llvm` submodule (23.1.x or 24.x):

1. For each upstream backport, check whether the commit is already in the new tag (`gh api repos/llvm/llvm-project/compare/<newtag>...<sha>` reports `behind` or `identical`, or the patch fails forward and applies in reverse). If so, delete the patch file and its row in `docs/notes/llvm-patches.md`.
2. For DeduBB, rebase `0100-dedubb-codegen.patch` onto the new tag (see `docs/notes/llvm-patches.md` for the procedure), rebuild a scratch `llc`, rerun the 6 DeduBB lit tests, and run stage 95 (`check_dedubb_codegen`, `check_dedubb_inert`). Check the DeduBB repo for a newer commit or an upstream PR. If DeduBB lands upstream, drop the vendored patch in favour of upstream.
3. Patches must not overlap hunks (`apply_patches` detects "already applied" per patch with `git apply --reverse --check`); the unit test in `tests/unit/common.test.sh` pins re-application.
4. Update this issue: one comment per bump listing kept, dropped and rebased patches.

Owners: toolchain maintainers. Labels: `llvm`, `patches`.
