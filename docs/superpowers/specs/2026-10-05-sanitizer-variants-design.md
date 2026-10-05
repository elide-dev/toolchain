# Sanitizer Variants: Design

**Date:** 2026-10-05
**Status:** Revised 2026-10-05 with the user's decisions (§12)
**Builds on:** `docs/superpowers/specs/2026-10-04-universal-native-toolchain-design.md` (binding; "base spec" below)
**Evidence:** `docs/notes/sanitizer-spikes.md` (throwaway spikes A–H, run on 2026-10-05 against a copy of the complete linux-amd64 build)
**Plan:** `docs/superpowers/plans/2026-10-05-sanitizer-variants.md`

## 1. Intent

A downstream project should be able to build a sanitized binary in which every native layer it
links works with the chosen sanitizer: its own code, the bundle's libc++/libc++abi/libunwind,
the components (zlib-ng, zstd, brotli, snappy, lz4, crc32c, aws-lc, …) and mimalloc. It does so
with one switch, `elide-toolchain env --target T --sanitizer S` or the action's `sanitizer:` input,
and keeps the ThinLTO-everywhere model.

### Success criteria

1. Every runtime in the support matrix (§3) is in the bundle for its triple. A known-bad program
   trips each one in stage 95.
2. On every `*-linux-gnu` triple, ASan, TSan and MSan builds that link libc++ and **every**
   default component run a real workload with **zero** sanitizer reports, with and without
   `-flto=thin`. For MSan this is impossible without instrumented libc++ and components; the
   spikes reproduced the false positives.
3. CMake, pkg-config, autotools and cargo consumers pick up the instrumented libraries without
   hand-written `-L` paths.
4. The main bundle grows by less than 1 % and its existing checks (glibc floor, bitcode,
   relocatability, minos) cover the new files.
5. Nothing changes for consumers who do not ask for a sanitizer.

### Non-goals

- Sanitizing GraalVM native-image output (§7.4: unsupported).
- ASan, TSan, MSan or LSan for musl targets (§3.2: not shipped). musl is **static-only by
  design**; dynamically linked musl executables are neither supported nor needed downstream.
- CFI, SafeStack, DFSan, NSan, TySan, RTSan, MemProf, Scudo, GWP-ASan, XRay. They are cheap to
  add later (spike A built them all on gnu) but no consumer has asked for them.
- Sanitizer-instrumented builds of the shipped clang/lld themselves.

## 2. Decisions

