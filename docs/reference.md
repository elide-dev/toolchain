# Toolchain reference

A self-contained native toolchain: LLVM 23 (clang, clangd, lld, BOLT, Polly), libc++ / libc++abi / libunwind, compiler-rt, and a full tree of pre-built static libraries (zlib-ng, zstd, brotli, snappy, lz4, crc32c, AWS-LC, mimalloc, libsqlite3elide, and optionally OpenSSL, zlib, SQLite, SQLCipher, Cap'n Proto, hiredis, LevelDB), all compiled with one consistent flags profile. Linux bundles carry two sysroots, fully static **musl** (with mimalloc built into `libc.a`) and **glibc 2.17**; macOS bundles carry a component overlay on top of the system SDK. It is built from source, one bundle per host OS/arch, and is used by Elide, Komodo, Bali (crema-jit) and GraalVM `native-image` builds (`--libc=musl`).

Releases are `elide-toolchain-<version>-<os>-<arch>.tar.xz`, each with a `.sha256` and a CycloneDX SBOM, on [GitHub Releases](https://github.com/elide-dev/toolchain/releases) (tags `vYYYY.M.N`; the month is not zero-padded, e.g. `v2026.9.0`), mirrored to `https://static.elideusercontent.com/toolchain/<version>/`.

## Bundles

| Bundle | Triples |
|---|---|
| `linux-amd64` | `x86_64-unknown-linux-musl`, `x86_64-unknown-linux-gnu` |
| `linux-arm64` | `aarch64-unknown-linux-musl`, `aarch64-unknown-linux-gnu` |
| `darwin-arm64` | `arm64-apple-darwin` |

Each bundle targets its own OS and architecture (no cross-OS or cross-arch targeting).

Floors:

- **glibc 2.17.** Every glibc-targeted binary, including the bundled clang and lld, references no symbol version newer than `GLIBC_2.17` (RHEL/CentOS 7, Amazon Linux 2, Ubuntu 14.04, Debian 8 and newer). The gnu sysroot is CentOS 7.9's final glibc 2.17 build (prebuilt RPMs pinned by SHA256 in `versions.env`) over current Linux UAPI headers. Code built against it sees glibc 2.17 headers, so newer interfaces (`getrandom`, `getentropy`, `statx`, …) are absent and libraries fall back to their syscall or `/dev/urandom` paths.
- **macOS 12.0** (`minos` <= 12.0).
- **Host ISA:** x86-64-v3 (AVX2) on amd64, `armv8.2-a+crypto+crc+dotprod` on arm64. The shipped tools are built with the same `-march` as the code they produce, so they need such a host.

Every target library (each sysroot's static archives) and the libc++ runtimes (`lib/<triple>/libc++.a`, `libc++abi.a`, `libunwind.a`) carry LLVM 23 ThinLTO bitcode, so downstream links are `-flto=thin` end to end with lld. On Linux, components, musl `libc.a`, the allocator libraries and libc++/libc++abi/libunwind are fat objects (native code plus bitcode in `.llvm.lto`), so they also link without LTO; darwin archives are pure bitcode (Mach-O has no fat objects); compiler-rt, glibc's own archives and hand-written assembly members are native only. The LLVM/clang development libraries in `lib/` (`libLLVM*.a`, `libclang*.a`) are host tool libraries and are native code, not bitcode. Consumers using Rust need a rustc whose LLVM major is **<=** the bundle's (`llvmMajor` in `manifest.json`).

Assets are named `elide-toolchain-<version>-<os>-<arch>.tar.xz` (`os` = `linux|darwin`, `arch` = `amd64|arm64`; macOS ships arm64 only), with one top-level directory, `elide-toolchain/`.

## Install

### GitHub Actions

```yaml
- uses: elide-dev/toolchain/action@<ref>
  with:
    version: latest                    # or 2026.11.5 / v2026.11.5
    target: x86_64-unknown-linux-gnu   # optional: exports CC, CXX, AR, ... for this triple
    github-token: ${{ github.token }}  # optional
    sanitizer: asan                    # optional (needs target): see Sanitizers
```

With no inputs it installs the latest bundle for the runner's OS/arch, exports `ELIDE_TOOLCHAIN_HOME` and adds `bin/` to `PATH`. Outputs: `home`, `version`, `targets`, `sanitizer-addon`. Inputs for testing and mirrors: `archive` (local `.tar.xz`), `sanitizer-archive` (local add-on `.tar.xz`), `base-url`, `repo`, `os`, `arch`. `latest` is resolved via the Releases API, falling back to the R2 mirror.

### mise

```toml
[tools]
"github:elide-dev/toolchain" = "2026.11.5"
```

mise picks the asset by OS/arch and strips the single top-level directory, so `bin/` is found by default. If that auto-strip is ever unwanted, use the explicit form:

```toml
[tools]
"github:elide-dev/toolchain" = { version = "2026.11.5", bin_path = "elide-toolchain/bin" }
```

mise only provides `PATH`; use `elide-toolchain env` (below) for target settings. Sanitizer add-ons are separate release assets (`…-<os>-<arch>-sanitizer-<san>.tar.xz`). mise always picks the main bundle (its asset matcher scores both equally on OS/arch/format and breaks the tie by the shorter name; see `docs/notes/mise-assets.md`); install an add-on with `elide-toolchain addon install sanitizer-<san>`.

### Manual

```sh
v=2026.11.5; a=elide-toolchain-$v-linux-amd64.tar.xz
curl -LO https://github.com/elide-dev/toolchain/releases/download/v$v/$a
curl -LO https://github.com/elide-dev/toolchain/releases/download/v$v/$a.sha256
shasum -a 256 -c $a.sha256
tar -xJf $a
export ELIDE_TOOLCHAIN_HOME=$PWD/elide-toolchain PATH=$PWD/elide-toolchain/bin:$PATH
```

## Use

Invoke `<triple>-clang` / `<triple>-clang++`; clang loads `bin/<triple>.cfg`, which supplies `--target`, `--sysroot`, `-rtlib=compiler-rt`, `-unwindlib=libunwind`, `-stdlib=libc++` and `-fuse-ld=lld`. glibc 2.17 keeps `libpthread`, `libdl` and `librt` out of `libc`; the gnu sysroot's `libc.so` linker script pulls in `libpthread` and `libdl` as needed (as glibc 2.34+ does by merging them), so only `librt` users (`shm_open`, `timer_create`, …) must add `-lrt`. Plain `bin/clang` (and `clang --target=<triple>`) auto-loads the cfg too: plain `clang` loads the host's default-triple cfg, which is the gnu triple on Linux and the darwin triple on macOS. Pass `--no-default-config` for a bare clang. The bundle is relocatable. For fully static output use the musl triple with `-static`; static linking of the gnu triple is unsupported.

```sh
x86_64-unknown-linux-musl-clang hello.c -static -o hello
x86_64-unknown-linux-gnu-clang++ hello.cpp -o hello
```

**Environment.** `elide-toolchain env --target <triple>` prints `CC`, `CXX`, `AR`, `NM`, `RANLIB`, `PKG_CONFIG_LIBDIR`, `PKG_CONFIG_SYSROOT_DIR`, `CMAKE_TOOLCHAIN_FILE`, the Cargo linker variable, and (macOS) `SDKROOT`. Formats: `--format sh|github|json`; `--static` for static mode.

```sh
eval "$(elide-toolchain env --target x86_64-unknown-linux-gnu)"
```

**CMake.** `-DCMAKE_TOOLCHAIN_FILE=$ELIDE_TOOLCHAIN_HOME/share/elide-toolchain/cmake/<triple>.cmake`.

**pkg-config.** `PKG_CONFIG_LIBDIR=<sysroot>/usr/lib/pkgconfig` and `PKG_CONFIG_SYSROOT_DIR=<sysroot>` (set by `env --target`); every component installs its `.pc` file there.

**Rust.** The bundle ships the official Rust toolchain named by `rustversion` (`nightly-2026-10-09`, LLVM 23.1.3, paired with this bundle’s LLVM 23.1.4) under `rust/`: `rustc`, `cargo` and `rustdoc` for the host, and std for every bundle triple, unmodified. Run `rust/bin/cargo` with `RUSTC=<bundle>/rust/bin/rustc`; neither needs rustup. Other components (clippy, rustfmt, `rust-src`, more targets) are not included: install the same pin with `rustup toolchain install "$(cat /path/to/elide-toolchain/rustversion)"` when you need them. `manifest.json` records the toolchain under `rust`. rustc links through a C compiler driver and its default is the host's `cc`, so always name the bundle's: link through the bundle for cross-language LTO: `CARGO_TARGET_<TRIPLE>_LINKER=<triple>-clang` (printed by `env --target`) with `-Clink-arg=-fuse-ld=lld`; on Linux also pass `-Clink-arg=-Wl,--fat-lto-objects`, since rustc never passes `-flto` to clang (see Link rules). `elide-toolchain flags --target <triple> lto` prints this set as `ELIDE_RUSTFLAGS`. rustc's LLVM major must be <= the bundle's. The gnu std always passes `-lgcc_s`; the gnu sysroot's `usr/lib/libgcc_s.so` is a linker script (`INPUT(-lunwind)`) that resolves it to the static libunwind, so outputs never need `libgcc_s.so.1`. For musl, add `-C target-feature=+crt-static`.

**GraalVM native-image.** Linux bundles ship `<cpu>-linux-musl-gcc` / `-g++` (and `cc`, `c++`, `ar`, `ranlib`, `nm`, `strip`) as shims over clang and the llvm tools, so `native-image --libc=musl` works with `bin/` on `PATH`. The shims never add `-static`. For LTO into the shipped archives, give the final link `-flto=thin`: `-H:NativeLinkerOption=-flto=thin` (glibc: also `--native-compiler-path=<bundle>/bin/<triple>-clang`). Native Image's own object is machine code, so the LTO covers libc, libc++ and the components.

**Sanitizers.** See [Sanitizers](#sanitizers).

**Doctor.** `elide-toolchain doctor` compiles, links and runs a C and C++ hello world for every triple in the bundle. `doctor --sanitizers` also builds a clean C++ program and a known bug through every shipped sanitizer wrapper (with the add-on when installed) and checks the bug is reported. Other subcommands: `home`, `targets`, `version`, `flags` (see below).

**Link rules.** Linux archives are fat ThinLTO objects. A link without `-flto` (dev builds, GNU ld, an older rust-lld) uses their native code. For Linux targets the bundle's clang passes lld `--fat-lto-objects` on in-process links that have `-flto` (a local driver patch, [#13](https://github.com/elide-dev/toolchain/issues/13)), so a plain `-flto=thin` link uses the bitcode and components, libc and libc++ join cross-module optimization. Index-only links retain the archives' native code for distributed ThinLTO (see Bazel below). `-fno-fat-lto-objects` on the link turns the default off; `-Wl,--no-fat-lto-objects` also overrides an explicit linker opt-in. Compiles are unchanged: `-flto=thin` still emits plain bitcode unless you also pass `-ffat-lto-objects`. Three cases need the flag themselves: a Linux link that is LTO only because its inputs are bitcode (rustc `-Clinker-plugin-lto`: rustc never passes `-flto`), another clang, and an older bundle. Pass `-Wl,--fat-lto-objects` (or `-flto=thin -ffat-lto-objects` to clang). `elide-toolchain flags --target <triple> lto [--format json]` prints the complete set for each stage: `ELIDE_CFLAGS` for compiles, `ELIDE_LDFLAGS` for final links, `ELIDE_RUSTFLAGS` for rustc; archiving needs no flags (`llvm-ar`). To see what a link actually does, add `-###`: on Linux the `ld.lld` line shows `"--fat-lto-objects"` when the archives' bitcode is used. Bitcode needs LLVM at least the bundle's major: the bundle's clang/lld, or rust-lld from a rustc whose LLVM major is <= the bundle's. darwin archives are pure ThinLTO bitcode, so link them through the bundle's `<triple>-clang` (its cfg sets `-fuse-ld=lld`), not Apple's `ld64`, which fails loudly on them.

**Bazel.** Use the bundle's `<triple>-clang`/`-clang++` as the cc toolchain's compiler and linker. Turn on ThinLTO with the `thin_lto` feature (`--features=thin_lto`) or with `-flto=thin` in `copts` and `linkopts`. Starting with 2026.11.5, Linux index-only links (`--thinlto-index-only[=path]` or the `-plugin-opt` alias, forwarded by `-Wl,` or `-Xlinker`) do not enable fat-object bitcode by default. Both joined and split plugin options are recognized, including Bazel's `-Wl,-plugin-opt,thinlto-index-only=path`; 2026.11.4 missed that split form. Project bitcode still participates in distributed ThinLTO; sysroot archives use their native members at indexing time, so `.imports` never gains their absolute archive-member paths ([#18](https://github.com/elide-dev/toolchain/issues/18)). Ordinary in-process links retain the fat-LTO default. Do not add `-ffat-lto-objects` or `-Wl,--fat-lto-objects` to distributed index actions: explicit opt-ins still win. On 2026.11.2 or 2026.11.4, pass `--linkopt=-fno-fat-lto-objects` as a workaround; `--linkopt=-Wl,--no-fat-lto-objects` also works when placed after an explicit linker opt-in. Ensure the option reaches the LTO indexing action in your cc toolchain. For in-process links that are LTO only through Rust bitcode, add `--linkopt=-Wl,--fat-lto-objects`. To check a target, inspect its link/index arguments with `bazel aquery`, then run them with `-###` added.

**SQLite for Elide.** `libsqlite3elide.a` is SQLite (`SQLITE_VERSION` in `versions.env`, aligned with the sqlite-jdbc jar Elide ships) with the [sqlite-jni](https://github.com/elide-tools/sqlite-jni) shim (`sqlite_*` entry points that Elide's Rust JNI layer forwards to) compiled into the amalgamation, built with `SQLITE_GVM_STATIC` and sqlite-jdbc's compile options (`MAX_ATTACHED=25`, `MAX_VARIABLE_NUMBER=250000`, `API_ARMOR`, FTS3/FTS5, RTREE, STAT4, geopoly, column metadata, update/delete limit; math functions off). It replaces sqlite-jni's release tarballs: `lib/libsqlite3elide.a` and `include/{sqlite3.h,sqlite3ext.h,sqlite3jni.h}` sit in each sysroot's `usr/`, with `sqlite3elide.pc`. `sqlite3jni.h` includes `<jni.h>`, which comes from the consumer's JDK.

C++ implies libc++ on every target; there is no libstdc++ in the bundle, so drop any `-lstdc++`.

## Profile-guided layout, deduplication and memory hints

Design: `docs/superpowers/specs/2026-10-05-memprof-dedubb-design.md`. LLVM carries a few local patches (MemProf backports, DeduBB, the Linux fat-LTO link default), tracked in [#4](https://github.com/elide-dev/toolchain/issues/4) and `docs/notes/llvm-patches.md`. `elide-toolchain flags --target <triple> <mode>...` prints `ELIDE_CFLAGS`, `ELIDE_CXXFLAGS`, `ELIDE_LDFLAGS` and `ELIDE_RUSTFLAGS` (linker-plugin LTO) for each step below. Modes combine.

| Feature | Linux x86_64 | Linux aarch64 | macOS |
|---|---|---|---|
| Propeller (`bin/generate_propeller_profiles`) | yes (LBR profiles) | yes (SPE profiles, unverified) | no (ELF only) |
| DeduBB (code-size deduplication) | yes | yes (tail-call folds only) | no |
| MemProf profile collection | gnu only | no | no |
| MemProf use + `libelidealloc-shim` | yes | yes | shim forwards (no partitions) |

**Propeller.** Profiles come from `perf` with branch sampling (LBR on x86, SPE on arm64), recorded **by you on your own perf-capable hosts** with real workloads. The bundle ships the tool and compiler support; our CI cannot branch-sample and verifies from fixtures (`docs/notes/propeller-fixtures.md`).
```sh
eval "$(elide-toolchain flags --target x86_64-unknown-linux-gnu propeller-baseline)"   # labelled build
perf record -e cycles:u -j any,u -o perf.data -- ./app <workload>
generate_propeller_profiles --binary=./app --profile=perf.data --cc_profile=cc.txt --ld_profile=ld.txt
eval "$(elide-toolchain flags --target x86_64-unknown-linux-gnu propeller-use=cc.txt,ld.txt)"  # relink
```

**DeduBB** ([LCTES '26](https://dl.acm.org/doi/10.1145/3814943.3816169)) folds identical basic blocks across the whole program into jumps or calls to one copy. It is static: directives come from the labelled binary alone, with no profile needed. The patched compiler is unchanged unless you pass a directive file.
```sh
generate_propeller_profiles --binary=./app --dedubb_profile=dedubb.txt [--dedubb_subsequence]
eval "$(elide-toolchain flags --target x86_64-unknown-linux-gnu dedubb-apply=dedubb.txt)"     # relink
```
Add `--dedubb_cold_only --profile=perf.data` to fold only never-executed blocks, and combine with `propeller-use=` for one relink. Apply it to final links only, never to static archives you ship. Never collect profiles from a DeduBB binary.

**MemProf.** Collect on `x86_64-unknown-linux-gnu` (the only runtime upstream supports); use the profile on any triple. Hints need ThinLTO and an allocator: `libelidealloc-shim` (below).
```sh
eval "$(elide-toolchain flags --target x86_64-unknown-linux-gnu memprof-instrument)"; ./app   # memprof.profraw.<pid>
llvm-profdata merge memprof.profraw.* --profiled-binary ./app -o app.memprofdata
eval "$(elide-toolchain flags --target <triple> memprof-use=app.memprofdata)"
```
Only C++ `operator new` sites are hinted (not `malloc`, not Rust allocations). Rust binaries that link C++ through `-Clinker-plugin-lto` get hints for the C++ parts. Name profile and directive files by content hash: ThinLTO and compiler caches key on the path, not the contents.

**libelidealloc-shim** (`-lelidealloc-shim`, `elidealloc-shim.h`, `pkg-config elidealloc-shim`; gnu also needs `-lmimalloc`; musl links static, and its mimalloc lives in `libc.a`, with an empty `libmimalloc.a` stub and `mimalloc.pc` so `-lmimalloc` still resolves). Provides the tcmalloc-compatible `operator new(size_t, __hot_cold_t)` that MemProf calls, plus a small C API (`elidealloc_malloc(size, ELIDEALLOC_COLD, 0)`, `elidealloc_partition_of`, stats). Hint ≤ 63 goes to a dedicated COLD heap and ≥ 240 to a HOT heap. `notcold` (128) and `ambiguous` (222) stay with the stock allocator. The backend is mimalloc on Linux and `forward` on macOS. Tune with `ELIDEALLOC_COLD_MAX`, `ELIDEALLOC_HOT_MIN`, `ELIDEALLOC_{COLD,HOT}_RESERVE_MB`, `ELIDEALLOC_HOT_LARGE_PAGES`; `ELIDEALLOC_DISABLE=1` for A/B runs, `ELIDEALLOC_STATS=1` for counters at exit. ABI v1 is frozen (`src/elidealloc-shim/abi-v1.symbols`); allocation tokens will arrive as an additive v2.

**GraalVM native-image** Java code cannot take part (Graal compiles it). Separately built C/C++ (JNI libraries) can.

## Sanitizers

Design: [`docs/superpowers/specs/2026-10-05-sanitizer-variants-design.md`](superpowers/specs/2026-10-05-sanitizer-variants-design.md).

| Sanitizer | `*-linux-gnu` | `*-linux-musl` | `arm64-apple-darwin` |
|---|---|---|---|
| `asan` (+ leak checking) | runtime in bundle; add-on recommended | — | runtime (dylib) |
| `tsan` | runtime in bundle; add-on recommended | — | runtime (dylib) |
| `msan` | runtime in bundle; **add-on required** | — | — |
| `ubsan` (standalone + minimal) | runtime in bundle | runtime, fully static | runtime (dylib) |
| `lsan` (standalone) | runtime in bundle | — | — |
| `hwasan` | aarch64 only (kernel needs the tagged-address ABI) | — | — |
| libFuzzer (`-fsanitize=fuzzer`) | in bundle | — | in bundle |

musl is static-only by design, and ASan/TSan/MSan/LSan need dynamic linking, so on musl only UBSan is offered: sanitize on the gnu triple.

**Use.** `bin/<triple>-<san>-clang` / `-clang++` are wrappers that add the sanitizer to the triple's normal cfg (and, once installed, the add-on's instrumented sysroot and libc++); `share/elide-toolchain/cmake/<triple>-<san>.cmake` is the matching toolchain file. The helper sets it all up:

```sh
eval "$(elide-toolchain env --target x86_64-unknown-linux-gnu --sanitizer asan)"
# CC/CXX = the wrappers, CMAKE_TOOLCHAIN_FILE, PKG_CONFIG_* (add-on sysroot when installed),
# CARGO_TARGET_<T>_LINKER + CARGO_TARGET_<T>_RUSTFLAGS="-Zsanitizer=address -Zexternal-clangrt",
# ELIDE_SANITIZER, ELIDE_SANITIZER_RUNTIME (shared runtime, for LD_PRELOAD)
elide-toolchain sanitizers            # what is supported and installed
elide-toolchain doctor --sanitizers   # clean program + known bug through every wrapper
```

**Add-ons.** Each release also publishes, for linux-amd64 only (`SANITIZER_VARIANT_CPUS`), one archive per sanitizer, `elide-toolchain-<ver>-linux-amd64-sanitizer-{asan,tsan,msan}.tar.xz` (+ `.sha256`), with libc++/libc++abi and every component instrumented for that sanitizer, a mimalloc forwarding shim, and a sysroot `sysroot/<triple>+<san>/` that layers them over the normal one. Each extracts over the main bundle of the same version, independently of the others: `elide-toolchain addon install sanitizer-msan` (GitHub release, then the R2 mirror; checksum and version checked), the action's `sanitizer:` input, or `tar -xJf <addon> -C <dir containing elide-toolchain/>`. MSan needs its add-on (anything uninstrumented produces false positives), so on linux-arm64 use ASan, TSan or HWASan; ASan/TSan work without one but cannot see inside libc++ and the components. Add-ons are built on pushes to `main` and on releases, not on pull requests; locally, `BUILD_SANITIZER_VARIANTS=yes ./build.sh`.

**Caveats.**
- Sanitizers own `malloc`: do not link the main sysroot's `libmimalloc.a` (it overrides `malloc`) into a sanitized program; the add-ons' `libmimalloc.a` forwards `mi_*` to the sanitized libc allocator. Disable Rust's `mimalloc` global allocator in sanitizer builds.
- Rust (nightly): one runtime only. `env --sanitizer` uses clang's (`-Zexternal-clangrt`, linked by the wrapper); passing `-fsanitize` to the linker *and* letting rustc link its own runtime fails with duplicate symbols. MSan/TSan need `-Zbuild-std`.
- GraalVM native-image output cannot be sanitized with ASan/TSan/MSan/LSan (static, uninstrumented image with its own heap and signal handling). Sanitize the JNI/native libraries instead: in test executables on the gnu triple, or loaded by a JVM with `-shared-libsan` and `LD_PRELOAD=$ELIDE_SANITIZER_RUNTIME ASAN_OPTIONS=detect_leaks=0:handle_segv=0:allow_user_segv_handler=1`.
- ASan/TSan/MSan cannot link `-static`; `env --static --sanitizer` refuses everything but `ubsan`.
- darwin: clang links the sanitizer dylibs with an absolute rpath into the bundle, so sanitized test binaries do not survive moving the bundle.

## Layout

```
elide-toolchain/
  bin/
    clang clang++ clang-cpp clangd ld.lld lld llvm-ar llvm-nm llvm-ranlib llvm-objcopy llvm-strip ...
    llvm-bolt perf2bolt merge-fdata llvm-profgen llvm-profdata llvm-dwarfdump llvm-dwp   (Linux)
    generate_propeller_profiles           # Propeller layout profiles + DeduBB directives (Linux)
    elide-toolchain                       # helper CLI (POSIX sh)
    <triple>.cfg                          # clang config per target triple
    <triple>-clang  -> clang
    <triple>-clang++ -> clang++
    <arch>-linux-musl-gcc, <arch>-linux-musl-g++   # Linux GCC-named shims
    <triple>-<san>-clang, <triple>-<san>-clang++   # sanitizer front-ends (POSIX sh)
  lib/
    clang/<major>/include/                # resource dir
    clang/<major>/lib/<triple>/libclang_rt.*   # Linux: builtins, crtbegin/crtend, profile, sanitizers, libFuzzer; memprof (x86_64 gnu)
    clang/<major>/lib/darwin/libclang_rt.*     # macOS
    <triple>/libc++.a libc++abi.a libunwind.a  # Linux
  rust/                                   # official Rust toolchain of `rustversion`
    bin/ rustc cargo rustdoc ...
    lib/rustlib/<rust-triple>/lib/        # std for every bundle triple
  include/
    c++/v1/                               # libc++ headers (Linux)
    <triple>/c++/v1/__config_site
  sysroot/
    <arch>-unknown-linux-musl/usr/{include,lib}   # musl+mimalloc, kernel headers, components
    <arch>-unknown-linux-gnu/usr/{include,lib}    # glibc 2.17, kernel headers, components, libmimalloc.a
    <every sysroot>/usr/lib/libelidealloc-shim.a, usr/include/elidealloc-shim.h
    <arch>-apple-darwin/usr/{include,lib}         # macOS component overlay (no SDK)
  share/elide-toolchain/
    manifest.json
    sbom.cdx.json
    cmake/<triple>.cmake, cmake/<triple>-<san>.cmake
    sanitizers/<triple>-<san>.cfg         # sanitizer runtime layer
```

A sanitizer add-on adds `lib/<triple>/<san>/` (instrumented libc++), `sysroot/<triple>+<san>/`, `include/<triple>/asan/` (asan) and `share/elide-toolchain/sanitizers/{<triple>-<san>.addon.cfg,<san>.addon.json}`.

`manifest.json` records the version, revision, host floors (`glibcFloor`, `march`), per-target libc and march/mtune, component versions, `llvmMajor`, the cflags profile, and `features` (Propeller tool and pin, DeduBB, MemProf runtime targets and backports, shim ABI and per-triple backend, and `fatLto`: the Linux targets whose driver passes `--fat-lto-objects` on `-flto` links, plus the explicit link flag and opt-out).

## Migrating from musl-toolchain

| Old (`$MUSL_HOME` = `…/1.2.5`) | New (`$ELIDE_TOOLCHAIN_HOME`) |
|---|---|
| `bin/clang`, `bin/llvm-bolt`, … | `bin/clang`, `bin/llvm-bolt`, … (unchanged names) |
| `lib/libz.a`, `lib/libcrypto.a`, `include/…` | `sysroot/<triple>/usr/lib/…`, `sysroot/<triple>/usr/include/…` |
| `x86_64-linux-musl/lib/libc++.a` | `lib/x86_64-unknown-linux-musl/libc++.a` |
| `lib/mimalloc-2.2/`, `lib/mimalloc-3.3/` | musl: built into `libc.a`; gnu/macOS: `sysroot/<triple>/usr/lib/libmimalloc.a` |
| `lib/clang/22/…` | `lib/clang/<llvmMajor>/…` (read `llvmMajor` from `share/elide-toolchain/manifest.json`) |
| `--sysroot=$MUSL_HOME/x86_64-linux-musl --gcc-toolchain=$MUSL_HOME` | `x86_64-unknown-linux-musl-clang` (cfg supplies everything) |
| `x86_64-linux-musl-gcc` | still present, as a shim over clang |
| `-lstdc++` | drop it; libc++ is implied |
| `musl-toolchain-<sha>-amd64.txz` | `elide-toolchain-<ver>-linux-amd64.tar.xz` |

Other changes to plan for:

- This is a clean break from the old layout; consumers migrate when they bump their pin.
- glibc 2.17 is the baseline for all consumers (Elide/WHIPLASH, Bali/crema-jit, Komodo).
- The default TLS library is AWS-LC 5.x (`libcrypto.a`, `libssl.a`); OpenSSL is off by default. The Elide ACCP fork (`elide-tools/amazon-corretto-crypto-provider`) must be synced to upstream `main` to build against AWS-LC v5.
- Host GCC is no longer part of the bundle; `musl-cross-make` is gone.

## Building from source

See [Building and verification](building.md).

## Flags

Component and consumer flags come from the `cflags/` submodule profiles: `cflags/cli/cflags.sh <os> <arch>`, then the `cflags.local/` overlay, then `-march`/`-mtune` from `versions.env`. Compile profiles (`base`, `linux`, `linux-amd64`, ...) apply to every compilation unit and intermediate link; binary profiles (`*-bin`) apply only to a consumer's final link. Both Linux libcs use the `linux-<arch>` profile. The toolchain layer (libc, runtimes, LLVM, mimalloc) keeps its own tuned flags.

The shared profiles enable strong stack canaries while retaining `-O3`, ThinLTO, PIC,
unwind information and full RELRO. Linux x86-64 follows `MARCH_AMD64` without extra
crypto/GFNI/RNG ISA switches; crypto libraries may still select optimized implementations
at runtime. Relative C++ vtables and aggressive constant merging are disabled. Rebuild
all component archives when adopting the 2026.11 profiles; do not reuse archives compiled
with the previous C++ ABI settings.

The GNU `libgcc_s.so` compatibility script groups libunwind with compiler-rt builtins,
so Rust's `-nodefaultlibs` links also resolve `__gcc_personality_v0` (including TSAN).
For TSAN hosted inside a JVM, set `TSAN_OPTIONS=ignore_noninstrumented_modules=1` to
avoid reports from the uninstrumented VM; this reduces coverage of those modules.

`clangd` comes from the same LLVM revision as clang. Stage 95 runs a real LSP session
from a renamed bundle under a path containing spaces, checking standard-library header
resolution, diagnostics, definition and rename for each target. LLVM license notices and
an explicit clangd SBOM entry accompany it.

See [2026.11 dependency migration](notes/2026-11-dependency-migration.md) for the
required Elide consumer updates (AWS-LC, ACCP and SQLite).

**glibc and DT_RELR.** `cflags/linux.txt` carries `-Wl,-z,pack-relative-relocs`, which makes lld emit a `GLIBC_ABI_DT_RELR` version need (glibc 2.36+). The build removes that flag for gnu triples whenever the glibc floor is below 2.36. Consumers applying the cflags profile themselves to gnu targets must drop it too, or their binaries will not load on older glibc.
