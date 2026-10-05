# Sanitizer Variants: Design

**Date:** 2026-10-05
**Status:** Draft for review
**Builds on:** `docs/superpowers/specs/2026-10-04-universal-native-toolchain-design.md` (binding; "base spec" below)
**Evidence:** `docs/notes/sanitizer-spikes.md` (throwaway spikes A–H, run on 2026-10-05 against a copy of the complete linux-amd64 build)
**Plan:** `docs/superpowers/plans/2026-10-05-sanitizer-variants.md`

## 1. Intent

A downstream project should be able to build a sanitized binary in which every native layer it
links works with the chosen sanitizer: its own code, the bundle's libc++/libc++abi/libunwind,
the components (zlib-ng, zstd, brotli, snappy, lz4, crc32c, aws-lc, …) and mimalloc. It does so
with one switch, `elide-toolchain env --target T --sanitizer S` or the equivalent action input,
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
- ASan, TSan, MSan or LSan for musl targets (§3.2: not shipped).
- CFI, SafeStack, DFSan, NSan, TySan, RTSan, MemProf, Scudo, GWP-ASan, XRay. They are cheap to
  add later (spike A built them all on gnu) but no consumer has asked for them.
- Sanitizer-instrumented builds of the shipped clang/lld themselves.

## 2. Decisions