| Topic | Decision | Why (evidence) |
|---|---|---|
| Runtimes | Build compiler-rt sanitizers into the **main** bundle for every triple, subset per §3 | +2.7 MiB xz per gnu triple, about +0.3 MiB per musl triple, against a 525.7 MiB bundle; ~30 s of build per triple (spike A, sizes) |
| Instrumented libraries | **One add-on archive per sanitizer** per Linux bundle: `elide-toolchain-<ver>-linux-<arch>-sanitizer-<san>.tar.xz` for `asan`, `tsan`, `msan` (§4.2). Each has the same root dir, extracts over the main bundle independently of the others, and never overwrites a main-bundle file | Payload per arch (xz): msan 28.1 MiB, asan 24.0 MiB, tsan 15.8 MiB (spike D). Full variant bundles would re-ship 525 MiB of LLVM per sanitizer; putting it all in the main bundle costs +12 % for everyone |
| Which variants | `asan`, `tsan`, `msan`, gnu triples only | MSan needs them (false positives otherwise). ASan/TSan work without them but miss bugs inside libc++/components, and TSan cannot see synchronisation done in uninstrumented code. UBSan and LSan need no instrumented libraries |
| musl | UBSan (standalone + minimal, static) only. musl is **static-only by design** | ASan/TSan/MSan/LSan cannot link `-static` (`_DYNAMIC` undefined); dynamic musl is not a supported or needed configuration; upstream does not test TSan/MSan on musl (spike B) |
| darwin | ASan, TSan, UBSan dylibs in the main bundle; no add-ons | MSan unsupported by clang on Darwin; macOS uses the system libc++, which cannot be swapped; component add-ons are a possible follow-up |
| HWASan | aarch64-gnu runtime only, best effort | x86_64 needs LAM (spike B: `requires a kernel with tagged address ABI`); aarch64 uses TBI but needs the tagged-address ABI (Linux ≥ 5.4). **Unverified on arm64** |
| libFuzzer | **Ship in the main bundle** on gnu triples (and darwin); not on musl | +0.6 MiB xz per gnu triple; fuzzing for Elide/Bali/Komodo native code; on musl its private libc++ build fails (spike A) |
| Selection | Generated POSIX-sh wrappers `bin/<T>-<san>-clang{,++}` that stack `--config` layers on the normal `<T>.cfg`, plus `share/elide-toolchain/cmake/<T>-<san>.cmake` | Prefixed names (`<T>-msan-clang`) are parsed as a bogus triple and suffixes (`<T>-clang-msan`) are ignored by clang; `--config` layering works and can be repeated (spike F) |
| Variant sysroot | `sysroot/<T>+<san>/`: a relative-symlink farm over `sysroot/<T>/`, with the instrumented archives as real files | CMake `find_package`/`find_library` return absolute paths inside `CMAKE_SYSROOT`, bypassing `-L` (spike F) |
| Variant libc++ | `lib/<T>/<san>/libc++{,abi,experimental}.a`, put first on the search path by the variant cfg's `-L`; **no variant libunwind**; ASan adds `include/<T>/asan/c++/v1/__config_site` | An instrumented unwinder recurses forever under MSan (spike C) |
| mimalloc in variants | `libmimalloc.a` in the farm is a **forwarding shim** (`mi_*` → libc allocator, which every sanitizer intercepts) | The shipped `MI_OVERRIDE=ON` archive segfaults under ASan and TSan; `MI_OVERRIDE=OFF` hides `mi_*` blocks from ASan and trips MSan (spike E) |
| Rust | `-Zsanitizer=<s> -Zexternal-clangrt`, linker = the variant wrapper (one runtime: clang's) | Verified with rustc nightly on LLVM 23.1.1, including cross-language ThinLTO; two runtimes give duplicate symbols (spike G) |
| CI | Runtimes (main bundle) on every CI run. Add-ons are built, verified and uploaded **only on push to `main` and on release**, never on PRs | Keeps PR jobs within ~3–5 min of today; add-on regressions surface on the next `main` push (§9) |
| Asset names | Add-ons carry a `-sanitizer-<san>` suffix; the main bundle must stay the unambiguous mise/action match per platform (§5.4) | User decision; mise autodetects one asset per platform |

## 3. Support matrix (LLVM 23.1.2)

Legend: **S** shipped and verified by a spike; **S\*** shipped, follows from compiler-rt CMake
and the clang driver but not yet run; **–** not shipped (reason in notes); `o` = needs that
sanitizer's add-on archive for end-to-end coverage.

| Sanitizer | x86_64-gnu | aarch64-gnu | x86_64-musl | aarch64-musl | arm64-darwin |
|---|---|---|---|---|---|
| ASan (`address`) | **S** `o` static + `.so` | **S\*** `o` | – | – | **S\*** dylib |
| LSan (`leak`, standalone) | **S** | **S\*** | – | – | – (use ASan `detect_leaks=1`; standalone LSan on Darwin is not a supported configuration, **uncertain**) |
| TSan (`thread`) | **S** `o` static + `.so` | **S\*** `o` | – | – | **S\*** dylib |
| MSan (`memory`) | **S** `o` (required) static | **S\*** `o` (required) | – | – | – (driver does not offer it) |
| UBSan (`undefined`, standalone) | **S** static + `.so` | **S\*** | **S** static | **S\*** static | **S\*** dylib |
| UBSan minimal runtime | **S** | **S\*** | **S** static | **S\*** static | **S\*** |
| HWASan (`hwaddress`) | – (needs LAM) | **S\*** best effort | – | – | – |
| libFuzzer (`fuzzer`) | **S** | **S\*** | – | – | **S\*** |

### 3.1 Evidence

- **CMake** (`compiler-rt/cmake/config-ix.cmake`): gating is by `OS_NAME` only, so musl counts as
  Linux. `COMPILER_RT_HAS_MSAN` covers `Linux|FreeBSD|NetBSD` (line 836), `_TSAN` covers
  `Linux|Darwin|FreeBSD|NetBSD` (872), `_HWASAN` covers `Linux|Android|Fuchsia` (800) and `_LSAN`
  covers `…Darwin|Linux…` (829). Static ASan/TSan runtimes exist only on non-Apple platforms
  (813, 883), so Darwin runtimes are dylibs. Arch lists (`AllSupportedArchDefs.cmake`) include
  x86_64 and arm64 for ASan, LSan, TSan, MSan, HWASan, UBSan and libFuzzer.
- **Driver**: `Linux::getSupportedSanitizers` offers all of the above on x86_64 and aarch64 with no
  musl exception. `Darwin::getSupportedSanitizers` offers Address, Leak, Thread, UBSan and Fuzzer,
  but not Memory.
- **Spike A**: every sanitizer runtime **compiles** for both x86_64 triples; only libFuzzer fails on
  musl.
- **Spike B**: on gnu every trigger trips except HWASan (kernel). On musl only static UBSan works on
  the shipped sysroot; with a mallocng `libc.so` every runtime trips its trivial trigger.

### 3.2 Why no ASan/TSan/MSan/LSan on musl

1. musl is **static-only by design**: the musl triple exists to produce fully static executables,
   and every downstream consumer links it statically. Dynamically linked musl executables are not
   a supported or needed configuration, so nothing in this design or its verification exercises
   them.
2. ASan, TSan, MSan and LSan require dynamic linking (`-static` fails to link: `_DYNAMIC`
   undefined, spike B), so they cannot exist on a static-only triple.
3. Upstream compiler-rt does not test TSan or MSan on musl.
4. The libraries are the same on both triples, so consumers lose nothing by sanitizing on the gnu
   triple. UBSan, which links statically, covers musl itself (spike B: trips on the shipped,
   mimalloc-in-`libc.a` musl).

## 4. Packaging

### 4.1 Main bundle additions (all bundles)

```
lib/clang/23/include/sanitizer/*.h                     # asan_interface.h, msan_interface.h, …
lib/clang/23/share/{asan,msan,hwasan,cfi}_ignorelist.txt …
lib/clang/23/lib/<T>/libclang_rt.<rt>.a, .a.syms, .so   # Linux, subset per §3, incl. libFuzzer (gnu)
lib/clang/23/lib/darwin/libclang_rt.{asan,tsan,ubsan}_osx_dynamic.dylib, libclang_rt.fuzzer_osx.a …
share/elide-toolchain/sanitizers/<T>-<san>.cfg          # runtime layer, e.g. "-fsanitize=address"
share/elide-toolchain/sanitizers/supported.json        # {"<T>": {"asan": {"addon": "recommended"}, "msan": {"addon": "required"}, …}}
share/elide-toolchain/cmake/<T>-<san>.cmake             # toolchain file (uses the farm if present)
bin/<T>-<san>-clang, bin/<T>-<san>-clang++              # POSIX-sh wrappers (§5.1)
```

Today the main bundle cannot link any sanitizer program: the runtimes, headers and ignorelists
are missing (spike A). The headers and ignorelists come from the compiler-rt install, and stage 30
installs them into the resource dir.

### 4.2 Sanitizer add-on archives (Linux bundles only)

One archive per sanitizer variant and Linux bundle, `+ .sha256`:

```
elide-toolchain-<ver>-linux-<arch>-sanitizer-asan.tar.xz
elide-toolchain-<ver>-linux-<arch>-sanitizer-tsan.tar.xz
elide-toolchain-<ver>-linux-<arch>-sanitizer-msan.tar.xz
```

(final spelling subject to the mise check in §5.4). Each has one top-level dir,
`elide-toolchain/`, and is extracted **over** the main bundle of the **same** version. Any subset
can be installed, in any order: the archives' path sets are disjoint from each other and from
the main bundle, so extraction never overwrites a file. Contents of the `<san>` add-on
(`G` = `<arch>-unknown-linux-gnu`):

```
lib/<G>/<san>/libc++.a libc++abi.a libc++experimental.a
include/<G>/asan/c++/v1/__config_site                    # asan add-on only (_LIBCPP_INSTRUMENTED_WITH_ASAN 1)
sysroot/<G>+<san>/                                       # symlink farm (§4.3)
share/elide-toolchain/sanitizers/<G>-<san>.addon.cfg     # sysroot/-L/-isystem layer (§5.1)
share/elide-toolchain/sanitizers/<san>.addon.json        # {"sanitizer": "<san>", "version": "...", "revision": "...", "triples": [...]}
```

Sizes, measured on x86_64-gnu (xz -9): msan 28.1 MiB, asan 24.0 MiB, tsan 15.8 MiB (212.0 MiB raw
for all three). aarch64 is assumed similar (**unverified**).

**Alternatives rejected.**
(a) Everything in the main bundle: +12 % download for every consumer, almost none of whom
sanitize.
(b) Full per-sanitizer bundles (`…-linux-amd64-msan.tar.xz` with LLVM included): about 590 MiB
each for about 22 MiB of distinct content, and the action/mise would have to pick among four
"linux-amd64" toolchains.
(c) One combined add-on for all three sanitizers (65 MiB): forces every sanitizer user to
download the other two. Superseded by the per-sanitizer decision.

### 4.3 Variant sysroot farm

`sysroot/<G>+<san>/` (shipped in the `<san>` add-on) mirrors `sysroot/<G>/` entry by entry:

- every top-level entry except `usr/` (e.g. the `lib64/ld-linux-x86-64.so.2` loader link): one
  relative symlink `../<G>/<name>`;
- every `usr/*` except `usr/lib`: one relative symlink `../../<G>/usr/<name>` (headers, `share/`
  and so on are shared);
- every `usr/lib/*`: a relative symlink `../../../<G>/usr/lib/<name>`, **except** the instrumented
  archives (`libz.a`, `libzstd.a`, `libbrotli*.a`, `libsnappy.a`, `liblz4.a`, `libcrc32c.a`,
  `libcrypto.a`, `libssl.a`, plus any other enabled component, and `libmimalloc.a` = shim), which
  are real files.

Consequences, verified in spike F unless marked: `--sysroot=<farm>` keeps glibc, the loader,
kernel headers and glibc's `libc.so` linker script working (C, C++ and component links through
the farm all run). `find_package(ZLIB)` / `find_library(zstd)` under `CMAKE_SYSROOT=<farm>`
return the instrumented archives. pkg-config with `PKG_CONFIG_SYSROOT_DIR=<farm>` should emit
`-L<farm>/usr/lib`, because the `.pc` files say `prefix=/usr` (**not run**). Shared component
libraries are not instrumented, and variants are static-only, so the farm **drops** the `.so`
symlinks whose `.a` was replaced (`libcrypto.so`, `libssl.so`): lld prefers `.so` within a
directory. Spike F's negative control: with `libcrypto.so` restored, the MSan workload reports
`use-of-uninitialized-value`; without it, the run is clean. aws-lc's CMake package files reached
through the farm's `usr/lib/cmake` symlink are **unverified**.

