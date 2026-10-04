# Universal Native Toolchain — Design

**Date:** 2026-10-04
**Status:** Draft — awaiting review
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
  lib/
    clang/<major>/include/…                 # clang resource dir
    clang/<major>/lib/<triple>/libclang_rt.*  # builtins, crtbegin/crtend, profile
    <triple>/libc++.a libc++abi.a libunwind.a # per-target runtime dir (Linux)
    LLVMgold.so                             # Linux, when binutils plugin-api.h is present
  include/c++/v1/                           # libc++ headers (Linux)
  sysroot/
    <arch>-unknown-linux-musl/usr/{include,lib}   # musl+mimalloc, kernel headers, components
    <arch>-unknown-linux-gnu/usr/{include,lib}    # glibc 2.34, kernel headers, components, libmimalloc.a
    <arch>-apple-darwin/usr/{include,lib}         # macOS: components overlay (no SDK)
  share/elide-toolchain/
    manifest.json                           # see §2.2
    sbom.cdx.json                           # CycloneDX 1.6, generated from versions.env
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
dynamic-capable defaults).

macOS (`arm64-apple-darwin.cfg`):

```
--target=arm64-apple-macos12.0
-isystem <CFGDIR>/../sysroot/arm64-apple-darwin/usr/include
-L<CFGDIR>/../sysroot/arm64-apple-darwin/usr/lib
-fuse-ld=lld
```

The SDK is resolved by clang from `SDKROOT`; the helper CLI sets `SDKROOT`
from `xcrun --show-sdk-path` when unset. macOS uses the system libc++.

### 2.2 manifest.json