| Topic | Decision | Why (evidence) |
|---|---|---|
| Runtimes | Build compiler-rt sanitizers into the **main** bundle for every triple, subset per §3 | +2.7 MiB xz per gnu triple, about +0.3 MiB per musl triple, against a 525.7 MiB bundle; ~30 s of build per triple (spike A, sizes) |
| Instrumented libraries | Ship them in a **separate overlay archive** per Linux bundle: `elide-toolchain-<ver>-linux-<arch>-sanitizers.tar.xz`, with the same root dir and extracted over the main bundle | Real payload is 63.6 MiB xz (asan+tsan+msan, gnu). Full variant bundles would re-ship 525 MiB of LLVM per sanitizer; putting it all in the main bundle costs +12 % for everyone (spike D) |
| Which variants | `asan`, `tsan`, `msan`, gnu triples only | MSan needs them (false positives otherwise). ASan/TSan work without them but miss bugs inside libc++/components, and TSan cannot see synchronisation done in uninstrumented code. UBSan and LSan need no instrumented libraries |
| musl | UBSan (standalone + minimal, static) only | ASan/TSan/MSan/LSan cannot link `-static` (`_DYNAMIC` undefined); dynamically linked musl executables crash today (§10); upstream does not test TSan/MSan on musl (spike B) |
| darwin | ASan, TSan, UBSan dylibs in the main bundle; no overlay | MSan unsupported by clang on Darwin; macOS uses the system libc++, which cannot be swapped; components overlay is a possible follow-up |
| HWASan | aarch64-gnu runtime only, best effort | x86_64 needs LAM (spike B: `requires a kernel with tagged address ABI`); aarch64 uses TBI but needs the tagged-address ABI (Linux ≥ 5.4). **Unverified on arm64** |
| libFuzzer | Ship on gnu triples (and darwin); not on musl | +0.6 MiB xz; Bali/Komodo fuzzing; on musl its private libc++ build fails (spike A) |
| Selection | Generated POSIX-sh wrappers `bin/<T>-<san>-clang{,++}` that stack `--config` layers on the normal `<T>.cfg`, plus `share/elide-toolchain/cmake/<T>-<san>.cmake` | Prefixed names (`<T>-msan-clang`) are parsed as a bogus triple and suffixes (`<T>-clang-msan`) are ignored by clang; `--config` layering works and can be repeated (spike F) |
| Variant sysroot | `sysroot/<T>+<san>/`: a relative-symlink farm over `sysroot/<T>/`, with the instrumented archives as real files | CMake `find_package`/`find_library` return absolute paths inside `CMAKE_SYSROOT`, bypassing `-L` (spike F) |
| Variant libc++ | `lib/<T>/<san>/libc++{,abi,experimental}.a`, put first on the search path by the variant cfg's `-L`; **no variant libunwind**; ASan adds `include/<T>/asan/c++/v1/__config_site` | An instrumented unwinder recurses forever under MSan (spike C) |
| mimalloc in variants | `libmimalloc.a` in the farm is a **forwarding shim** (`mi_*` → libc allocator, which every sanitizer intercepts) | The shipped `MI_OVERRIDE=ON` archive segfaults under ASan and TSan; `MI_OVERRIDE=OFF` hides `mi_*` blocks from ASan and trips MSan (spike E) |
| Rust | `-Zsanitizer=<s> -Zexternal-clangrt`, linker = the variant wrapper (one runtime: clang's) | Verified with rustc nightly on LLVM 23.1.1, including cross-language ThinLTO; two runtimes give duplicate symbols (spike G) |
| CI | Build and verify runtimes and overlay on every CI run; publish the overlay on release | ~10–20 % extra job time; catches flag/recipe regressions where they happen (§9) |

## 3. Support matrix (LLVM 23.1.2)

Legend: **S** shipped and verified by a spike; **S\*** shipped, follows from compiler-rt CMake
and the clang driver but not yet run; **–** not shipped (reason in notes); `o` = needs the overlay
for end-to-end coverage.

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

1. They require dynamic linking (`-static` fails to link). The musl triple exists to produce fully
   static executables, and the build host has no musl loader.
2. Dynamically linked musl executables segfault at startup on today's sysroot (§10). Shipping
   musl sanitizers would also mean a second `libc.so` built with mallocng, which the spike showed
   works.
3. Upstream compiler-rt does not test TSan or MSan on musl. A trivial trigger passing is not
   support.
4. The libraries are the same on both triples, so consumers lose nothing by sanitizing on the gnu
   triple. Revisit if a consumer needs musl-only coverage. The spike shows the path: a
   `sysroot/<arch>-unknown-linux-musl+san` farm with a mallocng `libc.so`.

## 4. Packaging

### 4.1 Main bundle additions (all bundles)

```
lib/clang/23/include/sanitizer/*.h                     # asan_interface.h, msan_interface.h, …
lib/clang/23/share/{asan,msan,hwasan,cfi}_ignorelist.txt …
lib/clang/23/lib/<T>/libclang_rt.<rt>.a, .a.syms, .so   # Linux, subset per §3
lib/clang/23/lib/darwin/libclang_rt.{asan,tsan,ubsan}_osx_dynamic.dylib, libclang_rt.fuzzer_osx.a …
share/elide-toolchain/sanitizers/<T>-<san>.cfg          # runtime layer, e.g. "-fsanitize=address"
share/elide-toolchain/sanitizers/supported.json        # {"<T>": {"asan": {"overlay": "recommended"}, "msan": {"overlay": "required"}, …}}
share/elide-toolchain/cmake/<T>-<san>.cmake             # toolchain file (uses the farm if present)
bin/<T>-<san>-clang, bin/<T>-<san>-clang++              # POSIX-sh wrappers (§5.1)
```

Today the main bundle cannot link any sanitizer program: the runtimes, headers and ignorelists
are missing (spike A). The headers and ignorelists come from the compiler-rt install, and stage 30
installs them into the resource dir.

### 4.2 Sanitizers overlay (Linux bundles only)

`elide-toolchain-<ver>-linux-<arch>-sanitizers.tar.xz` (+ `.sha256`). It has one top-level dir,
`elide-toolchain/`, and is extracted **over** the main bundle of the **same** version (a
mismatch is detected, see §5.2):

```
lib/<G>/{asan,tsan,msan}/libc++.a libc++abi.a libc++experimental.a   # G = <arch>-unknown-linux-gnu
include/<G>/asan/c++/v1/__config_site                               # _LIBCPP_INSTRUMENTED_WITH_ASAN 1
sysroot/<G>+{asan,tsan,msan}/                                        # symlink farm (§4.3)
share/elide-toolchain/sanitizers/<G>-{asan,tsan,msan}.overlay.cfg    # sysroot/-L/-isystem layer
share/elide-toolchain/sanitizers/overlay.json                        # {"version": "...", "revision": "...", "variants": {...}}
```

Sizes, measured on x86_64-gnu (xz -9): msan 27.4 MiB, asan 23.5 MiB, tsan 15.6 MiB; **63.6 MiB
together** (208.7 MiB raw). aarch64 is assumed similar (**unverified**).

**Alternatives rejected.**
(a) Everything in the main bundle: +12 % download for every consumer, almost none of whom
sanitize.
(b) Full per-sanitizer bundles (`…-linux-amd64-msan.tar.xz` with LLVM included): about 590 MiB
each, three times per arch, for about 22 MiB of distinct content, and the action/mise would have
to pick among four "linux-amd64" toolchains.
(c) One overlay per sanitizer: smaller single downloads (16–27 MiB) but three more assets per
arch and more action logic. Reasonable if the user prefers it (open question Q2).

### 4.3 Variant sysroot farm

`sysroot/<G>+<san>/` mirrors `sysroot/<G>/` entry by entry:

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
                                 "overlay": ["asan","tsan","msan"] },
  "x86_64-unknown-linux-musl": { "runtimes": ["ubsan","ubsan_minimal"], "overlay": [] }
},
"overlay": { "sanitizers": "elide-toolchain-2026.10.0-linux-amd64-sanitizers.tar.xz" }
```

The SBOM is unchanged: same components and versions. The overlay's archives carry the same
component versions with a `build-variant` property added (open question Q5).

## 5. Selection: front-ends, helper, action, mise

### 5.1 Wrappers and cfg layers

`bin/<T>-<san>-clang` (and `-clang++`), generated by `install_sanitizer_frontends`:

```sh
#!/bin/sh
# <T> + <san>: the base cfg (<T>.cfg, auto-loaded) + the <san> runtime layer + the overlay layer if installed.
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
san=$here/../share/elide-toolchain/sanitizers
if [ -f "$san/<T>-<san>.overlay.cfg" ]; then
  exec "$here/<T>-clang" --config="$san/<T>-<san>.cfg" --config="$san/<T>-<san>.overlay.cfg" "$@"