### 4.4 Manifest

`manifest.json` gains:

```json
"sanitizers": {
  "x86_64-unknown-linux-gnu":  { "runtimes": ["asan","lsan","tsan","msan","ubsan","ubsan_minimal","fuzzer"],
                                 "addons": ["asan","tsan","msan"] },
  "x86_64-unknown-linux-musl": { "runtimes": ["ubsan","ubsan_minimal"], "addons": [] }
},
"addons": {
  "asan": "elide-toolchain-2026.10.0-linux-amd64-sanitizer-asan.tar.xz",
  "tsan": "elide-toolchain-2026.10.0-linux-amd64-sanitizer-tsan.tar.xz",
  "msan": "elide-toolchain-2026.10.0-linux-amd64-sanitizer-msan.tar.xz"
}
```

The SBOM is unchanged: same components and versions. The add-ons' archives carry the same
component versions with a `build-variant` property added (open question Q1).

## 5. Selection: front-ends, helper, action, mise

### 5.1 Wrappers and cfg layers

`bin/<T>-<san>-clang` (and `-clang++`), generated by `install_sanitizer_frontends`:

```sh
#!/bin/sh
# <T> + <san>: the base cfg (<T>.cfg, auto-loaded) + the <san> runtime layer + the add-on layer if installed.
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
san=$here/../share/elide-toolchain/sanitizers
if [ -f "$san/<T>-<san>.addon.cfg" ]; then
  exec "$here/<T>-clang" --config="$san/<T>-<san>.cfg" --config="$san/<T>-<san>.addon.cfg" "$@"
fi
# (msan only) echo "…: msan needs its add-on (instrumented libc++ and components)" >&2; exit 2
exec "$here/<T>-clang" --config="$san/<T>-<san>.cfg" "$@"
```

