# Universal Native Toolchain — Design

**Date:** 2026-10-04
**Status:** Revised after review (Fable, 2026-10-04) — approved by Fable (delegated reviewer), 2026-10-04
**Repo:** `elide-dev/musl-toolchain` → to be renamed `elide-dev/toolchain`

## 1. Intent

Transition this repo from a musl-only, linux-amd64-only toolchain into a
universal native toolchain used by Elide, Bali and Komodo (and the labs
projects WHIPLASH / HEATWAVE):

- A full component tree for **musl** and for **glibc** on Linux.
- Bundles for **linux** and **macOS**, on **x86-64** and **arm64**.
- All components updated to their latest stable releases.
- Seamless consumption from **GitHub Actions** (select, download, install any
  bundle) and from **developer machines via mise**.

### Success criteria

1. CI produces four bundles — `linux-amd64`, `linux-arm64`, `darwin-amd64`,
   `darwin-arm64` — from one tagged commit, published to GitHub Releases with
   checksums and an SBOM, mirrored to R2.
2. Each Linux bundle compiles, links and runs C and C++ programs for both
   `<arch>-unknown-linux-musl` (fully static) and `<arch>-unknown-linux-gnu`,
   with every component library available for both.
3. Every glibc-targeted binary — including the shipped clang/lld themselves —
   references no glibc symbol version newer than **GLIBC_2.34**.
4. macOS bundles produce binaries with `minos` ≤ **12.0**.
5. `uses: elide-dev/toolchain/action@<ref>` with no inputs installs the latest
   bundle for the runner's OS/arch; `mise use github:elide-dev/toolchain@<ver>`
   does the same on a developer machine.

### Decisions (with rationale)

| Topic | Decision | Why |
|---|---|---|
| Host/target model | Native per host: each bundle targets its own OS/arch | Matches CI shape; avoids cross sysroots and macOS SDK licensing |
| Linux packaging | One bundle per arch; one shared LLVM; two sysroots (`musl`, `gnu`) | LLVM built once; libc selected by triple |
| glibc version | **2.34**, built from source, branch `release/2.34/master` | Consumers range 2.17–2.38 with no shared pin; released elide already requires 2.34; RHEL 9 / AL2023 / Ubuntu 22.04 / Debian 12+. Older distros are served by static musl. Release branch carries CVE backports without raising the symbol floor |
| C++ runtime | LLVM libc++/libc++abi/libunwind + compiler-rt (builtins, crt) on both libcs | One compiler, consistent runtime; removes GCC from the bundle |
| GCC | Host GCC used **only** to compile glibc (glibc 2.34 cannot build with clang). `musl-cross-make` removed | Eliminates the slowest stage and the GCC 15 cross build |
| Host floor of shipped tools | Linux: LLVM stage 2 built against our gnu 2.34 sysroot, static libc++. macOS: single stage with `-mmacosx-version-min=12.0` | Bundle runs on the same hosts it targets |
| macOS floor | 12.0 | `cflags/` documented floor (chained fixups); elide's C builds use 12.3 |
| Compatibility | **Clean break** from the `musl-toolchain` / `1.2.5/` layout | Consumers pin old revisions; they migrate when they bump (Claude will migrate Bali, Elide, Komodo) |
| Component versions | Latest stable tag of each; LLVM on `llvmorg-23.x`; musl stays on `elide-v1.2.5` fork | Recorded once in `versions.env` |
| Naming | `elide-toolchain-<version>-<os>-<arch>.tar.xz`, root dir `elide-toolchain/`, env `ELIDE_TOOLCHAIN_HOME` | Matches repo rename to `elide-dev/toolchain` |
| Versioning | CalVer tags `vYYYY.MM.N` (e.g. `v2026.10.0`) | Toolchain is a rolling bundle of many upstream versions |
| Publishing | GitHub Releases (primary) + R2 mirror | Releases API gives discovery for action + mise `github:` backend without custom index code |

