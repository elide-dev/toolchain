# Architecture

The repository assembles one relocatable compiler distribution per host OS and
architecture. It is organized around a sequential stage pipeline in `build.sh`.
[The stage table](building.md#building) describes inputs and outputs in detail.

`versions.env` pins upstream revisions, versions, and downloaded hashes; gitlinks
pin source submodules. `vars.sh` holds overridable build choices. `cflags` and
`cflags.local` define the baseline CPU and optimization profile. `scripts/lib/`
contains shared platform, CMake, driver, allocator, and sanitizer behavior.

Linux bootstraps with a pinned LLVM distribution (or builds stage 1), constructs
musl and glibc sysroots, builds runtimes and allocator support, then builds the
shipped LLVM against the compatibility sysroot. macOS builds against Xcode's SDK
with the deployment floor. Component stages compile static libraries using these
drivers. Patches under `src/patches/` apply to staged upstream sources.

The package stage emits target drivers, CMake and pkg-config integration, metadata,
SBOM, licenses, archive, and checksum. Sanitizer variants are separate add-ons tied
to the same main bundle version. Verification compiles and runs fixture programs,
checks binary dependencies and symbol versions, and exercises sanitizers and
container compatibility. `action/` installs releases for GitHub Actions;
`src/elide-toolchain` provides the installed POSIX helper CLI.

Local stamps allow resuming long builds but do not hash every input. CI cleans
stage output and retains only checksum-verified downloads and compiler caches.
See [CI and caching](ci.md) and the [security boundaries](../SECURITY.md).