Runtime layer `<T>-<san>.cfg`: `-fsanitize=address` / `thread` / `memory` plus
`-fsanitize-memory-track-origins` / `undefined` / `leak` / `hwaddress`, and `-fno-omit-frame-pointer`.
Add-on layer `<G>-<san>.addon.cfg`, shipped in that sanitizer's add-on (paths relative to
`share/elide-toolchain/sanitizers/`):

```
--sysroot=<CFGDIR>/../../../sysroot/<G>+<san>
-L<CFGDIR>/../../../lib/<G>/<san>
-isystem <CFGDIR>/../../../include/<G>/asan/c++/v1     # asan only
```

Ordering, verified: the default `<T>.cfg` loads first, then explicit `--config`s in order, so the
add-on layer's `--sysroot` wins. The cfg `-L` precedes the driver's `lib/<T>` path. User `-I`/`-L` on
the command line still come first.

The CMake file `<T>-<san>.cmake` is the base toolchain file with the compilers pointed at the
wrappers, and:

```cmake
if(EXISTS "${_ET_ROOT}/sysroot/<T>+<san>/usr/lib")
  set(CMAKE_SYSROOT "${_ET_ROOT}/sysroot/<T>+<san>")
else()
  set(CMAKE_SYSROOT "${_ET_ROOT}/sysroot/<T>")
endif()
```

### 5.2 Helper CLI

```
elide-toolchain env --target T --sanitizer asan|tsan|msan|ubsan|lsan|hwasan [--format sh|github|json]
elide-toolchain sanitizers [--target T]          # list: name, runtime present, add-on installed/required/recommended
elide-toolchain addon install sanitizer-<san> [--from FILE|URL]   # fetch + sha256 + extract one add-on (§5.4)
```

`env --sanitizer S` changes the base output as follows:

| Var | Value |
|---|---|
| `CC`, `CXX` | `bin/<T>-<S>-clang`, `bin/<T>-<S>-clang++` |
| `CMAKE_TOOLCHAIN_FILE` | `share/elide-toolchain/cmake/<T>-<S>.cmake` |
| `PKG_CONFIG_SYSROOT_DIR`, `PKG_CONFIG_LIBDIR` | the farm when the `<S>` add-on is installed, else the base sysroot |
| `CARGO_TARGET_<RT>_LINKER` | `bin/<T>-<S>-clang` |
| `CARGO_TARGET_<RT>_RUSTFLAGS` | `-Zsanitizer=<address|thread|memory|leak|hwaddress> -Zexternal-clangrt` (not emitted for ubsan: Rust has no UBSan) |
| `ELIDE_SANITIZER` | `S` |
| `ELIDE_SANITIZER_RUNTIME` | absolute path of the shared runtime (`libclang_rt.asan.so`, …) where one exists, for `LD_PRELOAD` into uninstrumented hosts such as the JVM |

Errors: unknown or unsupported (T, S), e.g. `--target x86_64-unknown-linux-musl --sanitizer asan`
→ `asan is not supported for musl targets (musl is static-only); use x86_64-unknown-linux-gnu`.
`--static` with any sanitizer except ubsan → error. `msan` without its add-on → error naming the
asset (`elide-toolchain-<ver>-<os>-<arch>-sanitizer-msan.tar.xz`). `<S>.addon.json` version ≠
bundle `VERSION` → error. `asan`/`tsan` without their add-on → a warning on stderr ("libc++ and
components are not instrumented; install the sanitizer-<S> add-on for full coverage"), and the
output is still emitted.

### 5.3 GitHub Action

New input `sanitizer: asan|tsan|msan|ubsan|lsan|hwasan` (requires `target`). For a sanitizer that
has an add-on on the runner's platform (asan, tsan, msan on Linux), the action resolves, downloads,
checksum-verifies and extracts **that one** add-on over the main bundle, with the same resolution,
`.sha256` check and R2 fallback as the main bundle and before `tc.cacheDir`. It then applies
`elide-toolchain env --target T --sanitizer S`. A missing add-on is an error for msan and a warning
for asan/tsan, matching the helper. New output `sanitizer-addon`: the installed add-on asset name,
or empty. For testing, `sanitizer-archive` installs the add-on from a local file, mirroring
`archive`.

### 5.4 mise and asset naming

mise installs one asset per platform and only provides `PATH`. Add-ons reach mise users through
`elide-toolchain addon install sanitizer-<san>`, which downloads the release asset matching the
bundle's own version and platform (GitHub release, then R2), verifies its `.sha256` and extracts
it over the bundle.

**The main bundle must stay the unambiguous match** for `github:elide-dev/toolchain` on every
platform. Whether mise's autodetection (`src/backend/asset_matcher.rs`, see
`docs/notes/mise-assets.md`) ranks `…-linux-amd64.tar.xz` above `…-linux-amd64-sanitizer-asan.tar.xz`
is **not verified**. The plan's first task decides it from mise's matcher code and tests, with a
release-time guard (§9):

- If the main bundle provably wins, keep `…-sanitizer-<san>.tar.xz`.
- Otherwise, rename the add-ons so that mise cannot select them. Prefer a non-archive extension,
  e.g. `elide-toolchain-<ver>-<os>-<arch>-sanitizer-<san>.addon` (an xz-compressed tar). mise
  ranks a recognised archive above it, and the action and helper fetch add-ons by exact name, so
  the extension does not matter to them.

The README's mise snippet stays as it is. Add-ons never change which asset mise picks.

## 6. Build pipeline

### 6.1 Configuration

`versions.env` (shared floors and policy):

