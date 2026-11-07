# Local patch ledger (LLVM and llvm-propeller)

This file is the maintained patch ledger, superseding the original
[elide-dev/toolchain#4](https://github.com/elide-dev/toolchain/issues/4) tracker
(source text: `docs/notes/llvm-backports-issue.md`). Rules (spec D2): one self-contained patch per
feature or backport; patches of one component never overlap hunks; a `# requires: VAR` first
line gates a patch on a `vars.sh` knob. `apply_patches` applies a series in stages 10/30/40 (llvm)
and 45 (llvm-propeller). Stage 00's `unapply_patches` reverses it before the clean-tree check.

## `src/patches/llvm` (base `llvmorg-23.1.4`)

| Patch | Origin | Files | Why | Default | Drop when |
|---|---|---|---|---|---|
| `0001-memprof-deterministic-clone-tiebreak.patch` | llvm/llvm-project#222126 (`8c7d76bfc1b5`) | `MemProfContextDisambiguation.cpp` + tests | Deterministic MemProf cloning | on | the new LLVM tag contains `8c7d76bfc1b5` |
| `0002-memprof-histogram-tail-granule.patch` | llvm/llvm-project#208911 (`c0b8c59b65af`) | `compiler-rt/lib/memprof/memprof_allocator.cpp` + tests | Correct histogram profiles | on | the new tag contains `c0b8c59b65af` |
| `0100-dedubb-codegen.patch` | chaitanyaupp18/DeduBB@`07d730d` `patches/llvm-project-dedubb.patch` | CodeGen (DeduBB passes, hooks), X86/AArch64 InstrInfo, lld LinkerScript, clang driver CMake, 6 lit tests | DeduBB folding (`-mllvm -dedubb-directives=`) | on (`LLVM_DEDUBB`), inert without directives | DeduBB lands upstream |
| `0200-linux-fat-lto-objects-default.patch` | local, [#13](https://github.com/elide-dev/toolchain/issues/13), [#18](https://github.com/elide-dev/toolchain/issues/18) | `clang/lib/Driver/ToolChains/CommonArgs.cpp`, `clang/test/Driver/elide-fat-lto-objects-default.c` | Linux in-process LTO links default to lld `--fat-lto-objects`; index-only links retain native archive members for distributed backends; explicit opt-in/out overrides either default | on | never (bundle policy); drop only if the archives stop being fat |

## `src/patches/llvm-propeller` (base `google/llvm-propeller@ea240c1`)

| Patch | Why |
|---|---|
| `0001-find-package-llvm.patch` | Link the stage-2 LLVM via `find_package(LLVM CONFIG)` instead of downloading and building LLVM `db9b595` |
| `0002-quipper-llvm-object-no-libelf-libcrypto.patch` | Apply `quipper/0001-llvm-object-md5.patch` to the fetched quipper tree (build IDs via LLVM `Object`, MD5 via LLVM) and drop libelf, libz and libcrypto |
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
4. Run `tests/run.sh` (series re-apply and unapply tests), then update this ledger in the same change.

## 2026-10-31: LLVM 23.1.4 / toolchain 2026.10.5

Upgraded from 23.1.2 for Xcode 27 SDK `arm64e.x1` TAPI support
([upstream backport #224185](https://github.com/llvm/llvm-project/pull/224185)).
All three LLVM patches apply in order without changes to the 23.1.4 sources;
both MemProf backports are still needed. Propeller and quipper pins and patches
are unchanged; their complete patch series also apply cleanly. Full compilation,
DeduBB checks, and platform smoke tests run in the release workflow.

The distribution root now carries `rustversion`: `nightly-2026-10-09`
(rustc `a30aa9064`, LLVM 23.1.3). A native arm64 program linked with that Rust
linker against the installed macOS 27.2 SDK, CoreFoundation, libiconv, and
libSystem and ran successfully. Rust LLD was invoked directly with its toolchain
`lib` directory in `DYLD_LIBRARY_PATH` for this probe; consumers should continue
to use the bundle clang/lld wrappers.

The initial 2026.10.4 release attempt stopped at submodule checkout because
persistent CI worktrees still contained the previous LLVM patches. 2026.10.5
forces checkout of the pinned submodule revisions before the existing cleanup.

## 2026-11 refresh

LLVM remains at the latest published release, 23.1.4. All three LLVM patches still
apply and remain necessary. Propeller advances to `ea240c1`; patch 0001 now replaces
its updated LLVM snapshot `260f2eb1`, and patches 0002–0004 apply without changes.
Propeller's CMake dependency versions remain unchanged.

The SQLite JNI shim now carries `src/patches/sqlite-jni/0001-jdbc-3.54.1-jni-lifetime.patch`,
backporting the two NativeDB.c fixes from sqlite-jdbc 3.54.1.0: keep an already-open
handle valid on duplicate open, and pass the pinned Java-array pointer to
`ReleasePrimitiveArrayCritical`. Drop it when a new sqlite-jni pin includes both fixes.

## 2026-11: fat-object LTO by default (#13)

`0200-linux-fat-lto-objects-default.patch` changes `addLTOOptions` so that `-ffat-lto-objects`
defaults to on at link time for Linux triples. lld then reads `.llvm.lto` from the fat archives
on in-process `-flto` links. The compile-side default is unchanged: `-flto=thin -c` still emits plain
bitcode. Darwin and non-LTO links are unaffected. The prebuilt stage-1 compiler is unpatched,
so internal builds keep their current link behavior. Stage 95's `check_fat_lto` covers this.

Issue #18 exposed that distributed index-only links cannot import archive-member
paths into Bazel's backend sandboxes. Since 2026.11.4 the default is disabled when
`thinlto-index-only` (with or without an output path) is forwarded through `-Wl,`
or `-Xlinker`, using either lld's direct spelling or its `plugin-opt` alias.
2026.11.4 missed split plugin options such as Bazel's
`-Wl,-plugin-opt,thinlto-index-only=path`. Since 2026.11.5 the driver also
recognizes separate plugin values across `-Wl,`, `-Xlinker`, and mixed forwarding
forms, matching lld's plugin-option normalization.
Explicit `-ffat-lto-objects` still opts in; `-fno-fat-lto-objects` opts out.
The driver regression covers both forwarding forms and architectures. Stage 95's
distributed ThinLTO regression exercises actual imports, isolated backends, a
final-link response file with Bazel's prefix/suffix rewriting, executable and
shared-library links, both opt-outs, and an explicit fat-LTO negative control.