## 2. Bundle layout

```
elide-toolchain/
  bin/
    clang clang++ clang-cpp ld.lld lld llvm-ar llvm-nm llvm-ranlib llvm-objcopy llvm-strip …
    llvm-bolt perf2bolt merge-fdata llvm-profgen llvm-profdata llvm-dwarfdump llvm-dwp
    elide-toolchain                         # helper CLI (POSIX sh), see §5.3
    <triple>.cfg                            # one clang config per target triple
    <triple>-clang   -> clang
    <triple>-clang++ -> clang++
    <arch>-linux-musl-gcc, <arch>-linux-musl-g++   # Linux: GCC-named shims, see §2.3
  lib/
    clang/<major>/include/…                 # clang resource dir
    clang/<major>/lib/<triple>/libclang_rt.*  # Linux: builtins, crtbegin/crtend, profile
    clang/<major>/lib/darwin/libclang_rt.*    # macOS: osx builtins, profile
    <triple>/libc++.a libc++abi.a libunwind.a # per-target runtime dir (Linux)
  include/
    c++/v1/                                 # libc++ shared headers (Linux)
    <triple>/c++/v1/__config_site           # per-triple libc++ config (searched first by clang)
  sysroot/
    <arch>-unknown-linux-musl/usr/{include,lib}   # musl+mimalloc, kernel headers, components
    <arch>-unknown-linux-gnu/usr/{include,lib}    # glibc 2.34, kernel headers, components, libmimalloc.a
    <arch>-apple-darwin/usr/{include,lib}         # macOS: components overlay (no SDK)
  share/elide-toolchain/
    manifest.json                           # see §2.2
    sbom.cdx.json                           # CycloneDX 1.6, generated from versions.env
    cmake/<triple>.cmake                    # CMake toolchain files (relative to bundle root)
```

Triples per bundle:

| Bundle | Triples |
|---|---|
| linux-amd64 | `x86_64-unknown-linux-musl`, `x86_64-unknown-linux-gnu` |
| linux-arm64 | `aarch64-unknown-linux-musl`, `aarch64-unknown-linux-gnu` |
| darwin-amd64 | `x86_64-apple-darwin` |
| darwin-arm64 | `arm64-apple-darwin` |

### 2.1 Clang config files

Invoking `<triple>-clang` makes clang auto-load `bin/<triple>.cfg`. Paths use
`<CFGDIR>` so the bundle is relocatable.

Linux (`x86_64-unknown-linux-gnu.cfg`, musl analogous):

```
--target=x86_64-unknown-linux-gnu
--sysroot=<CFGDIR>/../sysroot/x86_64-unknown-linux-gnu
-rtlib=compiler-rt
-unwindlib=libunwind
-stdlib=libc++
-fuse-ld=lld
```

The musl config additionally passes `-static` only via the helper's
`--static` mode, not unconditionally (consumers building `.so` files need
dynamic-capable defaults). Static linking of the **gnu** triple is
unsupported (NSS/`dlopen` semantics); use musl for fully static output.

C++ on gnu targets links libc++ (`-lc++ -lc++abi -lunwind` are implied by
`-stdlib=libc++`); there is no libstdc++ in the sysroot, so consumer flags
like `-lstdc++` must be dropped when migrating. Verification (§6) checks that
cfg-supplied link flags don't trip `-Werror` on compile-only invocations;
if they do, the cfgs add `-Qunused-arguments` (already in `cflags/base.txt`,
so consumers see no behavioural change).

macOS (`arm64-apple-darwin.cfg`):

```
--target=arm64-apple-macos12.0
-isystem <CFGDIR>/../sysroot/arm64-apple-darwin/usr/include
-L<CFGDIR>/../sysroot/arm64-apple-darwin/usr/lib
-fuse-ld=lld
```