```
SANITIZERS_LINUX_GNU="asan lsan tsan msan ubsan"
SANITIZERS_LINUX_GNU_AARCH64="hwasan"
SANITIZERS_LINUX_MUSL="ubsan"
SANITIZERS_DARWIN="asan tsan ubsan"
SANITIZER_VARIANTS="asan tsan msan"
LIBFUZZER_LIBCS="gnu darwin"            # libFuzzer ships in the main bundle for these libcs
```

`vars.sh`: `BUILD_SANITIZERS=${BUILD_SANITIZERS:-yes}` (runtimes, incl. libFuzzer, in the main
bundle, on every build) and `BUILD_SANITIZER_VARIANTS=${BUILD_SANITIZER_VARIANTS:-no}` (Linux
add-ons). CI sets the latter to `yes` only on push to `main` and on release (§9); developers opt
in locally. Verification skips what was not built and prints a notice.

### 6.2 Stage 30 (runtimes): pass 3, sanitizer runtimes

After `build_cxx_runtimes "$t"` (pass 3 needs the installed libc++ for libFuzzer and the
`*_cxx` runtimes), add `build_sanitizer_runtimes "$t"`. It runs the same `runtimes_common_args`
with:

```
-DLLVM_ENABLE_RUNTIMES=compiler-rt
-DCOMPILER_RT_BUILD_BUILTINS=OFF -DCOMPILER_RT_BUILD_CRT=OFF -DCOMPILER_RT_BUILD_PROFILE=OFF
-DCOMPILER_RT_BUILD_SANITIZERS=ON -DCOMPILER_RT_SANITIZERS_TO_BUILD="<asan;msan;tsan;ubsan_minimal[;hwasan]>"
-DCOMPILER_RT_BUILD_LIBFUZZER=<ON gnu / OFF musl> -DCOMPILER_RT_BUILD_GWP_ASAN=OFF -DCOMPILER_RT_BUILD_MEMPROF=OFF
-DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON -DSANITIZER_CXX_ABI=libc++ -DSANITIZER_TEST_CXX=libc++
-DCOMPILER_RT_INCLUDE_TESTS=OFF
CMAKE_CXX_FLAGS += -stdlib=libc++
CMAKE_{EXE,SHARED,MODULE}_LINKER_FLAGS = "-rtlib=compiler-rt -unwindlib=libunwind -stdlib=libc++ -fuse-ld=lld"
```

On musl, `COMPILER_RT_SANITIZERS_TO_BUILD="ubsan_minimal"`. compiler-rt always builds lsan and
ubsan when sanitizers are on, so a pruning step deletes `libclang_rt.lsan*` from musl resource
dirs. The headers (`include/sanitizer`) and `share/*_ignorelist.txt` are installed by the same
`cmake --install`. It installs into both prefixes, as stage 30 already does. Added time: about 30
s per triple on 32 threads.

compiler-rt sanitizers stay **native-only**. The base spec's §3.3a exemption for compiler-rt
already covers them, and `check_bitcode` already skips the resource dir.

### 6.3 Stage 10 (darwin)

`llvm_darwin` flips `COMPILER_RT_BUILD_SANITIZERS=ON` and `COMPILER_RT_BUILD_LIBFUZZER=ON`,
adds `-DCOMPILER_RT_SANITIZERS_TO_BUILD="asan;tsan;ubsan_minimal"` and
`-DSANITIZER_MIN_OSX_VERSION=$MACOS_MIN`, and keeps iOS/watchOS/tvOS/xrOS off. Output:
`lib/clang/23/lib/darwin/libclang_rt.{asan,tsan,ubsan,lsan}_osx_dynamic.dylib`, `…fuzzer_osx.a`.
`check_macos_minos` and `check_darwin_dylibs` already cover them. Time and signing are
**unverified**.

### 6.4 New stage 60: sanitizer variants (Linux, gnu triples only)

`scripts/stages/60-sanitizer-variants.sh`, between `50-components` and `90-package`. It uses the
bundle's stage-2 clang (`TOOLCHAIN_ROOT=$BUNDLE_DIR`, like stage 50). For each gnu triple in
`$TARGETS` and each `san` in `$SANITIZER_VARIANTS`:

1. The runtime cfg, wrappers and CMake file for (t, san) already exist (main bundle,
   `install_frontends`). Components need the runtime cfg in step 3. The add-on layer cfg is
   written last (step 6).
2. `build_variant_cxx t san` runs `llvm/runtimes` with `libunwind;libcxxabi;libcxx`, the stage-30
   cxx options, `-DLLVM_USE_SANITIZER=<Address|Thread|MemoryWithOrigins>` and
   `-DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=OFF`. It installs to a staging prefix
   and copies `libc++.a`, `libc++abi.a` and `libc++experimental.a` to `lib/<t>/<san>/`. For asan
   only, it also copies `include/<t>/c++/v1/__config_site` to `include/<t>/asan/c++/v1/`. It
   **never** copies `libunwind.a`.
3. `build_variant_components t san` calls every enabled `build_<component>` with
   `SANITIZER_LAYER=<san>` exported into a staging prefix `$BUILD_DIR/variants/<t>/<san>/usr`.
   `target_cflags` in `flags.sh` prepends `--config=<abs>/share/elide-toolchain/sanitizers/<t>-<san>.cfg`
   when `SANITIZER_LAYER` is set. Recipes need two hooks:
   `component_variant_args aws-lc msan` → `-DOPENSSL_NO_ASM=1` (and aws-lc builds static only in
   variants), and `openssl` (if enabled) → `no-asm` for msan. Shared libraries are not produced.
4. `build_mimalloc_shim t san` compiles `src/mimalloc-sanitizer-shim.c` with the runtime cfg and
   `-flto=thin` into `libmimalloc.a`.
