# Building and verification

## Building

Host requirements:

- **Linux:** `build-essential bison gawk python3 ninja-build cmake rsync xz-utils curl clang lld llvm` (apt), bash >= 4, and optionally `ccache` (see [Build speed](#build-speed)) and `docker` for the container checks. No `sudo` is used by the build.
- **macOS:** Xcode Command Line Tools, then `brew install bash ninja cmake rsync xz` (optionally `ccache`). bash >= 4 is required, so run `build.sh` with Homebrew bash. GNU rsync is required because the build uses `rsync --from0 --files-from`, which macOS's bundled openrsync lacks. Homebrew's bin directory must precede `/usr/bin` on `PATH`. Homebrew's standard shell setup does this, and the CI build job checks that GNU rsync is the one found.

```sh
git submodule update --init --depth=1 --recursive
./build.sh
```

glibc is not a submodule: stage 20 downloads CentOS 7.9's `glibc`, `glibc-devel`, `glibc-headers` and `glibc-static` RPMs (release `GLIBC_RPM_RELEASE`) from vault.centos.org, checks each against its pinned SHA256 (the repodata digest), and unpacks them with `scripts/rpm-extract.py`. glibc 2.17 cannot be built with a current GCC or clang.

Options:

| Option | Meaning |
|---|---|
| `--from STAGE` | run STAGE and every later stage, ignoring (and clearing) their stamps |
| `--only STAGE` | run only STAGE |
| `--targets LIST` | comma-separated triples for per-target stages (default: all in the bundle) |
| `--clean` | delete `out/<os>-<arch>` first |
| `--dry-run` | print the stages that would run |

Output goes to `out/<os>-<arch>/` (stamps in `stamps/`); the packaged archive, checksum and SBOM land in `dist/`. Completed stages are skipped on re-run. Stage names are checked before `--clean` deletes anything.

Logs: each stage's full output goes to `out/<os>-<arch>/logs/<stage>.log`. The console shows one start and one finish line per stage, plus the verification results; when a stage fails, the last 200 lines of its log are printed (`FAIL_TAIL_LINES=N` changes that). Set `VERBOSE=yes` to stream every stage's output. In CI, each stage is a collapsible log group and the `logs/` directory is uploaded as the `build-logs-<os>-<arch>` artifact on every run, pass or fail.

To rebuild stage 1, use `--from 10-llvm-stage1`, not `--only 10-llvm-stage1`. Stage 10 wipes `out/<os>-<arch>/stage1`, and the runtimes and cfgs that stage 30 installs there would then be missing.

Stages:

| # | Stage | What it does |
|---|---|---|
| 00 | `sources` | Check submodule pins; fetch Linux kernel headers (checksummed) into each Linux sysroot (macOS: check Xcode CLT) |
| 10 | `llvm-stage1` | Linux: the bootstrap clang/lld (not shipped), by default the pinned official LLVM release (`STAGE1_SOURCE`), else built by the host compiler. macOS: builds the full LLVM (floor 12.0) and compiler-rt directly into the bundle |
| 20 | `libc-gnu` | Unpack the pinned glibc 2.17 RPMs into the gnu sysroot (Linux) |
| 21 | `libc-musl` | Stage-1 clang builds musl phase 1 (Linux) |
| 30 | `runtimes` | compiler-rt, libunwind, libc++abi, libc++ per Linux triple, as fat ThinLTO archives; the memprof runtime for x86_64 gnu |
| 31 | `sanitizer-runtimes` | compiler-rt sanitizer runtimes and libFuzzer per Linux triple (matrix in `versions.env`) |
| 35 | `mimalloc` | musl: mimalloc into musl phase 2; gnu/macOS: standalone `libmimalloc.a`; `libelidealloc-shim.a` for every triple |
| 36 | `llvm-deps` | Static zlib-ng and zstd for the stage-2 LLVM build (Linux, not shipped) |
| 40 | `llvm-stage2` | Rebuild clang/clangd/lld/bolt/polly against the gnu 2.17 sysroot with static libc++ (Linux); these are the shipped tools |
| 45 | `propeller` | `generate_propeller_profiles` (with DeduBB) linked against the stage-2 LLVM build tree, offline from cached deps (Linux) |
| 50 | `components` | Build each enabled component per triple with the bundle's own `<triple>-clang`, installing `.pc` files |
| 60 | `sanitizer-addons` | With `BUILD_SANITIZER_VARIANTS=yes`: per sanitizer (asan/tsan/msan, gnu), instrumented libc++ and components and the `sysroot/<triple>+<san>` farm |
| 90 | `package` | Helper CLI, cfgs, shims, CMake files, manifest and SBOM; strip; `tar -cJf` plus `.sha256`; one archive per sanitizer add-on |
| 95 | `verify` | Run every check (see Verification) against a fresh extraction of the archive |

**`vars.sh` toggles** (each may also be set in the environment):

- Components: `BUILD_ZLIB_NG`, `BUILD_ZSTD`, `BUILD_BROTLI`, `BUILD_SNAPPY`, `BUILD_LZ4`, `BUILD_CRC32C`, `BUILD_AWS_LC`, `BUILD_SQLITE3ELIDE` (default yes); `BUILD_OPENSSL`, `BUILD_ZLIB`, `BUILD_SQLITE`, `BUILD_SQLCIPHER`, `BUILD_CAPNP`, `BUILD_HIREDIS`, `BUILD_LEVELDB` (default no).
- musl: `MUSL_USE_MIMALLOC`, `MUSL_USE_LTO`. mimalloc: `MIMALLOC_SECURE`, `MIMALLOC_GUARDED`.
- LLVM features: `LLVM_DEDUBB` (DeduBB patch, default yes), `BUILD_PROPELLER` (stage 45, default yes).
- `USE_CCACHE`, `USE_SCCACHE`, `STAGE1_SOURCE` (see Build speed), `REQUIRE_CONTAINER_CHECKS` (fail instead of skip when docker is missing), `REQUIRE_LBR` (fail instead of skip when the live Propeller check finds no LBR/SPE).
- Local patches live in `src/patches/<component>/`. Stage 00 un-applies them before its clean-submodule check, and the stages that build a component apply them again.
- Sanitizers: `BUILD_SANITIZERS` (runtimes and libFuzzer in the bundle, default yes), `BUILD_SANITIZER_VARIANTS` (add-on archives, default no; CI sets yes on push to `main` and on release).

> [!IMPORTANT]
> Switching providers (zlib vs zlib-ng, OpenSSL vs AWS-LC) or disabling components requires `./build.sh --clean`. Otherwise stale archives and shared objects already in the sysroot shadow the new ones.

### Build speed

| Knob | Default | Meaning |
|---|---|---|
| `STAGE1_SOURCE` | `prebuilt` on Linux when `versions.env` pins a release for the host arch, else `build` | `prebuilt`: stage 10 downloads the official LLVM `LLVM_VERSION` release (`LLVM_PREBUILT_LINUX_<ARCH>_{URL,SHA256}`, checksummed) and uses it as the bootstrap compiler, with its bundled runtimes removed. `build`: build clang/lld from the patched tree with the host compiler. macOS always builds (its stage 10 is the shipped LLVM). |
| `USE_CCACHE` | `auto` (on when `ccache` is on `PATH`) | `yes`/`no`/`auto`. When on, CMake builds use `ccache` as the compiler launcher, and it takes precedence over `USE_SCCACHE`. Unset settings default to `CCACHE_BASEDIR=<repo>`, `CCACHE_COMPILERCHECK=content`, `CCACHE_NOHASHDIR=1` and `CCACHE_MAXSIZE=50G`. Autotools components are not cached. |
| `JOBS` | min(CPUs, available GiB / 2) | Compile parallelism. |
| `LINK_JOBS` | available GiB / 8, clamped to 1..4 | Concurrent links in LLVM builds (`LLVM_PARALLEL_LINK_JOBS`) and in stage 45 (a Ninja link pool). |
| `ELIDE_MEM_GB`, `ELIDE_CPU_COUNT` | detected | Override the detected memory (Linux `MemAvailable`, macOS `hw.memsize`) and CPU count. |
| `XZ_LEVEL` | `9` for releases, `6` otherwise | xz level for the archive and the sanitizer add-ons. A release is a `TOOLCHAIN_VERSION` with no `-dev` or `+` suffix, or `RELEASE_BUILD=yes` (`RELEASE_BUILD=no` forces non-release). |

`build.sh` logs the chosen `JOBS`/`LINK_JOBS`, the compiler launcher and the stage-1 source when it starts.

Persistent caches: downloads (kernel headers, Propeller deps, the prebuilt LLVM tarball) go to `ELIDE_CACHE_DIR` (default `out/cache`), and ccache uses `CCACHE_DIR` (default `~/.cache/ccache`). CI sets both under `$HOME/.cache/elide-toolchain/v2/<scope>/<os>-<arch>/` because `actions/checkout` cleans ignored files in the workspace, and prints `ccache --show-stats` after every build. The prebuilt stage 1 is safe to use because the version is the same, so stage 1 produces bitcode the shipped LLVM reads. Our LLVM patches only affect the shipped stage 2 and compiler-rt, which stage 30 builds from the patched tree (spec §3.3b). Changing `STAGE1_SOURCE` takes effect on `--from 10-llvm-stage1`.

LLVM builds disable precompiled headers when ccache or sccache is active. LLVM 23's
default PCH otherwise makes most of its compilations uncacheable with strict ccache
settings. Builds without a compiler cache retain LLVM's PCH defaults. The first build
after this change populates the cache; subsequent builds benefit. CI reports verbose
ccache statistics, including reasons for uncacheable calls.

**Build times.** See [`docs/notes/build-timings.md`](notes/build-timings.md) for per-stage wall times and the host they were measured on.

## Versions

`versions.env` is the single source of truth: toolchain version, floors, `-march`/`-mtune`, libc versions, kernel headers (with checksum), and a generated pin (`*_REV`, `*_VERSION`) per submodule. Components track the latest stable release.

- `scripts/bump-submodules.sh` moves every submodule to its latest stable tag (or branch tip) and regenerates the pin block.
- `scripts/check-versions.sh` verifies the pins against `git submodule status` (run in CI and in stage 00).
- Releases are CalVer, `vYYYY.M.N`, with the month not zero-padded (`v2026.9.0`, not `v2026.09.0`; CI rejects padded versions). `git tag vYYYY.M.N && git push --tags` builds all three bundles, publishes the GitHub Release (archives, checksums, SBOMs) and mirrors it to R2.

## Verification

Stage 95 (`scripts/verify/checks.sh`) runs against a fresh extraction of the packaged archive and ends with `verification: N failure(s)`:

- **manifest:** `manifest.json` parses; its `version` (and `elide-toolchain version`) is the build's version, `llvmMajor` is the LLVM major, and every submodule's recorded revision is its `*_REV` pin in `versions.env`.
- **no build paths:** no text file mentions the build directory and there are no absolute symlinks.
- **smoke:** per triple, compile, link and run C and C++ (iostream, exceptions, threads); musl output is static.
- **werror:** `<triple>-clang -Werror -c` is clean (cfg flags raise no unused-argument warnings).
- **components:** a program links against every enabled component. On Linux, a `-shared` object also links `libssl.a`/`libcrypto.a` cleanly under `-z defs` (the ACCP/JNI case), and for gnu it stays within the glibc floor.
- **SQLite authorizer:** each `libsqlite3elide.a`, including sanitizer add-ons, exports `sqlite_set_1authorizer` and `sqlite_clear_1authorizer`; the installed JNI header declares both.
- **bitcode:** every member of every sysroot archive and of the libc++ runtimes is LLVM bitcode (raw or the Mach-O wrapper) or an object with a `.llvm.lto` section, produced by the bundle's LLVM major. Each occurrence of a duplicated member name is checked. Exempt: compiler-rt, glibc's own archives (gnu only), musl's empty stub archives, and hand-written assembly. A member counts as assembly only if it is a native object with no `.llvm.lto` and no compiler `.comment`, and its source is assembly (a CMake `*.S.o`/`*.s.o`/`*.asm.o` object, or a musl `src/*/<arch>/*.s` source).
- **fat LTO (Linux):** issue [#13](https://github.com/elide-dev/toolchain/issues/13). A C program calls `ZSTD_versionNumber` from the shipped fat `libzstd.a`. With a plain `-flto=thin` link, the driver passes `--fat-lto-objects` and the function is inlined and dropped (no symbol left). With `-fno-fat-lto-objects` or without `-flto`, the archive's native global is linked. Every variant runs. When `rustc` (LLVM <= the bundle's) and the target's std are installed, a Rust caller linked with `elide-toolchain flags lto`'s `ELIDE_RUSTFLAGS` must not end up with the archive's native global.
- **distributed ThinLTO (Linux):** issue [#18](https://github.com/elide-dev/toolchain/issues/18). Index-only C++ links use Bazel's split plugin options, prefix/suffix rewriting, and final-link response file; joined options are also covered. Imports and the response file must contain only relative project paths. Isolated backend compilations receive only their bitcode, index and declared imports, then executables link and run with libc++ and zstd; glibc also checks a shared-library link. Both opt-outs are checked, and an explicit fat-LTO control reproduces the unsafe archive imports and response-file entries.
- **rust:** when `rustc` and the target's std are installed, a hello world with a caught panic links through `<triple>-clang` and runs (musl: `+crt-static`; gnu: within the glibc floor, no `libgcc_s`). Otherwise it is skipped with a warning.
- **glibc floor (gnu):** no `GLIBC_x.y` above 2.17 and no `GLIBC_ABI_DT_RELR` in outputs or bundled ELFs; no `libstdc++`/`libgcc_s` in `NEEDED`.
- **interp (gnu):** `PT_INTERP` is the canonical loader path.
- **musl libc (musl):** a `libc.a` member carries bitcode for the musl triple and native code, and a `-fno-lto` link works.
- **gcc shims (musl):** `<arch>-linux-musl-gcc hello.c -static` links and runs.
- **macOS minos / dylibs (macOS):** `minos` <= 12.0 and no unexpected dylib dependencies.
- **containers (Linux):** gnu smoke binaries and `clang --version` run inside `centos:7` (glibc 2.17), `amazonlinux:2` and `ubuntu:20.04` (skipped without docker unless `REQUIRE_CONTAINER_CHECKS=yes`).
- **propeller (Linux):** the shipped tool reproduces upstream's golden profile from checked-in perf data; a relink of upstream's fixture with the generated profiles shows functions in profile order, `.text.hot`/`.text.split`, and cold parts in `.text.split`. A live check runs only on hosts with LBR/SPE (otherwise a warned skip; `REQUIRE_LBR=yes` makes it fail).
- **dedubb (Linux):** directives from a labelled binary; a relink with them folds the duplicate into a branch to `DeduBB.master.0` and the program still works. Without directives, the compiler's output is deterministic and has no DeduBB trace.
- **elidealloc shim:** the shim test (hot/cold/default mapping, all eight overloads, alignment, OOM, cross-thread frees, C API, stats, env tuning) links through the shipped `.pc` and passes.
- **memprof:** on x86_64 gnu, instrument, run, merge `--profiled-binary`. On every triple, a YAML profile is matched, the ThinLTO link clones the allocation context and calls `_Znam12__hot_cold_t`, and the cold object lands in the COLD partition. Without `-supports-hot-cold-new` no hint survives. No memprof runtime ships for other triples.
- **relocatable:** the bundle is copied elsewhere and smoke tests plus `elide-toolchain doctor` rerun.
- **sanitizers** (`scripts/verify/sanitizers.sh`): the runtimes match the matrix (musl has no dynamic-only runtime); every sanitizer's fixture bug (`tests/fixtures/sanitizers/`) is reported through its wrapper, and the msan wrapper refuses to work without its add-on; `-static` is refused for the dynamic-only runtimes; a `-shared-libsan` library loaded by an uninstrumented host trips with the runtime `LD_PRELOAD`ed; a libFuzzer target runs.
- **sanitizer add-ons:** each add-on archive is checksummed, has the single root and shares no entry with the main archive; it is extracted over its own hardlinked copy of the main bundle (so add-ons are independent) and checked there: every archive in its sysroot and libc++ dir is instrumented, no libunwind is shipped, the farm has no dangling or absolute links and no `.so` beside a replaced `.a`; the fixture bug trips; libc++, every component (round-tripping real data in heap buffers) and the mimalloc shim run with no report, with and without `-flto=thin`; a CMake consumer resolves the add-on's archives; its archives pass the bitcode check; ASan sees `mi_malloc` overflows; `env --sanitizer` points at the add-on; and (asan) Rust nightly + C trips with clang's runtime when a nightly rustc is available.

Unit tests and shellcheck: `tests/run.sh`. Per-stage checks: `tests/stages/*.check.sh`. Action tests: `cd action && bun test`.