fi
# (msan only) echo "…: msan needs the sanitizers overlay (instrumented libc++ and components)" >&2; exit 2
exec "$here/<T>-clang" --config="$san/<T>-<san>.cfg" "$@"
```

Runtime layer `<T>-<san>.cfg`: `-fsanitize=address` / `thread` / `memory` plus
`-fsanitize-memory-track-origins` / `undefined` / `leak` / `hwaddress`, and `-fno-omit-frame-pointer`.
Overlay layer `<G>-<san>.overlay.cfg` (paths relative to `share/elide-toolchain/sanitizers/`):

```
--sysroot=<CFGDIR>/../../../sysroot/<G>+<san>
-L<CFGDIR>/../../../lib/<G>/<san>
-isystem <CFGDIR>/../../../include/<G>/asan/c++/v1     # asan only
```

Ordering, verified: the default `<T>.cfg` loads first, then explicit `--config`s in order, so the
overlay's `--sysroot` wins. The cfg `-L` precedes the driver's `lib/<T>` path. User `-I`/`-L` on
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
elide-toolchain sanitizers [--target T]          # list: name, runtime present, overlay present/required
```

`env --sanitizer S` changes the base output as follows:

| Var | Value |
|---|---|
| `CC`, `CXX` | `bin/<T>-<S>-clang`, `bin/<T>-<S>-clang++` |
| `CMAKE_TOOLCHAIN_FILE` | `share/elide-toolchain/cmake/<T>-<S>.cmake` |
| `PKG_CONFIG_SYSROOT_DIR`, `PKG_CONFIG_LIBDIR` | the farm when the overlay is installed, else the base sysroot |
| `CARGO_TARGET_<RT>_LINKER` | `bin/<T>-<S>-clang` |
| `CARGO_TARGET_<RT>_RUSTFLAGS` | `-Zsanitizer=<address|thread|memory|leak|hwaddress> -Zexternal-clangrt` (not emitted for ubsan: Rust has no UBSan) |
| `ELIDE_SANITIZER` | `S` |
| `ELIDE_SANITIZER_RUNTIME` | absolute path of the shared runtime (`libclang_rt.asan.so`, …) where one exists, for `LD_PRELOAD` into uninstrumented hosts such as the JVM |