5. `assemble_variant_sysroot t san` builds the farm (§4.3) from the staging archives plus the
   shim, and removes the farm's symlinks for `.so` files whose `.a` was replaced.
6. `install_sanitizer_addon_frontends` writes `<t>-<san>.addon.cfg`.

Measured on 32 threads: about 1 min per (triple, sanitizer), i.e. about 3 min per gnu triple
(spikes C and D).

### 6.5 Stage 90 (package)

`addon_paths S` lists the bundle paths of the `S` add-on (§4.2). The main archive excludes the
union of `addon_paths` over all variants. The `S` add-on archive contains exactly `addon_paths S`
plus `share/elide-toolchain/sanitizers/<S>.addon.json`. Both come from the one function, so the
lists cannot drift. One archive and one `.sha256` per built variant. Stage 90 asserts that the
`addon_paths` sets are pairwise disjoint. `relocate_prefix` needs nothing for the farms: their
`.pc` files are symlinks to relocated files. `manifest.json` gets the `sanitizers` and `addons`
sections. When `BUILD_SANITIZER_VARIANTS=no`, `addons` is empty and only the main archive is
written.

### 6.6 Library changes

| File | Change |
|---|---|
| `scripts/lib/platform.sh` | `triple_sanitizers T` (from `versions.env`), `triple_variants T`, `san_flag S` (asan→address …), `san_cmake S` (asan→Address, msan→MemoryWithOrigins, tsan→Thread), `san_symbol S` (`__asan_` …) |
| `scripts/lib/frontends.sh` | `render_san_cfg`, `render_san_addon_cfg`, `render_san_wrapper`, `render_san_toolchain_cmake`, `install_sanitizer_frontends` (runtime layers for every supported (T,S) go in the main bundle), `install_sanitizer_addon_frontends` (stage 60) |
| `scripts/lib/flags.sh` | `target_cflags` honours `SANITIZER_LAYER` |
| `scripts/lib/components.sh` | `component_variant_args NAME SAN` |
| `src/elide-toolchain` | `--sanitizer`, `sanitizers`, `addon install` |
| `src/mimalloc-sanitizer-shim.c` | new |
| `build.sh` | `60-sanitizer-variants` in `STAGES` and usage text |

## 7. Interplay

### 7.1 mimalloc

- **Sanitizers own `malloc`.** ASan, TSan, MSan, LSan and HWASan intercept the libc allocator. An
  allocator that also defines `malloc` (`MI_OVERRIDE=ON`, the gnu `libmimalloc.a`) crashes at
  startup as soon as its object is pulled in. Spike E: ASan SIGSEGV; TSan SIGSEGV in the
  `pthread_mutex_lock` interceptor during `mi_process_init`.
- **Variants** ship the forwarding shim, which gives full visibility and has no false positives
  (spike E). Main-bundle users of plain `-fsanitize=…` must not link `-lmimalloc` with
  sanitizers. The README says so; the variant wrappers make it moot once the add-on is installed.
- **musl `libc.a`** embeds mimalloc. That is irrelevant to musl UBSan, which does not replace the
  allocator (spike B: static UBSan trips on the shipped musl).
- **Rust `mimalloc` crate** vendors its own mimalloc (`libmimalloc-sys`). Consumers must disable
  the `#[global_allocator]` under sanitizers (a cargo feature; `cfg(sanitize = "…")` is unstable).

### 7.2 ThinLTO

- Instrumentation runs per module during the pre-link compile, so bitcode archives keep the
  instrumentation decided when they were compiled. Spike B/D: ASan with `-flto=thin` over bitcode
  components plus fat-LTO libc++ trips correctly. Variant links with `-flto=thin` are clean for
  all three sanitizers.
- LLVM refuses to inline across mismatched `sanitize_*` function attributes (CompatRule
  `isEqual` on the sanitizer attributes in `llvm/include/llvm/IR/Attributes.td`). Uninstrumented
  bitcode therefore cannot be inlined into instrumented code and silently weaken it. **Uncertain**:
  read from source, not tested in isolation.
- In an MSan ThinLTO link, uninstrumented bitcode (the base sysroot's components) still yields
  false positives (spike B). This is why the farm, not the base sysroot, must be on the path.
- Variant libc++ stays fat ThinLTO, like the main one. Variant components stay pure ThinLTO
  bitcode, so a variant link needs lld (same contract as the base spec).
- `-fsanitize=cfi` (needs LTO) is out of scope.

### 7.3 Rust

- Needs nightly (`-Zsanitizer`), with rustc's LLVM major ≤ the bundle's (base spec §5.3).
  Verified: rustc 1.101.0-nightly (2026-09-29), LLVM 23.1.1.
- **One runtime.** Either rustc links its own (`librustc-nightly_rt.<san>.a`, with the linker not
  given `-fsanitize`), or clang links the bundle's (`-Zexternal-clangrt` + the variant wrapper as
  linker). The helper emits the second because it also brings in the variant libc++/sysroot. Both
  together fail with duplicate `__asan::` symbols (spike G).
- Cross-language ThinLTO (`-Clinker-plugin-lto`) works with both (spike G).
- MSan and TSan need an instrumented `std` (`-Zbuild-std --target <T>`); otherwise MSan reports
  false positives in `std` and TSan misses its synchronisation. Untested here (**uncertain**).
- Pass `--target` explicitly so the target-scoped `CARGO_TARGET_<T>_RUSTFLAGS` do not apply to
  build scripts and proc-macros.

### 7.4 GraalVM native-image: unsupported