```json
{
  "name": "elide-toolchain",
  "version": "2026.10.0",
  "revision": "<git sha>",
  "host": { "os": "linux", "arch": "amd64", "glibcFloor": "2.34" },
  "targets": [
    { "triple": "x86_64-unknown-linux-musl", "libc": "musl", "libcVersion": "1.2.5",
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
| 10 | llvm-stage1 | Host clang (or gcc) builds `clang;lld` + llvm tools into `out/…/stage1` (not shipped). `LLVM_TARGETS_TO_BUILD="X86;AArch64"` | Host Apple clang builds full `LLVM_PROJECTS` with `CMAKE_OSX_DEPLOYMENT_TARGET=12.0`, installs directly into bundle; runtimes: compiler-rt (profile only; builtins and libc++ come from the system) |
| 20 | libc-gnu | Host GCC builds glibc (`--disable-werror`, `--enable-kernel=4.18`, `--prefix=/usr`, `DESTDIR=sysroot/<gnu triple>`) with `src/patches/glibc/` applied. Strip absolute paths from `libc.so`/`libpthread.so` linker scripts so the sysroot is relocatable | skip |
| 21 | libc-musl | Stage-1 clang builds musl phase 1 (mallocng) into `sysroot/<musl triple>/usr` | skip |
| 30 | runtimes | For each Linux triple, stage-1 clang runs the LLVM runtimes build: compiler-rt builtins + crt (`COMPILER_RT_BUILD_CRT=ON`), then libunwind, libc++abi, libc++ (static, `LIBCXX_HARDENING_MODE=fast`), compiler-rt profile. musl uses `LIBCXX_HAS_MUSL_LIBC=ON`. Install into bundle `lib/` | skip (done in 10) |
| 35 | mimalloc | musl: mimalloc object (MI_OVERRIDE=OFF) + glue, then musl phase 2 with `USE_MIMALLOC=yes`, ThinLTO, ldso `-fno-lto` (existing logic, ported). gnu: `libmimalloc.a` standalone (MI_OVERRIDE=ON) | `libmimalloc.a` standalone |
| 40 | llvm-stage2 | Stage-1 clang with `x86_64-unknown-linux-gnu.cfg` builds the full `LLVM_PROJECTS` (`clang;lld;lldb;bolt;polly`), `LLVM_ENABLE_LIBCXX=ON`, static libc++/libunwind/compiler-rt, `LLVM_DEFAULT_TARGET_TRIPLE=<arch>-unknown-linux-gnu`. Installs into bundle `bin/`, `lib/` | skip |
| 50 | components | For each triple, each enabled component's `build_<name> <triple> <sysroot>/usr`, compiled with the bundle's own `<triple>-clang` (dogfoods the cfg) plus the cflags profile | Same, single triple, installed into overlay sysroot |
| 90 | package | Copy helper CLI + cfgs, create triple symlinks, generate `manifest.json` and `sbom.cdx.json` from `versions.env`, strip binaries, `tar -cJf elide-toolchain-<ver>-<os>-<arch>.tar.xz`, write `.sha256` | same |
| 95 | verify | See §6 | same |

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

### 3.6 versions.env

Single source of truth, sourced by every stage and by package/SBOM generation:

```
TOOLCHAIN_VERSION=2026.10.0
LLVM_VERSION=23.1.0            # must match llvm submodule tag
MUSL_VERSION=1.2.5
GLIBC_VERSION=2.34             # floor; source = glibc submodule @ release/2.34/master
LINUX_HEADERS_VERSION=6.x.y
LINUX_HEADERS_SHA256=…
MIMALLOC_VERSION=3.3.2
ZLIB_NG_VERSION=… ZSTD_VERSION=… AWS_LC_VERSION=… …
MACOS_MIN=12.0
GLIBC_FLOOR=2.34
MARCH_AMD64=… MTUNE_AMD64=… MARCH_ARM64=… MTUNE_ARM64=…
```

A `scripts/check-versions.sh` asserts each `*_VERSION` matches the
corresponding submodule's `git describe --tags`; run in CI and stage 00.

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
- `job.action-e2e.yml` (new): after build, run the action against the just-built
  artifacts on all four runners and compile a hello-world per triple.

### 4.2 Risks

- **Build time.** Linux runs LLVM twice (~2× today). Mitigations: sccache for
  stage 1/2 (re-enabled behind `USE_SCCACHE`), stage stamps for retries.
  GitHub-hosted macOS has a 6-hour job limit; macOS does a single LLVM build
  and skips stage 2, which should fit — verify on first run and fall back to
  a self-hosted macOS runner if not.
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
filename (`linux`/`darwin`, `amd64`/`arm64`) and puts `bin/` on PATH. Asset
naming is chosen to satisfy its matcher; the plan includes verifying this
against mise 2026.9+ and, if the matcher cannot resolve `.tar.xz` or the
naming, adding explicit `asset_pattern`/per-platform config to the README
snippet.

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
`PKG_CONFIG_SYSROOT_DIR=<sysroot>`, and (macOS) `SDKROOT`. The helper locates
its root from its own path (symlink-safe), so it works from the action, mise,
or a manual extract. Both the action and downstream build scripts (Bali,
Elide, Komodo) use it instead of hard-coding layout paths.

## 6. Verification (stage 95, run in CI)

For every triple in the bundle:

1. **C/C++ smoke:** compile, link and run `hello.c` and `hello.cpp`
   (iostream + exceptions + threads) with `<triple>-clang{,++}`. musl: link
   `-static`, assert `file` reports statically linked. gnu: dynamic, runs on host.
2. **Component link:** link a test program against every enabled component
   (`-lz -lzstd -lbrotlidec -lsnappy -llz4 -lcrypto -lssl -lcrc32c -lmimalloc`).
3. **glibc floor:** for gnu outputs and for every ELF in `bin/` and `lib/*.so`,
   `llvm-objdump -T` max `GLIBC_x.y` ≤ `GLIBC_FLOOR`; fail otherwise.
4. **musl LTO triple:** `llvm-bcanalyzer`/`llvm-dis` on a `libc.a` member
   reports the musl triple (regression guard for the existing LTO fix).
5. **macOS floor:** `vtool -show-build` / `otool -l` `minos` ≤ `MACOS_MIN` for
   bundle binaries and smoke outputs.
6. **Relocatability:** move the extracted bundle to a different path and
   rerun (1).
7. **Manifest:** `manifest.json` parses, versions match `versions.env`.

`elide-toolchain doctor` runs (1) for end users.

## 7. Out of scope

- Cross-arch or cross-OS targeting (amd64↔arm64, Linux→macOS).
- Windows bundles.
- Shipping libstdc++ or a GCC compiler.
- Migrating consumers (Bali, Elide, Komodo, WHIPLASH, HEATWAVE) — follow-up
  work after the first release, done per consumer.
- The GitHub repo rename itself (user action); this work only updates
  references to `elide-dev/toolchain`.
