# Elide Toolchain

[![CI](https://github.com/elide-dev/toolchain/actions/workflows/on.push.yml/badge.svg?branch=main)](https://github.com/elide-dev/toolchain/actions/workflows/on.push.yml)
[![Fuzzing](https://github.com/elide-dev/toolchain/actions/workflows/fuzzing.yml/badge.svg?branch=main)](https://github.com/elide-dev/toolchain/actions/workflows/fuzzing.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/elide-dev/toolchain/badge)](https://scorecard.dev/viewer/?uri=github.com/elide-dev/toolchain)
[![OpenSSF Best Practices Gold](https://www.bestpractices.dev/projects/16468/badge)](https://www.bestpractices.dev/en/projects/16468)
[![Sigstore](https://img.shields.io/badge/Sigstore-signed_provenance-blue?logo=sigstore)](docs/releases.md#consumer-verification)
[![Release](https://img.shields.io/github/v/release/elide-dev/toolchain)](https://github.com/elide-dev/toolchain/releases/latest)
[![License: Apache-2.0 OR MIT](https://img.shields.io/badge/license-Apache--2.0%20OR%20MIT-blue)](LICENSE)
[![Discord](https://img.shields.io/discord/1119121740161884252?logo=discord&logoColor=white&label=Discord)](https://elide.dev/discord)

A portable LLVM 23 toolchain with Clang, clangd, LLD, libc++, sanitizer runtimes,
and static native libraries built with a consistent flags profile. Linux bundles
include musl and glibc sysroots; macOS bundles use the system SDK. Use it for C,
C++, Rust cross-language LTO, and GraalVM Native Image builds.

[Install a release](https://github.com/elide-dev/toolchain/releases) ·
[Toolchain reference](docs/reference.md) · [Build from source](docs/building.md) ·
[Contribute](CONTRIBUTING.md) · [Security](SECURITY.md)

## Choose a bundle

| Host | Targets | Requirements |
| --- | --- | --- |
| Linux amd64 | `x86_64-unknown-linux-gnu`, `x86_64-unknown-linux-musl` | x86-64-v3 (AVX2), glibc 2.17+ host |
| Linux arm64 | `aarch64-unknown-linux-gnu`, `aarch64-unknown-linux-musl` | ARMv8.2-A + crypto, CRC, dotprod; glibc 2.17+ host |
| macOS arm64 | `arm64-apple-darwin` | macOS 12+, Xcode Command Line Tools |

Each bundle targets its own OS and architecture. Choose **gnu** for normal Linux
applications and **musl** for fully static Linux executables. macOS amd64 and
cross-OS compilation are not supported. The compatibility floor is not a promise
that an end-of-life operating system receives upstream security updates.

## Quick start

This example installs the Linux amd64 bundle. Select the matching asset for your
host from [Releases](https://github.com/elide-dev/toolchain/releases). Pin a version
in production; `2026.11.5` is an example, not a moving “latest” alias.

```sh
version=2026.11.5
asset="elide-toolchain-$version-linux-amd64.tar.xz"
base="https://github.com/elide-dev/toolchain/releases/download/v$version"
curl --fail --location --remote-name "$base/$asset"
curl --fail --location --remote-name "$base/$asset.sha256"
shasum -a 256 -c "$asset.sha256"
tar -xJf "$asset"
export ELIDE_TOOLCHAIN_HOME="$PWD/elide-toolchain"
export PATH="$ELIDE_TOOLCHAIN_HOME/bin:$PATH"
elide-toolchain doctor
printf '#include <stdio.h>
int main(void) { puts("Hello, Elide!"); }
' > hello.c
x86_64-unknown-linux-gnu-clang hello.c -o hello
./hello
```

For a fully static executable, use `x86_64-unknown-linux-musl-clang -static`.
On arm64, substitute the corresponding target from the table. On macOS use
`arm64-apple-darwin-clang`. See [release verification](docs/releases.md) for signed
provenance: a checksum alone does not authenticate the publisher.

To uninstall a manual installation, remove its extracted directory and remove
its `bin` entry and exported variables from your shell configuration. No system
compiler is replaced.

### GitHub Actions

```yaml
- uses: elide-dev/toolchain/action@9087560dc52456a9ea1daf3708416295a9f3acc4 # replace with a reviewed full commit SHA
  with:
    version: '2026.11.5'
    target: x86_64-unknown-linux-gnu
```

The action adds tools to `PATH`, exports `ELIDE_TOOLCHAIN_HOME`, and sets `CC`,
`CXX`, and build-system variables when `target` is provided. Pin the action commit
and the bundle version separately. See [all inputs and outputs](action/action.yml).

### mise

```toml
[tools]
"github:elide-dev/toolchain" = "2026.11.5"
```

mise provides `PATH`; select a target with:

```sh
eval "$(elide-toolchain env --target x86_64-unknown-linux-gnu)"
```

## Integrate with your build

| Task | Where to start |
| --- | --- |
| CMake, pkg-config, Rust, Native Image | [Usage and link rules](docs/reference.md#use) |
| ASan, TSan, MSan and sanitizer add-ons | [Sanitizer support and limits](docs/reference.md#sanitizers) |
| ThinLTO, profile-guided optimization, BOLT, Propeller | [Optimization reference](docs/reference.md#profile-guided-layout-deduplication-and-memory-hints) |
| Compiler and linker flags | [Flags reference](docs/reference.md#flags) |
| Moving from musl-toolchain | [Migration guide](docs/reference.md#migrating-from-musl-toolchain) |
| Build stages, dependencies, caching and tests | [Building](docs/building.md), [CI](docs/ci.md) |

Use the bundle's target-prefixed Clang drivers to select its sysroot and libc++.
Do not add `-lstdc++`. Linux libraries contain native code and LLVM bitcode;
macOS libraries require the bundled LLVM linker. Match Rust's LLVM version to
these link requirements; see the reference and the bundled `rustversion` pin.

## Help and development

Report reproducible bugs through [GitHub Issues](https://github.com/elide-dev/toolchain/issues).
Include the bundle version, host OS/CPU, target, command, and a reduced example.
For install failures, include `elide-toolchain doctor` output if available. Report
suspected vulnerabilities privately using [SECURITY.md](SECURITY.md).

New contributors can run fast tests without building LLVM; start with
[CONTRIBUTING.md](CONTRIBUTING.md), including the
[contributor agreement](CONTRIBUTOR_AGREEMENT.md) and [DCO](DCO). [AGENTS.md](AGENTS.md) describes implementation
constraints. See [architecture](docs/architecture.md), [roadmap](docs/roadmap.md),
and [OpenSSF evidence and remaining work](docs/openssf.md).

First-party code is licensed under **Apache-2.0 OR MIT**, at your option:
[Apache](LICENSE-APACHE), [MIT](LICENSE-MIT). Bundled components retain their
[third-party licenses](THIRD_PARTY.md). Follow our [code of conduct](CODE_OF_CONDUCT.md).