Native-image links an uninstrumented Substrate VM image (its own GC, heap reservations and signal
handling) and, on the musl path, links `-static`. ASan, TSan, MSan, LSan and HWASan need dynamic
linking, their fixed shadow mappings, and control over SIGSEGV. They are **unsupported** for
native-image output, and `elide-toolchain env` does not try to make them work. UBSan (minimal or
standalone static runtime) in C code that native-image links is plausible but **unverified**.
This applies equally to Elide and Komodo, the two native-image consumers. What they **can**
sanitize is the JNI and native libraries they build with the toolchain: in ordinary test
executables on the gnu triple and, for JVM-hosted JNI libraries, built with `-shared-libsan`
with the runtime `LD_PRELOAD`ed (spike H; §11.1).

### 7.5 musl vs glibc

See §3.2. musl is static-only by design and gets UBSan only, which works fully static, including with the
mimalloc-in-`libc.a` sysroot. glibc gets the full set. The glibc floor holds for every shared
runtime (max `GLIBC_2.34`; spike H), and `check_glibc_floor` already scans `lib/**/*.so`.

### 7.6 darwin

Runtimes only: ASan, TSan, UBSan dylibs and libFuzzer, built in stage 10 with deployment target
12.0. Clang links the dylibs with an absolute `-rpath` into the bundle's resource dir, so
sanitized test binaries are not relocatable with the bundle. That is acceptable for test
binaries; document it. No MSan. The system libc++ cannot be swapped for an instrumented one, but
ASan and TSan do not need that. Instrumented-component add-ons for darwin are a follow-up if
asked.

## 8. Verification (stage 95 and `tests/stages/*.check.sh`)

Stage 95 extracts the main archive and, when built, **each** add-on over it (each one is also
checked alone: extract main + that add-on into a fresh dir and rerun its variant checks, which
proves add-ons are independent), then runs:

| Check | What |
|---|---|
| `check_sanitizer_runtimes ROOT T` | Every runtime in `triple_sanitizers T` exists (static, `.syms`, `.so` where applicable), libFuzzer on gnu, plus `include/sanitizer/asan_interface.h` and the ignorelists; musl has **no** `libclang_rt.{asan,tsan,msan,lsan}*` |
| `check_sanitizer_trips ROOT T` | For each supported S: compile `tests/fixtures/sanitizers/<S>.c` with `bin/<T>-<S>-clang` (musl: `-static`), run it; expect non-zero exit **and** the report string (`heap-buffer-overflow`, `data race`, `use-of-uninitialized-value`, `signed integer overflow`, `detected memory leaks`, `tag-mismatch`). hwasan is skipped with a notice unless `prctl(PR_GET_TAGGED_ADDR_CTRL)` succeeds |
| `check_sanitizer_static_policy ROOT T` | gnu: `asan` with `-static` fails to link; `elide-toolchain env --static --sanitizer asan` exits non-zero |
| `check_sanitizer_variant_clean ROOT G S` | Via the wrapper, link `clean.cpp`, `exc.cpp` and `workload.c` (every enabled component through `component_link`), each with and without `-flto=thin`. Each must exit 0 with an empty sanitizer log. This is the false-positive check |
| `check_sanitizer_variant_instrumented ROOT G S` | Every real file in `sysroot/<G>+<S>/usr/lib` and `lib/<G>/<S>/` references `san_symbol S` (`llvm-nm`); no `libunwind.a` in `lib/<G>/<S>/`; every farm symlink resolves; the farm has no `.so` whose `.a` was replaced |
| `check_sanitizer_cmake ROOT G S` | A two-line CMake project with `find_package(ZLIB)` under `<G>-<S>.cmake` reports a path under `sysroot/<G>+<S>/` and its binary runs clean |
| `check_sanitizer_mimalloc ROOT G` | `mimalloc-oob.c` trips under the asan variant; `mimalloc-api.c` runs clean under tsan and msan |
| `check_sanitizer_shared ROOT G` | `-shared-libsan` `.so` `dlopen`ed by an uninstrumented host trips with `LD_PRELOAD=$ELIDE_SANITIZER_RUNTIME` |
| `check_rust_sanitizer ROOT G` | When `rustc +nightly` is on PATH (CI installs it): `-Zsanitizer=address -Zexternal-clangrt` with the wrapper as linker, C part compiled by the bundle; trips. Skip with a notice otherwise |
| existing `check_bitcode` | Extended to the farms' real files and `lib/<G>/<S>/*.a` (bitcode producer major = `LLVM_MAJOR`) |
| existing `check_relocatable` | Also reruns one variant trip (`asan`) after moving the extracted tree to a path containing a space |
| existing `check_glibc_floor`, `check_no_build_paths` | Already scan the new files; add-ons included |
| `check_addon_disjoint` | `tar -tJf` of the main archive and each add-on: no path appears in two archives; each add-on has the single `elide-toolchain/` root |

`elide-toolchain doctor` gains `--sanitizers`, which runs the trip and clean checks for every
installed (T, S).

## 9. CI impact

| Item | Where | Estimate |
|---|---|---|
| Stage 30 pass 3 (runtimes + libFuzzer) | every run, Linux | ~30 s per triple × 2 on 32 threads; ×2–4 on smaller runners → +2–4 min per Linux job |
| Stage 10 darwin sanitizers | every run, darwin | +3–6 min on `macos-15` (**unverified**) |
| Main-bundle sanitizer checks (trips, shared runtime, static policy) | every run | +1–2 min |
| Stage 60 (add-ons) | push to `main`, release | ~3 min on 32 threads → +6–12 min per Linux job (runner core count **uncertain**) |
| Packaging three add-ons (xz -9, ~210 MiB raw) and their checks | push to `main`, release | +3–5 min |
| **Total** | | PRs: Linux +3–6 min, darwin +5–8 min. Push/release: Linux about +12–20 min |
| Artifacts | | main bundle +~3 MiB per Linux arch; add-ons 28.1 + 24.0 + 15.8 MiB per Linux arch (push/release only) |