The SDK is resolved by clang from `SDKROOT`; the helper CLI sets `SDKROOT`
from `xcrun --show-sdk-path` when unset. macOS uses the system libc++, and
the bundle's own `libclang_rt.osx.a` (mainline clang always links it from
its resource dir). The overlay `-isystem` intentionally shadows SDK headers
for bundled components (e.g. zlib-ng's compat `zlib.h` over the SDK's zlib).

### 2.3 GCC-named musl shims

GraalVM `native-image --libc=musl` and existing Elide/WHIPLASH builds invoke
`<arch>-linux-musl-gcc` by name. The Linux bundle ships
`bin/<arch>-linux-musl-gcc` / `-g++` as small POSIX-sh wrappers that `exec`
`<arch>-unknown-linux-musl-clang{,++}` with the given arguments (never
adding `-static`; native-image passes it itself), dropping GCC-only flags
clang rejects (list maintained in the wrapper, initially
empty — populated as migration finds them). The `-g++` shim inherits
`-stdlib=libc++` from the cfg, so consumer `-lstdc++` must be dropped on the
musl path too. These are part of the bundle contract, not a consumer
migration step.

### 2.2 manifest.json

```json
{
  "name": "elide-toolchain",
  "version": "2026.10.0",
  "revision": "<git sha>",
  "host": { "os": "linux", "arch": "amd64", "glibcFloor": "2.34" },
  "targets": [
    { "triple": "x86_64-unknown-linux-musl", "libc": "musl", "libcVersion": "1.2.5",
      "libcRevision": "<elide-v1.2.5 fork sha>",
      "march": "x86-64-v3", "mtune": "znver3" },
    { "triple": "x86_64-unknown-linux-gnu", "libc": "glibc", "libcVersion": "2.34",
      "march": "x86-64-v3", "mtune": "znver3" }
  ],
  "components": { "llvm": "23.1.x", "zlib-ng": "…", "…": "…" },
  "cflagsProfile": "linux-amd64"
}
```

Generated at package time from `versions.env`; consumers may read it instead
of hard-coding paths (e.g. `lib/clang/<major>`).

## 3. Build system

### 3.1 Structure

```
build.sh                    # orchestrator: args, config, stage loop
versions.env                # all versions, pins, checksums, floors, march/mtune
vars.sh                     # optional local overrides (component toggles, flags) — unchanged role
scripts/lib/
  common.sh                 # logging, env save/restore, stamps, patch application
  platform.sh               # os/arch detection, triple mapping, bundle triples
  flags.sh                  # cflags profile resolution (moved from build.sh), per-triple flags
  cmake.sh                  # run_cmake / run_cmake_runtime generalized to (triple, prefix)
scripts/stages/
  00-sources.sh
  10-llvm-stage1.sh
  20-libc-gnu.sh
  21-libc-musl.sh
  30-runtimes.sh
  35-mimalloc.sh
  36-llvm-deps.sh
  40-llvm-stage2.sh
  50-components.sh
  90-package.sh
  95-verify.sh
scripts/components/<name>.sh  # one file per component: build_<name> <triple> <prefix>
src/patches/<component>/*.patch
src/mimalloc-musl-glue.c      # unchanged
src/elide-toolchain           # helper CLI source (copied into bin/)
src/cfg/                      # cfg templates
```

### 3.2 Invocation

```
./build.sh                         # all stages for the native host
./build.sh --from 50-components    # resume
./build.sh --only 95-verify
./build.sh --targets x86_64-unknown-linux-gnu   # restrict per-triple stages
./build.sh --clean                 # wipe out/<os>-<arch>
```

Output tree: `out/<os>-<arch>/{build/<stage>/…, stage1/, stamps/, elide-toolchain/}`.
Each stage writes `stamps/<stage>.done` on success; the orchestrator skips
stamped stages unless `--from`/`--only`/`--clean` says otherwise. No `sudo`
anywhere. `out/` is git-ignored.

### 3.3 Stages

