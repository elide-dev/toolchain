# Elide Toolchain

A self-contained native toolchain: LLVM 23 (clang, lld, BOLT, Polly), libc++ / libc++abi / libunwind, compiler-rt, and a full tree of pre-built static libraries (zlib-ng, zstd, brotli, snappy, lz4, crc32c, AWS-LC, mimalloc, and optionally OpenSSL, zlib, SQLite, SQLCipher, Cap'n Proto, hiredis, LevelDB), all compiled with one consistent flags profile. Linux bundles carry two sysroots, fully static **musl** (with mimalloc built into `libc.a`) and **glibc 2.34**; macOS bundles carry a component overlay on top of the system SDK. It is built from source, one bundle per host OS/arch, and is used by Elide, Komodo, Bali (crema-jit) and GraalVM `native-image` builds (`--libc=musl`).

Releases are `elide-toolchain-<version>-<os>-<arch>.tar.xz`, each with a `.sha256` and a CycloneDX SBOM, on [GitHub Releases](https://github.com/elide-dev/toolchain/releases) (tags `vYYYY.M.N`; the month is not zero-padded, e.g. `v2026.9.0`), mirrored to `https://static.elideusercontent.com/toolchain/<version>/`.

## Bundles

| Bundle | Triples |
|---|---|
| `linux-amd64` | `x86_64-unknown-linux-musl`, `x86_64-unknown-linux-gnu` |
| `linux-arm64` | `aarch64-unknown-linux-musl`, `aarch64-unknown-linux-gnu` |
| `darwin-amd64` | `x86_64-apple-darwin` |
| `darwin-arm64` | `arm64-apple-darwin` |

Each bundle targets its own OS and architecture (no cross-OS or cross-arch targeting).

Floors:

- **glibc 2.34.** Every glibc-targeted binary, including the bundled clang and lld, references no symbol version newer than `GLIBC_2.34` (RHEL 9, AL2023, Ubuntu 22.04, Debian 12 and newer). Older systems are served by static musl.
- **macOS 12.0** (`minos` <= 12.0).
- **Host ISA:** x86-64-v3 (AVX2) on amd64, `armv8.2-a+crypto+crc+dotprod` on arm64. The shipped tools are built with the same `-march` as the code they produce, so they need such a host.

Every target library (each sysroot's static archives) and the libc++ runtimes (`lib/<triple>/libc++.a`, `libc++abi.a`, `libunwind.a`) carry LLVM 23 ThinLTO bitcode, so downstream links are `-flto=thin` end to end with lld. Components are pure bitcode; musl `libc.a` and libc++/libc++abi/libunwind are fat (bitcode plus native); compiler-rt, glibc's own archives and hand-written assembly members are native only. The LLVM/clang development libraries in `lib/` (`libLLVM*.a`, `libclang*.a`) are host tool libraries and are native code, not bitcode. Consumers using Rust need a rustc whose LLVM major is **<=** the bundle's (`llvmMajor` in `manifest.json`).

Assets are named `elide-toolchain-<version>-<os>-<arch>.tar.xz` (`os` = `linux|darwin`, `arch` = `amd64|arm64`), with one top-level directory, `elide-toolchain/`.

## Install

### GitHub Actions

```yaml
- uses: elide-dev/toolchain/action@<ref>
  with:
    version: latest                    # or 2026.10.0 / v2026.10.0
    target: x86_64-unknown-linux-gnu   # optional: exports CC, CXX, AR, ... for this triple
    github-token: ${{ github.token }}  # optional
```

With no inputs it installs the latest bundle for the runner's OS/arch, exports `ELIDE_TOOLCHAIN_HOME` and adds `bin/` to `PATH`. Outputs: `home`, `version`, `targets`. Inputs for testing and mirrors: `archive` (local `.tar.xz`), `base-url`, `repo`, `os`, `arch`. `latest` is resolved via the Releases API, falling back to the R2 mirror.

### mise

```toml
[tools]
"github:elide-dev/toolchain" = "2026.10.0"
```

mise picks the asset by OS/arch and strips the single top-level directory, so `bin/` is found by default. If that auto-strip is ever unwanted, use the explicit form:

```toml
[tools]
"github:elide-dev/toolchain" = { version = "2026.10.0", bin_path = "elide-toolchain/bin" }
```

mise only provides `PATH`; use `elide-toolchain env` (below) for target settings.

### Manual

```sh
v=2026.10.0; a=elide-toolchain-$v-linux-amd64.tar.xz
curl -LO https://github.com/elide-dev/toolchain/releases/download/v$v/$a
curl -LO https://github.com/elide-dev/toolchain/releases/download/v$v/$a.sha256
shasum -a 256 -c $a.sha256
tar -xJf $a
export ELIDE_TOOLCHAIN_HOME=$PWD/elide-toolchain PATH=$PWD/elide-toolchain/bin:$PATH
```

## Use

Invoke `<triple>-clang` / `<triple>-clang++`; clang loads `bin/<triple>.cfg`, which supplies `--target`, `--sysroot`, `-rtlib=compiler-rt`, `-unwindlib=libunwind`, `-stdlib=libc++` and `-fuse-ld=lld`. Plain `bin/clang` (and `clang --target=<triple>`) auto-loads the cfg too: plain `clang` loads the host's default-triple cfg, which is the gnu triple on Linux and the darwin triple on macOS. Pass `--no-default-config` for a bare clang. The bundle is relocatable. For fully static output use the musl triple with `-static`; static linking of the gnu triple is unsupported.

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

**Rust.** Link through the bundle for cross-language LTO: `CARGO_TARGET_<TRIPLE>_LINKER=<triple>-clang` (printed by `env --target`) with `-Clink-arg=-fuse-ld=lld`. rustc's LLVM major must be <= the bundle's. The gnu std always passes `-lgcc_s`; the gnu sysroot's `usr/lib/libgcc_s.so` is a linker script (`INPUT(-lunwind)`) that resolves it to the static libunwind, so outputs never need `libgcc_s.so.1`. For musl, add `-C target-feature=+crt-static`.

**GraalVM native-image.** Linux bundles ship `<cpu>-linux-musl-gcc` / `-g++` (and `cc`, `c++`, `ar`, `ranlib`, `nm`, `strip`) as shims over clang and the llvm tools, so `native-image --libc=musl` works with `bin/` on `PATH`. The shims never add `-static`.

**Doctor.** `elide-toolchain doctor` compiles, links and runs a C and C++ hello world for every triple in the bundle. Other subcommands: `home`, `targets`, `version`.

C++ implies libc++ on every target; there is no libstdc++ in the bundle, so drop any `-lstdc++`.

## Layout

```
elide-toolchain/
  bin/
    clang clang++ clang-cpp ld.lld lld llvm-ar llvm-nm llvm-ranlib llvm-objcopy llvm-strip ...
    llvm-bolt perf2bolt merge-fdata llvm-profgen llvm-profdata llvm-dwarfdump llvm-dwp   (Linux)
    elide-toolchain                       # helper CLI (POSIX sh)
    <triple>.cfg                          # clang config per target triple
    <triple>-clang  -> clang
    <triple>-clang++ -> clang++
    <arch>-linux-musl-gcc, <arch>-linux-musl-g++   # Linux GCC-named shims
  lib/
    clang/<major>/include/                # resource dir
    clang/<major>/lib/<triple>/libclang_rt.*   # Linux: builtins, crtbegin/crtend, profile
    clang/<major>/lib/darwin/libclang_rt.*     # macOS
    <triple>/libc++.a libc++abi.a libunwind.a  # Linux
  include/
    c++/v1/                               # libc++ headers (Linux)
    <triple>/c++/v1/__config_site
  sysroot/
    <arch>-unknown-linux-musl/usr/{include,lib}   # musl+mimalloc, kernel headers, components
    <arch>-unknown-linux-gnu/usr/{include,lib}    # glibc 2.34, kernel headers, components, libmimalloc.a
    <arch>-apple-darwin/usr/{include,lib}         # macOS component overlay (no SDK)
  share/elide-toolchain/
    manifest.json
    sbom.cdx.json
    cmake/<triple>.cmake
```

`manifest.json` records the version, revision, host floors (`glibcFloor`, `march`), per-target libc and march/mtune, component versions, `llvmMajor` and the cflags profile.

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
- glibc 2.34 is the new baseline for all consumers (Elide/WHIPLASH, Bali/crema-jit, Komodo).
- The default TLS library is AWS-LC 5.x (`libcrypto.a`, `libssl.a`); OpenSSL is off by default. The Elide ACCP fork (`elide-tools/amazon-corretto-crypto-provider`) must be synced to upstream `main` to build against AWS-LC v5.
- Host GCC is no longer part of the bundle (it is used only to compile glibc); `musl-cross-make` is gone.

## Building

Host requirements:

- **Linux:** `build-essential bison gawk python3 ninja-build cmake rsync xz-utils curl clang lld llvm` (apt), bash >= 4, and optionally `docker` for the container checks. No `sudo` is used by the build.
- **macOS:** Xcode Command Line Tools, then `brew install bash ninja cmake rsync xz`. bash >= 4 is required, so run `build.sh` with Homebrew bash. GNU rsync is required because the build uses `rsync --from0 --files-from`, which macOS's bundled openrsync lacks. Homebrew's bin directory must precede `/usr/bin` on `PATH`. Homebrew's standard shell setup does this, and the CI build job checks that GNU rsync is the one found.

```sh
git submodule update --init --depth=1 --recursive
./build.sh
```

Options:

| Option | Meaning |
|---|---|
| `--from STAGE` | run STAGE and every later stage, ignoring (and clearing) their stamps |
| `--only STAGE` | run only STAGE |
| `--targets LIST` | comma-separated triples for per-target stages (default: all in the bundle) |
| `--clean` | delete `out/<os>-<arch>` first |
| `--dry-run` | print the stages that would run |

Output goes to `out/<os>-<arch>/` (stamps in `stamps/`); the packaged archive, checksum and SBOM land in `dist/`. Completed stages are skipped on re-run. Stage names are checked before `--clean` deletes anything.

To rebuild stage 1, use `--from 10-llvm-stage1`, not `--only 10-llvm-stage1`. Stage 10 wipes `out/<os>-<arch>/stage1`, and the runtimes and cfgs that stage 30 installs there would then be missing.

Stages:

| # | Stage | What it does |
|---|---|---|
| 00 | `sources` | Check submodule pins; fetch Linux kernel headers (checksummed) into each Linux sysroot (macOS: check Xcode CLT) |
| 10 | `llvm-stage1` | Linux: host compiler builds clang/lld (not shipped). macOS: builds the full LLVM (floor 12.0) and compiler-rt directly into the bundle |
| 20 | `libc-gnu` | Host GCC builds glibc 2.34 into the gnu sysroot (Linux) |
| 21 | `libc-musl` | Stage-1 clang builds musl phase 1 (Linux) |
| 30 | `runtimes` | compiler-rt, libunwind, libc++abi, libc++ per Linux triple, as fat ThinLTO archives |
| 35 | `mimalloc` | musl: mimalloc into musl phase 2; gnu/macOS: standalone `libmimalloc.a` |
| 36 | `llvm-deps` | Static zlib-ng and zstd for the stage-2 LLVM build (Linux, not shipped) |
| 40 | `llvm-stage2` | Rebuild clang/lld/bolt/polly against the gnu 2.34 sysroot with static libc++ (Linux); these are the shipped tools |
| 50 | `components` | Build each enabled component per triple with the bundle's own `<triple>-clang`, installing `.pc` files |
| 90 | `package` | Helper CLI, cfgs, shims, CMake files, manifest and SBOM; strip; `tar -cJf` plus `.sha256` |
| 95 | `verify` | Run every check (see Verification) against a fresh extraction of the archive |

**`vars.sh` toggles** (each may also be set in the environment):

- Components: `BUILD_ZLIB_NG`, `BUILD_ZSTD`, `BUILD_BROTLI`, `BUILD_SNAPPY`, `BUILD_LZ4`, `BUILD_CRC32C`, `BUILD_AWS_LC` (default yes); `BUILD_OPENSSL`, `BUILD_ZLIB`, `BUILD_SQLITE`, `BUILD_SQLCIPHER`, `BUILD_CAPNP`, `BUILD_HIREDIS`, `BUILD_LEVELDB` (default no).
- musl: `MUSL_USE_MIMALLOC`, `MUSL_USE_LTO`. mimalloc: `MIMALLOC_SECURE`, `MIMALLOC_GUARDED`.
- `USE_SCCACHE`, `REQUIRE_CONTAINER_CHECKS` (fail instead of skip when docker is missing).

> [!IMPORTANT]
> Switching providers (zlib vs zlib-ng, OpenSSL vs AWS-LC) or disabling components requires `./build.sh --clean`. Otherwise stale archives and shared objects already in the sysroot shadow the new ones.

**Build times.** See [`docs/notes/build-timings.md`](docs/notes/build-timings.md) for per-stage wall times and the host they were measured on.

## Versions

`versions.env` is the single source of truth: toolchain version, floors, `-march`/`-mtune`, libc versions, kernel headers (with checksum), and a generated pin (`*_REV`, `*_VERSION`) per submodule. Components track the latest stable release.

- `scripts/bump-submodules.sh` moves every submodule to its latest stable tag (or branch tip) and regenerates the pin block.
- `scripts/check-versions.sh` verifies the pins against `git submodule status` (run in CI and in stage 00).
- Releases are CalVer, `vYYYY.M.N`, with the month not zero-padded (`v2026.9.0`, not `v2026.09.0`; CI rejects padded versions). `git tag vYYYY.M.N && git push --tags` builds all four bundles, publishes the GitHub Release (archives, checksums, SBOMs) and mirrors it to R2.

## Verification

Stage 95 (`scripts/verify/checks.sh`) runs against a fresh extraction of the packaged archive and ends with `verification: N failure(s)`:

- **manifest:** `manifest.json` parses; its `version` (and `elide-toolchain version`) is the build's version, `llvmMajor` is the LLVM major, and every submodule's recorded revision is its `*_REV` pin in `versions.env`.
- **no build paths:** no text file mentions the build directory and there are no absolute symlinks.
- **smoke:** per triple, compile, link and run C and C++ (iostream, exceptions, threads); musl output is static.
- **werror:** `<triple>-clang -Werror -c` is clean (cfg flags raise no unused-argument warnings).
- **components:** a program links against every enabled component. On Linux, a `-shared` object also links `libssl.a`/`libcrypto.a` cleanly under `-z defs` (the ACCP/JNI case), and for gnu it stays within the glibc floor.
- **bitcode:** every member of every sysroot archive and of the libc++ runtimes is LLVM bitcode (raw or the Mach-O wrapper) or an object with a `.llvm.lto` section, produced by the bundle's LLVM major. Each occurrence of a duplicated member name is checked. Exempt: compiler-rt, glibc's own archives (gnu only), musl's empty stub archives, and hand-written assembly. A member counts as assembly only if it is a native object with no `.llvm.lto` and no compiler `.comment`, and its source is assembly (a CMake `*.S.o`/`*.s.o`/`*.asm.o` object, or a musl `src/*/<arch>/*.s` source).
- **rust:** when `rustc` and the target's std are installed, a hello world with a caught panic links through `<triple>-clang` and runs (musl: `+crt-static`; gnu: within the glibc floor, no `libgcc_s`). Otherwise it is skipped with a warning.
- **glibc floor (gnu):** no `GLIBC_x.y` above 2.34 and no `GLIBC_ABI_DT_RELR` in outputs or bundled ELFs; no `libstdc++`/`libgcc_s` in `NEEDED`.
- **interp (gnu):** `PT_INTERP` is the canonical loader path.
- **musl libc (musl):** a `libc.a` member carries bitcode for the musl triple and native code, and a `-fno-lto` link works.
- **gcc shims (musl):** `<arch>-linux-musl-gcc hello.c -static` links and runs.
- **macOS minos / dylibs (macOS):** `minos` <= 12.0 and no unexpected dylib dependencies.
- **containers (Linux):** gnu smoke binaries and `clang --version` run inside `almalinux:9` and `ubuntu:22.04` (skipped without docker unless `REQUIRE_CONTAINER_CHECKS=yes`).
- **relocatable:** the bundle is copied elsewhere and smoke tests plus `elide-toolchain doctor` rerun.

Unit tests and shellcheck: `tests/run.sh`. Per-stage checks: `tests/stages/*.check.sh`. Action tests: `cd action && bun test`.

## Flags

Component and consumer flags come from the `cflags/` submodule profiles: `cflags/cli/cflags.sh <os> <arch>`, then the `cflags.local/` overlay, then `-march`/`-mtune` from `versions.env`. Compile profiles (`base`, `linux`, `linux-amd64`, ...) apply to every compilation unit and intermediate link; binary profiles (`*-bin`) apply only to a consumer's final link. Both Linux libcs use the `linux-<arch>` profile. The toolchain layer (libc, runtimes, LLVM, mimalloc) keeps its own tuned flags.

**glibc and DT_RELR.** `cflags/linux.txt` carries `-Wl,-z,pack-relative-relocs`, which makes lld emit a `GLIBC_ABI_DT_RELR` version need (glibc 2.36+). The build removes that flag for gnu triples whenever the glibc floor is below 2.36. Consumers applying the cflags profile themselves to gnu targets must drop it too, or their binaries will not load on glibc 2.34.