Matrix: unchanged, with the same three jobs. `job.build.yml` gets a boolean input
`sanitizer-addons` that sets `BUILD_SANITIZER_VARIANTS=yes`. `on.push.yml` (branch `main`) and
`on.release.yml` pass `true`; `on.pr.yml` leaves it `false`. On push to `main` the add-ons are
uploaded as workflow artifacts. On release they are attached to the GitHub Release with their
`.sha256`s and mirrored to R2 under `toolchain/<version>/`.

`job.action-e2e.yml` gains one leg per Linux arch on push/release: `sanitizer: msan` with
`target: <arch>-unknown-linux-gnu`. It compiles and runs the trigger and the clean workload
through the action-provided env. On release, a mise guard installs
`github:elide-dev/toolchain@<ver>` on each platform and asserts that the installed tree is the
main bundle (`bin/clang` present, no `sysroot/*+*`). This is the §5.4 guarantee.

Trade-off accepted: a PR that breaks a component recipe under a sanitizer is caught on the next
`main` push, not on the PR. Contributors can run `BUILD_SANITIZER_VARIANTS=yes ./build.sh` locally.

## 10. musl is static-only

Spike B observed that a dynamically linked musl executable does not start on the shipped sysroot.
musl here is **static-only by design**: downstream links it statically, and dynamic musl is not a
supported or needed configuration. This is not a defect, the design adds no dynamic-musl
verification, and the helper refuses dynamic-only sanitizers for musl targets (§5.2).

## 11. Consumer integration notes

Elide, Bali and Komodo all use the same clang toolchain. Elide and Komodo also ship GraalVM
native-image binaries, which cannot be sanitized with ASan/TSan/MSan/LSan (§7.4). The JNI and
native libraries all three build with the toolchain can be.

### 11.1 Elide (labs/WHIPLASH: Rust + GraalVM native-image + JNI/ACCP) and Komodo (GraalVM native-image + JNI/native libraries)

- Native-image binaries: no ASan/TSan/MSan/LSan (§7.4). Sanitize the Rust crates and C/JNI
  sources through **test executables** on `x86_64-unknown-linux-gnu`:
  `eval "$(elide-toolchain env --target x86_64-unknown-linux-gnu --sanitizer asan)"; cargo +nightly test --target x86_64-unknown-linux-gnu`.
  In CI: `uses: elide-dev/toolchain/action@<ref>` with `target:` and `sanitizer: asan`.
- JVM-hosted JNI libraries (incl. ACCP): build with `-shared-libsan`, run the JVM with
  `LD_PRELOAD=$ELIDE_SANITIZER_RUNTIME` and
  `ASAN_OPTIONS=detect_leaks=0:handle_segv=0:allow_user_segv_handler=1`. The JVM uses SIGSEGV for
  safepoints and implicit null checks. Spike H verified the preload shape with a stand-in host,
  not a JVM (**uncertain**).
- ACCP builds its own aws-lc. Whether a build links the bundle's `libcrypto.a` or ACCP's copy
  decides whether the instrumented aws-lc in the farm is used (**uncertain**; check each build).
- CMake-built native libraries: `-DCMAKE_TOOLCHAIN_FILE=$(elide-toolchain home)/share/elide-toolchain/cmake/<T>-<S>.cmake`,
  or take `CMAKE_TOOLCHAIN_FILE` from `env`.
- Release builds stay on the static musl triple; sanitizer jobs use the gnu triple. musl native
  code can still use UBSan statically.
- Disable the Rust `mimalloc` global allocator in sanitizer builds (§7.1).
- MSan on Rust needs `-Zbuild-std`; start with ASan + UBSan, then TSan.

### 11.2 Bali (labs/crema-jit: Rust + C)

- ASan + UBSan first: JIT-emitted code is invisible to ASan, which is fine. MSan: memory written by
  JIT code looks uninitialised; unpoison JIT outputs at the boundary (`__msan_unpoison`, from
  `<sanitizer/msan_interface.h>`, now shipped) or exclude MSan. TSan cannot see JIT code's memory
  accesses, so do not expect race detection inside generated code.
- libFuzzer ships in the main bundle (gnu). `cargo fuzz` builds its own libFuzzer through
  `libfuzzer-sys`, which compiles C++ with `$CXX`, so the wrapper's variant libc++ is used. C
  fuzz targets can use `-fsanitize=fuzzer,address` with `bin/<T>-asan-clang`.
- C parts built by `cc`/`cmake` crates pick up `CC`/`CXX`/`CMAKE_TOOLCHAIN_FILE` from `env`.

## 12. Decisions recorded and open questions

Decided by the user (2026-10-05):

- Dynamic musl is not supported or needed; musl is static-only (§3.2, §10).
- One add-on archive per sanitizer, each independently extractable over the main bundle; action
  input `sanitizer:` and `elide-toolchain env --sanitizer S` (§4.2, §5).
- libFuzzer ships in the main bundle on gnu triples (§3, §6.2).
- Add-ons are built and published only on push to `main` and on release, not on PRs (§9).
- Add-on assets may be renamed so that the main bundle stays mise's unambiguous match (§5.4).
- Komodo is treated like Elide: native-image unsupported, JNI/native libraries sanitizable (§11).

Still open:

- **Q1.** SBOM: a separate SBOM per add-on, or one SBOM with variant properties?
- **Q2.** Should ASan/TSan without their add-on be an error rather than a warning in
  `elide-toolchain env`? Recommended: warning.
- **Q3.** darwin: are instrumented-component add-ons wanted (ASan/TSan only)?