| # | Stage | Linux | macOS |
|---|---|---|---|
| 00 | sources | Check submodules initialized; download Linux kernel tarball (`LINUX_HEADERS_VERSION`, sha256 in `versions.env`) into `out/cache/`, `make headers_install ARCH=<karch>` into each Linux sysroot | Check submodules; verify Xcode CLT present |
| 10 | llvm-stage1 | Host clang (or gcc) builds `clang;lld` + llvm tools into `out/…/stage1` (not shipped). `LLVM_TARGETS_TO_BUILD="X86;AArch64"` | Host Apple clang builds `LLVM_PROJECTS` with `CMAKE_OSX_DEPLOYMENT_TARGET=12.0`, installs directly into bundle; runtimes: compiler-rt **builtins + profile** (`COMPILER_RT_BUILD_BUILTINS=ON`, `COMPILER_RT_ENABLE_IOS=OFF`, watchOS/tvOS off) → `lib/clang/<major>/lib/darwin/` |
| 20 | libc-gnu | Host GCC builds glibc with `CFLAGS="-O2 -std=gnu11"` (GCC 15 defaults to C23, which glibc < 2.39 cannot build under), `--disable-werror`, `--enable-kernel=4.18`, `--prefix=/usr`, `--libdir=/usr/lib`, `libc_cv_slibdir=/usr/lib` (glibc otherwise uses `lib64`), `--with-headers=<sysroot>/usr/include`, `DESTDIR=sysroot/<gnu triple>`, patches from `src/patches/glibc/`. Host deps: bison, gawk, python3. Because `slibdir` = `/usr/lib`, the stage
explicitly creates the canonical loader path inside the sysroot
(`lib64/ld-linux-x86-64.so.2` on x86_64, `lib/ld-linux-aarch64.so.1` on
aarch64, as relative symlinks to `usr/lib/…`) so `libc.so`'s
`AS_NEEDED(ld-linux…)` resolves at link time; PT_INTERP stays the host's
canonical path. Relocatability of `libc.so`/`libpthread.so` linker scripts is verified (lld resolves absolute script paths against the sysroot); rewrite to relative paths only if verification fails | skip |
| 21 | libc-musl | Stage-1 clang builds musl phase 1 (mallocng) into `sysroot/<musl triple>/usr` | skip |
| 30 | runtimes | For each Linux triple, stage-1 clang runs the LLVM runtimes build with bare `--target/--sysroot` flags (**not** the cfg, whose `-rtlib=compiler-rt` would fail cmake's link probes before builtins exist). Pass 1: compiler-rt builtins + crt (`COMPILER_RT_BUILD_CRT=ON`, `CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY`). Pass 2: libunwind, libc++abi, libc++ (static, `LIBCXX_HARDENING_MODE=fast`, `LIBCXX_INSTALL_INCLUDE_TARGET_DIR=include/<triple>/c++/v1`), compiler-rt profile. musl uses `LIBCXX_HAS_MUSL_LIBC=ON`. Installed into **both** the bundle and the stage-1 prefix (so stage-1 clang resolves them from its own resource dir in later stages) | skip (done in 10) |
| 35 | mimalloc | musl: mimalloc object (MI_OVERRIDE=OFF) + glue, then musl phase 2 with `USE_MIMALLOC=yes`, `-flto=thin -ffat-lto-objects` (archive members carry both bitcode and native code, so lld does cross-language LTO while GNU ld, older rust-lld, and GraalVM's link still work), ldso `-fno-lto` (existing logic, ported). gnu: `libmimalloc.a` standalone (MI_OVERRIDE=ON) | `libmimalloc.a` standalone |
| 36 | llvm-deps | Static zlib-ng (compat) + zstd for the gnu triple into `out/…/llvm-deps` (not shipped), needed because stage 2 builds under `--sysroot` and lld must support `--compress-debug-sections=zstd` (used by `cflags/linux-bin.txt`) | skip (host SDK zlib; zstd optional) |
| 40 | llvm-stage2 | Stage-1 clang with the gnu cfg builds `LLVM_PROJECTS=clang;lld;bolt;polly`, `LLVM_ENABLE_LIBCXX=ON`, `LLVM_STATIC_LINK_CXX_STDLIB=ON`, `LLVM_LINK_LLVM_DYLIB=OFF`, `CLANG_LINK_CLANG_DYLIB=OFF` (one static libc++ per executable, no shared libLLVM/libclang), `LLVM_ENABLE_ZLIB=FORCE_ON`, `LLVM_ENABLE_ZSTD=FORCE_ON` against stage 36, `LLVM_DEFAULT_TARGET_TRIPLE=<arch>-unknown-linux-gnu`. Installs into bundle `bin/`, `lib/` | skip |
| 50 | components | For each triple, each enabled component's `build_<name> <triple> <sysroot>/usr`, compiled with the bundle's own `<triple>-clang` (dogfoods the cfg) plus the cflags profile. Each installs `.pc` files to `<sysroot>/usr/lib/pkgconfig` | Same, single triple, installed into overlay sysroot |
| 90 | package | Copy helper CLI, cfgs, musl-gcc shims; create triple symlinks; write `share/elide-toolchain/cmake/<triple>.cmake` toolchain files; generate `manifest.json` and `sbom.cdx.json` from `versions.env`; strip binaries; `tar -cJf elide-toolchain-<ver>-<os>-<arch>.tar.xz`; write `.sha256` | same |
| 95 | verify | See §6 | same |

### 3.3a LLVM bitcode in shipped archives

Downstream projects link with `-flto=thin` end to end, so every static
archive the bundle ships carries LLVM bitcode produced by the bundle's own
LLVM major (`LLVM_MAJOR`, currently 23):

| Archive | Form |
|---|---|
| Components (stage 50) and standalone `libmimalloc.a` | ThinLTO bitcode (from `-flto=thin` in the cflags profile) |
| musl `libc.a` | fat ThinLTO objects (bitcode + native) |
| `libc++.a`, `libc++abi.a`, `libunwind.a` | fat ThinLTO objects (bitcode + native), so non-LTO links such as stage 2 still use the native code |
| compiler-rt (`libclang_rt.*`, crt objects) | **native only**: LLVM requires builtins to stay native, since LTO code generation can introduce calls into them |
| glibc's own archives | native only (built by GCC) |

Verification (§6) checks every member of every non-exempt archive.

### 3.4 Components

Same set as today, each moved into `scripts/components/<name>.sh` with the
current recipe, parameterized by triple/prefix. Default toggles (overridable
in `vars.sh`): zlib-ng (compat), zstd, brotli, snappy, lz4, aws-lc, crc32c
**on**; openssl, zlib (cloudflare), sqlite, sqlcipher, capnp, hiredis,
leveldb, propeller **off** (as today). Platform-specific adjustments:

- zlib-ng: `--64` style flags only for x86_64; works on darwin as-is.
- aws-lc: static + shared on Linux; static only on darwin.
- openssl: target `linux-x86_64` / `linux-aarch64` / `darwin64-arm64-cc` / `darwin64-x86_64-cc`.
- mimalloc headers/libs installed flat (`usr/include/mimalloc*.h`, `usr/lib/libmimalloc.a`) — no versioned `mimalloc-X.Y` dir.

### 3.5 Flags

Unchanged model, generalized per target: `cflags/cli/cflags.sh <os> <arch>`
→ `cflags.local/` overlay → `-march/-mtune` from `versions.env`
(`MARCH_AMD64=x86-64-v3`, `MTUNE_AMD64=znver3`, `MARCH_ARM64=armv8.2-a+crypto+crc`,
`MTUNE_ARM64=generic`; darwin-arm64 uses the cflags profile's `apple-m1`).
Both Linux libcs use the `linux-<arch>` profile. The toolchain layer (libc,
runtimes, LLVM, mimalloc) keeps its own tuned flags, as today.

**glibc-floor filter.** `cflags/linux.txt` carries `-Wl,-z,pack-relative-relocs`,
which makes lld emit a `GLIBC_ABI_DT_RELR` version need (glibc 2.36+). For gnu
triples, `flags.sh` removes that flag whenever `GLIBC_FLOOR` < 2.36. The same
note goes in the README for consumers that apply the cflags profile themselves.

**ISA floor of the tools.** Stage-2 tools are built with the bundle's
`-march`, so the shipped clang itself requires an x86-64-v3 (AVX2) or
armv8.2-a host — the same floor as the code it produces. Stated in README and
`manifest.json` (`host.march`).

### 3.6 versions.env

Single source of truth, sourced by every stage and by package/SBOM generation:

```
TOOLCHAIN_VERSION=2026.10.0
LLVM_VERSION=23.1.0            # must match llvm submodule tag
MUSL_VERSION=1.2.5
GLIBC_BRANCH=release/2.34/master  # glibc submodule branch; floor is GLIBC_FLOOR
LINUX_HEADERS_VERSION=6.x.y
LINUX_HEADERS_SHA256=…
MIMALLOC_VERSION=3.3.2
ZLIB_NG_VERSION=… ZSTD_VERSION=… AWS_LC_VERSION=… …
MACOS_MIN=12.0
GLIBC_FLOOR=2.34
MARCH_AMD64=… MTUNE_AMD64=… MARCH_ARM64=… MTUNE_ARM64=…
```

`versions.env` also records each submodule's pinned commit (`*_REV`).
`scripts/check-versions.sh` compares those against `git submodule status`
(works on shallow depth-1 clones, unlike `git describe --tags`); run in CI and
stage 00. Human-readable `*_VERSION` values are verified once when bumping,
with `git fetch --tags` in the bump helper.

### 3.7 Repository changes

- **Add** submodule `glibc` (`https://sourceware.org/git/glibc.git`, shallow,
  branch `release/2.34/master`).
- **Remove** submodule `musl-cross-make`, `config.mak`, `latest` symlink,
  `musl.sbom.json` (replaced by generated SBOM), countdown/`sudo` logic.
- **Update** all submodules to latest stable tags; pin tag-less trackers
  (zstd, zlib, sqlite, capnp, llvm-propeller) to latest tag where one exists,
  else current HEAD; record in `versions.env`.
- **Rewrite** README for the new model.

## 4. CI

### 4.1 Workflows

- `job.build.yml` (reusable): matrix of four hosts, each runs `./build.sh`,
  uploads the tarball + `.sha256` as a workflow artifact.

  | Bundle | Runner |
  |---|---|
  | linux-amd64 | `linux-amd64-cipool` |
  | linux-arm64 | `linux-arm64-cipool` |
  | darwin-arm64 | `macos-15` |
  | darwin-amd64 | `macos-15-intel` |

- `on.pr.yml` / `on.push.yml`: call `job.build.yml` (artifacts only, no publish).
- `on.release.yml` (new): on tag `v*` → `job.build.yml` → create GitHub
  Release, attach all bundles, `.sha256`s, SBOMs; mirror `dist/` to R2
  under `toolchain/<version>/`; attest build provenance.
- `job.action-e2e.yml` (new): after build, run the action (via its `archive`
  input, §5.1) against the just-built artifacts on all four runners and run
  `elide-toolchain doctor`.

### 4.2 Risks

- **Build time.** Linux runs LLVM twice (~2× today). Mitigations: sccache for
  stage 1/2 (re-enabled behind `USE_SCCACHE`), stage stamps for retries.
  GitHub-hosted macOS has a 6-hour job limit; macOS does a single LLVM build,
  skips stage 2, and `lldb` is dropped from `LLVM_PROJECTS` everywhere (no
  consumer uses it; it pulls in Python/SWIG and `liblldb.so`) — verify on first
  run and fall back to a self-hosted macOS runner if not.
- **Intel macOS runners** are being retired by GitHub; `macos-15-intel` is
  time-limited. When it disappears, darwin-amd64 moves to a self-hosted runner
  or is built by cross-compiling on arm64 (explicit follow-up, out of scope now).
- **linux-arm64** was previously disabled (commit `04a6ded`, "doesn't run?").
  Treat it as an explicit first-class verification target; failures there
  block release.
- **glibc 2.34 on host GCC 15** may need backported build fixes; this is the
  first spike in the implementation plan, with patches kept in `src/patches/glibc/`.

## 5. Consumption

### 5.1 GitHub Action (`action/`)

Rewritten from `install-musl-toolchain`:

```yaml
- uses: elide-dev/toolchain/action@<ref>
  with:
    version: latest          # or 2026.10.0 / v2026.10.0
    target: x86_64-unknown-linux-gnu   # optional; configures CC/CXX/… for this triple
    github-token: ${{ github.token }}  # optional; avoids API rate limits
    # testing / mirrors only:
    archive: ./dist/elide-toolchain-….tar.xz   # install from a local file (skips resolution/download)
    base-url: https://…                         # override download host
```

Behaviour:
1. Detect `os`/`arch` from `process.platform`/`process.arch` (override inputs
   `os`, `arch` exist but are rarely needed).
2. Resolve `latest` via the GitHub Releases API; fall back to R2
   `toolchain/latest.txt` on API failure.
3. Download `elide-toolchain-<ver>-<os>-<arch>.tar.xz` + `.sha256` from the
   release (fallback: R2 mirror), verify, extract, `tc.cacheDir`.
4. Export `ELIDE_TOOLCHAIN_HOME`, add `bin/` to `PATH`.
5. If `target` is set: apply `elide-toolchain env --target <t>` output via
   `core.exportVariable` (CC, CXX, AR, NM, RANLIB, CFLAGS, CXXFLAGS, LDFLAGS,
   PKG_CONFIG_LIBDIR, PKG_CONFIG_SYSROOT_DIR).
6. Outputs: `home`, `version`, `targets` (JSON array from manifest).

Built with bun as today; `dist/main.js` committed.

### 5.2 mise

```toml
[tools]
"github:elide-dev/toolchain" = "2026.10.0"
```

mise's `github:` backend selects the release asset by os/arch tokens in the
filename and puts `bin/` on PATH. Its documented tokens are
`linux|macos|windows` and `x64|arm64`; whether it also scores
`darwin`/`amd64` is **unverified**. The first implementation task checks this
against the locally installed mise 2026.9.12 with a test release; if the
default matcher fails, the README snippet uses explicit per-platform asset
patterns (`[tools."github:elide-dev/toolchain".platforms]`) rather than
renaming assets.

mise only provides `PATH`. Target-specific env comes from the helper, which
self-locates its bundle root (no `ELIDE_TOOLCHAIN_HOME` needed):
`eval "$(elide-toolchain env --target x86_64-unknown-linux-gnu)"` in shells,
Makefiles, or mise tasks. The helper CLI is the stable contract; any
mise-native `[env]` integration is a later convenience.

### 5.3 Helper CLI `bin/elide-toolchain` (POSIX sh)

```
elide-toolchain home                       # print bundle root
elide-toolchain targets                    # list triples in this bundle
elide-toolchain env [--target T] [--static] [--format sh|github|json]
elide-toolchain doctor                     # run a hello-world compile per triple
elide-toolchain version
```

`env` with no `--target` exports only `ELIDE_TOOLCHAIN_HOME` and `PATH`;
with a target it exports `CC=<triple>-clang`, `CXX=<triple>-clang++`,
`AR/NM/RANLIB=llvm-*`, `PKG_CONFIG_LIBDIR=<sysroot>/usr/lib/pkgconfig`,
`PKG_CONFIG_SYSROOT_DIR=<sysroot>`, `CMAKE_TOOLCHAIN_FILE=<root>/share/elide-toolchain/cmake/<triple>.cmake`,
and (macOS) `SDKROOT`.

**Rust.** Cross-language LTO requires linking through the bundle's clang/lld
(`-Clinker=<triple>-clang -Clink-arg=-fuse-ld=lld`) and a rustc whose LLVM
major is ≤ the bundle's. `env --target` additionally prints
`CARGO_TARGET_<TRIPLE>_LINKER` for convenience. Fat LTO objects in musl
`libc.a` keep non-LTO Rust links working regardless. The helper locates
its root from its own path (symlink-safe), so it works from the action, mise,
or a manual extract. Both the action and downstream build scripts (Bali,
Elide, Komodo) use it instead of hard-coding layout paths.

## 6. Verification (stage 95, run in CI)

For every triple in the bundle:

1. **C/C++ smoke:** compile, link and run `hello.c` and `hello.cpp`
   (iostream + exceptions + threads) with `<triple>-clang{,++}`. musl: link
   `-static`, assert `file` reports statically linked. gnu: dynamic, runs on host;
   assert PT_INTERP is the canonical loader path
   (`/lib64/ld-linux-x86-64.so.2` / `/lib/ld-linux-aarch64.so.1`).
2. **Component link:** link a test program against every enabled component
   (`-lz -lzstd -lbrotlidec -lsnappy -llz4 -lcrypto -lssl -lcrc32c -lmimalloc`).
3. **glibc floor:** for gnu outputs and every ELF in `bin/` and `lib/**/*.so`,
   `llvm-readelf -V` version *needs* contain no `GLIBC_x.y` > `GLIBC_FLOOR`
   and no `GLIBC_ABI_DT_RELR`; `NEEDED` contains no `libstdc++`/`libgcc_s`.
   Then run the gnu smoke binaries and `clang --version` inside
   `almalinux:9` and `ubuntu:22.04` containers (Linux CI only).
4. **musl LTO + fat objects:** a `libc.a` member has a `.llvm.lto` section
   whose bitcode reports the musl triple (regression guard for the existing
   LTO fix) **and** native code; a C program links against it with
   `-fno-lto`.
4a. **GCC shims:** `<arch>-linux-musl-gcc hello.c -static` links and runs.
4b. **`-Werror` clean:** `<triple>-clang -Werror -c hello.c` succeeds (cfg
    link flags don't trigger unused-argument warnings).
5. **macOS floor:** `vtool -show-build` / `otool -l` `minos` ≤ `MACOS_MIN` for
   bundle binaries and smoke outputs.
6. **Relocatability:** move the extracted bundle to a different path and
   rerun (1).
6a. **Bitcode:** every member of every shipped static archive (except compiler-rt
   and glibc's own) is LLVM bitcode or an ELF object with a `.llvm.lto` section,
   and its bitcode producer major equals `LLVM_MAJOR`.
7. **Manifest:** `manifest.json` parses, versions match `versions.env`.

`elide-toolchain doctor` runs (1) for end users.

## 7. Out of scope

- Cross-arch or cross-OS targeting (amd64↔arm64, Linux→macOS).
- `LLVMgold.so` / GNU ld LTO (non-reproducible host dependency; lld is the
  supported linker and fat LTO objects cover non-LTO linkers).
- `lldb`.
- Static linking of glibc targets.
- Windows bundles.
- Shipping libstdc++ or a GCC compiler.
- Migrating consumers (Bali, Elide, Komodo, WHIPLASH, HEATWAVE) — follow-up
  work after the first release, done per consumer.
- The GitHub repo rename itself (user action); this work only updates
  references to `elide-dev/toolchain`.