Errors: unknown or unsupported (T, S), e.g. `--target x86_64-unknown-linux-musl --sanitizer asan`
→ `asan is not supported for musl targets; use x86_64-unknown-linux-gnu`. `--static` with any
sanitizer except ubsan → error. `msan` without the overlay → error with the overlay asset name.
Overlay `overlay.json` version ≠ bundle `VERSION` → error. `asan`/`tsan` without the overlay →
a warning on stderr ("libc++ and components are not instrumented; install …-sanitizers.tar.xz
for full coverage"), and the output is still emitted.

### 5.3 GitHub Action

New inputs: `sanitizers: true|false` (default `false`) downloads and extracts the overlay after
the main bundle (same resolution, checksum and R2 fallback), and
`sanitizer: asan|tsan|msan|ubsan|lsan|hwasan` (requires `target`) applies
`elide-toolchain env --target T --sanitizer S`. Setting `sanitizer` to asan/tsan/msan implies
`sanitizers: true`. New output: `sanitizers` (JSON of the installed variants).

### 5.4 mise

mise installs one asset per platform. A second `linux-amd64` `.tar.xz` on the same release may
make autodetection ambiguous (**uncertain**: the plan's first task checks
`src/backend/asset_matcher.rs`, as was done in `docs/notes/mise-assets.md`). Overlays reach mise
users through a helper subcommand that downloads the release asset matching the bundle:

```
elide-toolchain overlay install sanitizers [--from FILE|URL]   # curl/wget + sha256; extracts over the bundle
```

## 6. Build pipeline

### 6.1 Configuration

`versions.env` (shared floors and policy):

```
SANITIZERS_GNU="asan;lsan;tsan;msan;ubsan;ubsan_minimal;fuzzer"
SANITIZERS_GNU_AARCH64_EXTRA="hwasan"
SANITIZERS_MUSL="ubsan;ubsan_minimal"
SANITIZERS_DARWIN="asan;tsan;ubsan;ubsan_minimal;fuzzer"
SANITIZER_VARIANTS="asan tsan msan"
```

`vars.sh`: `BUILD_SANITIZERS=${BUILD_SANITIZERS:-yes}` (runtimes in the main bundle) and
`BUILD_SANITIZER_VARIANTS=${BUILD_SANITIZER_VARIANTS:-yes}` (Linux overlay). Both can be turned
off for fast local builds. Verification skips what was not built and reports a notice.

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

1. `install_sanitizer_frontends "$BUNDLE_DIR"` for (t, san) renders the runtime cfg, the overlay
   cfg, the wrappers and the CMake file. Components need them in step 3.
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

Measured on 32 threads: about 1 min per (triple, sanitizer), i.e. about 3 min per gnu triple
(spikes C and D).

### 6.5 Stage 90 (package)

The main archive excludes the overlay paths: `sysroot/*+*`, `lib/*/{asan,tsan,msan}`,
`include/*/asan`, `share/elide-toolchain/sanitizers/*.overlay.cfg` and `overlay.json`. The overlay
archive contains exactly those paths, with `tar --exclude` / `-T filelist` from one function,
`overlay_paths`, so the two lists cannot drift. Each archive gets a `.sha256`. `relocate_prefix`
also covers the farms: their `.pc` files are symlinks to relocated files, so this is a no-op
check. `manifest.json` gets the `sanitizers` section, and `overlay.json` is written into the
overlay.

### 6.6 Library changes

| File | Change |
|---|---|
| `scripts/lib/platform.sh` | `triple_sanitizers T` (from `versions.env`), `triple_variants T`, `san_flag S` (asan→address …), `san_cmake S` (asan→Address, msan→MemoryWithOrigins, tsan→Thread), `san_symbol S` (`__asan_` …) |
| `scripts/lib/frontends.sh` | `render_san_cfg`, `render_san_overlay_cfg`, `render_san_wrapper`, `render_san_toolchain_cmake`, `install_sanitizer_frontends` (runtime layers for every supported (T,S) go in the main bundle; overlay layers only in stage 60) |
| `scripts/lib/flags.sh` | `target_cflags` honours `SANITIZER_LAYER` |
| `scripts/lib/components.sh` | `component_variant_args NAME SAN` |
| `src/elide-toolchain` | `--sanitizer`, `sanitizers`, `overlay install` |
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
  sanitizers. The README says so, and the `<T>-<san>-clang` wrapper for asan/tsan without the
  overlay warns when it sees `-lmimalloc` (**cheap, optional**; plan task 9).
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
Supported alternatives for Elide: sanitize the native layers (Rust, C, JNI) in ordinary test
executables on the gnu triple, and, for JVM-hosted JNI libraries, build with `-shared-libsan` and
`LD_PRELOAD` the runtime (spike H; §11.1).

### 7.5 musl vs glibc

See §3.2. musl gets UBSan only, and it works fully static, including with the
mimalloc-in-`libc.a` sysroot. glibc gets the full set. The glibc floor holds for every shared
runtime (max `GLIBC_2.34`; spike H), and `check_glibc_floor` already scans `lib/**/*.so`.

### 7.6 darwin

Runtimes only: ASan, TSan, UBSan dylibs and libFuzzer, built in stage 10 with deployment target
12.0. Clang links the dylibs with an absolute `-rpath` into the bundle's resource dir, so
sanitized test binaries are not relocatable with the bundle. That is acceptable for test
binaries; document it. No MSan. The system libc++ cannot be swapped for an instrumented one, but
ASan and TSan do not need that. An instrumented components overlay for darwin is a follow-up if
asked.

## 8. Verification (stage 95 and `tests/stages/*.check.sh`)

Stage 95 extracts the main archive and, when built, the overlay over it, then runs:

| Check | What |
|---|---|
| `check_sanitizer_runtimes ROOT T` | Every runtime in `triple_sanitizers T` exists (static, `.syms`, `.so` where applicable), plus `include/sanitizer/asan_interface.h` and the ignorelists; musl has **no** `libclang_rt.{asan,tsan,msan,lsan}*` |
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
| existing `check_glibc_floor`, `check_no_build_paths` | Already scan the new files; overlay included |

`elide-toolchain doctor` gains `--sanitizers`, which runs the trip and clean checks for every
installed (T, S).

## 9. CI impact

| Item | Estimate |
|---|---|
| Stage 30 pass 3 (Linux) | ~30 s per triple × 2 on 32 threads; ×2–4 on smaller runners → +2–4 min per Linux job |
| Stage 60 (Linux) | ~3 min on 32 threads → +6–12 min per Linux job (runner core count **uncertain**) |
| Stage 10 darwin sanitizers | +3–6 min on `macos-15` (**unverified**) |
| Packaging the overlay (xz -9, ~210 MiB raw) | +1–2 min |
| New stage 95 checks | +2–3 min |
| **Total** | Linux about +12–20 min per job on top of ~22 min locally (CI ~1–2 h); darwin about +5–8 min |
| Artifacts | +64 MiB per Linux arch (overlay), +~3 MiB per Linux main bundle |

Matrix: unchanged, with the same three jobs. Everything is gated by `BUILD_SANITIZERS` /
`BUILD_SANITIZER_VARIANTS` (default yes), so a PR can be fast-pathed later if time hurts.

Release: `on.release.yml` attaches the `-sanitizers` archives and `.sha256`s and mirrors them to
R2. `job.action-e2e.yml` gains one leg per Linux arch with `sanitizer: msan` (gnu) that compiles
and runs the trigger and the clean workload through the action-provided env.

Recommendation: **build and verify on every CI run; publish only on release.** The cost is
modest, and recipe regressions (a component that stops honouring CFLAGS, a libc++ option change)
show up where they are introduced. Alternative: build the overlay only on `push` to main and on
release (open question Q3).

## 10. Pre-existing defect found by the spikes

**Every dynamically linked musl executable crashes before `main` on today's sysroot**, sanitized
or not:
`SIGSEGV in _mi_thread_init_with_heap ← mi_process_init_once ← _mi_auto_process_init ← do_init_fini`
inside `libc.so`/`ld-musl-x86_64.so.1`. musl is built with mimalloc (`USE_MIMALLOC=yes`) and LTO.
A mallocng rebuild of the same musl works. `check_components_shared` links musl `.so` files but
never runs a dynamic musl executable, so stage 95 misses this. It does not block this design,
which ships no dynamic-musl sanitizers, but it should be fixed or explicitly declared unsupported.
At minimum, add a verify check that runs a dynamically linked musl hello through the sysroot
loader. Root cause **not investigated**.

## 11. Consumer integration notes

### 11.1 Elide (labs/WHIPLASH: Rust + GraalVM native-image + JNI/ACCP)

- Native-image binaries: no ASan/TSan/MSan/LSan (§7.4). Sanitize the Rust crates and C/JNI
  sources through **test executables** on `x86_64-unknown-linux-gnu`:
  `eval "$(elide-toolchain env --target x86_64-unknown-linux-gnu --sanitizer asan)"; cargo +nightly test --target x86_64-unknown-linux-gnu`.
- JVM-hosted JNI libraries (incl. ACCP): build with `-shared-libsan`, run the JVM with
  `LD_PRELOAD=$ELIDE_SANITIZER_RUNTIME` and
  `ASAN_OPTIONS=detect_leaks=0:handle_segv=0:allow_user_segv_handler=1`. The JVM uses SIGSEGV for
  safepoints and implicit null checks. Spike H verified the preload shape with a stand-in host,
  not a JVM (**uncertain**).
- ACCP builds its own aws-lc. Whether WHIPLASH links the bundle's `libcrypto.a` or ACCP's copy
  decides whether the instrumented aws-lc in the farm is used (**uncertain**; check the WHIPLASH
  build).
- Disable the Rust `mimalloc` global allocator in sanitizer builds (§7.1).
- MSan on Rust needs `-Zbuild-std`; start with ASan + UBSan, then TSan.

### 11.2 Bali (labs/crema-jit: Rust + C)

- ASan + UBSan first: JIT-emitted code is invisible to ASan, which is fine. MSan: memory written by
  JIT code looks uninitialised; unpoison JIT outputs at the boundary (`__msan_unpoison`, from
  `<sanitizer/msan_interface.h>`, now shipped) or exclude MSan. TSan cannot see JIT code's memory
  accesses, so do not expect race detection inside generated code.
- libFuzzer is shipped (gnu). `cargo fuzz` builds its own libFuzzer through `libfuzzer-sys`,
  which compiles C++ with `$CXX`, so the wrapper's variant libc++ is used. C fuzz targets can use
  `-fsanitize=fuzzer,address` with `bin/<T>-asan-clang`.
- C parts built by `cc`/`cmake` crates pick up `CC`/`CXX`/`CMAKE_TOOLCHAIN_FILE` from `env`.

### 11.3 Komodo

- Komodo's stack was not inspected (**uncertain**). Generic guidance: CMake builds pass
  `-DCMAKE_TOOLCHAIN_FILE=$(elide-toolchain home)/share/elide-toolchain/cmake/<T>-<S>.cmake`, or
  use the action input `sanitizer:`. Autotools builds take `CC`/`CXX`/`PKG_CONFIG_*` from `env`.
  musl-only release builds keep musl for releases and add a gnu-triple sanitizer CI job; musl
  builds can still use UBSan statically.

## 12. Open questions

- **Q1.** Ship libFuzzer in the main bundle (+0.6 MiB xz per gnu triple)? Recommended yes.
- **Q2.** One combined overlay (64 MiB) or one per sanitizer (16–27 MiB each)? Recommended
  combined.
- **Q3.** Build the overlay on every PR, or only on push/release? Recommended every run.
- **Q4.** Fix or formally drop dynamically linked musl executables (§10) before shipping?
- **Q5.** SBOM: separate SBOM for the overlay, or one SBOM with variant properties?
- **Q6.** Should ASan/TSan without the overlay be an error rather than a warning in
  `elide-toolchain env`? Recommended warning.
- **Q7.** darwin: is an instrumented-components overlay wanted (ASan/TSan only)?
