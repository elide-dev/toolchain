# Local patch ledger (LLVM and llvm-propeller)

All local patches are tracked in [elide-dev/toolchain#4](https://github.com/elide-dev/toolchain/issues/4)
(source text: `docs/notes/llvm-backports-issue.md`). Rules (spec D2): one self-contained patch per
feature or backport; patches of one component never overlap hunks; a `# requires: VAR` first
line gates a patch on a `vars.sh` knob. `apply_patches` applies a series in stages 10/30/40 (llvm)
and 45 (llvm-propeller). Stage 00's `unapply_patches` reverses it before the clean-tree check.

## `src/patches/llvm` (base `llvmorg-23.1.2`)

| Patch | Origin | Files | Why | Default | Drop when |
|---|---|---|---|---|---|
| `0001-memprof-deterministic-clone-tiebreak.patch` | llvm/llvm-project#222126 (`8c7d76bfc1b5`) | `MemProfContextDisambiguation.cpp` + tests | Deterministic MemProf cloning | on | the new LLVM tag contains `8c7d76bfc1b5` |
| `0002-memprof-histogram-tail-granule.patch` | llvm/llvm-project#208911 (`c0b8c59b65af`) | `compiler-rt/lib/memprof/memprof_allocator.cpp` + tests | Correct histogram profiles | on | the new tag contains `c0b8c59b65af` |
| `0100-dedubb-codegen.patch` | chaitanyaupp18/DeduBB@`07d730d` `patches/llvm-project-dedubb.patch` | CodeGen (DeduBB passes, hooks), X86/AArch64 InstrInfo, lld LinkerScript, clang driver CMake, 6 lit tests | DeduBB folding (`-mllvm -dedubb-directives=`) | on (`LLVM_DEDUBB`), inert without directives | DeduBB lands upstream |

## `src/patches/llvm-propeller` (base `google/llvm-propeller@ddfb8b7`)

| Patch | Why |
|---|---|
| `0001-find-package-llvm.patch` | Link the stage-2 LLVM via `find_package(LLVM CONFIG)` instead of downloading and building LLVM `db9b595` |
| `0002-quipper-libelf-to-llvm-object.patch` | Apply `quipper/0001-dso-llvm-object.patch` to the fetched quipper tree (build-id reader on LLVM `Object`) and drop libelf |
| `0003-offline-deps.patch` | abseil/protobuf/googletest/quipper from `PROPELLER_DEPS_DIR` (stage 00 cache, sha256-pinned in `versions.env`) |
| `0004-dedubb.patch` | DeduBB directive generation, from DeduBB@`07d730d` `patches/llvm-propeller-dedubb.patch` (base `e2c7049`), rebased; `MCContext` uses the LLVM 23 reference API |

## Bump procedure

1. Backports: if the new tag contains the upstream commit
   (`gh api repos/llvm/llvm-project/compare/<tag>...<sha>` reports `behind` or `identical`), delete
   the patch and its row.
2. DeduBB: rebase `0100` onto the new tag. Build a scratch `llc` and run the 6 `dedubb*.ll` RUN
   lines, then run stage 95 (`check_dedubb_*`).
3. Propeller: on a submodule bump, re-read the dep versions in `CMake/*` and update `versions.env`.
   Rebase `0001`–`0004`, then run stage 45 and its check.
4. Run `tests/run.sh` (series re-apply and unapply tests), then post a comment on #4.
