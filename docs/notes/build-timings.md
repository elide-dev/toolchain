# Build timings

## 2026.11.2 release CI baseline and cache fix

[Release run 42283324390](https://github.com/elide-dev/toolchain/actions/runs/42283324390)
took 53m56s end to end. Linux runners reported 8 CPUs; amd64 had 50 GiB
available memory and arm64 60 GiB. macOS reported 16 CPUs and 128 GiB.

| Stage | linux-amd64 | linux-arm64 | darwin-arm64 |
|---|---:|---:|---:|
| Shipped LLVM (40 on Linux, 10 on macOS) | 1076 s | 736 s | 460 s |
| Components | 359 s | 345 s | 30 s |
| Sanitizer add-ons | 539 s | — | — |
| Package | 480 s | 222 s | 84 s |
| Verify | 290 s | 168 s | 60 s |

The LLVM log reports precompiled headers enabled. Of all ccache calls,
4538/9598 (amd64), 4472/7805 (arm64), and 4348/4949 (macOS) were uncacheable.
A local Clang/ccache 4.11.2 probe reproduced `Could not use precompiled header`
with LLVM's `-Xclang -fno-pch-timestamp` and default strict cache settings.
Compiling the same source without PCH gave a cache miss followed by a direct hit.

Starting with 2026.11.3, LLVM builds with a compiler launcher set
`CMAKE_DISABLE_PRECOMPILE_HEADERS=ON`; uncached builds retain upstream defaults.
This avoids relaxing ccache's header/macro validation. The first build populates
the new cache entries; full-build savings need a subsequent warm-cache run.
CI now prints verbose ccache statistics so bypass reasons are visible.

The macOS job in [the cancelled 2026.11.3 release run](https://github.com/elide-dev/toolchain/actions/runs/42304760774)
completed before cancellation for issue #18. Cacheable calls rose from 601/4949
(12.14%) to 4915/4944 (99.41%). This cold fill had 4799 misses; LLVM took 576 s
versus 460 s in the baseline, so it is evidence of restored caching, not yet a
warm-build speed measurement. All macOS bundle checks passed.

## Original local baseline

Full clean build of the linux-amd64 bundle: `REQUIRE_CONTAINER_CHECKS=yes ./build.sh --clean`
(2026-10-04, from timestamps in `out/full-build.log`; sccache off).

Host: AMD Ryzen 9 9950X3D2 16-Core Processor (32 threads), 92 GiB RAM, WSL2 (Linux 6.6.114.1-microsoft-standard-WSL2+).

| Stage | Wall time |
|---|---|
| 00-sources | 16 s |
| 10-llvm-stage1 | 8 m 31 s |
| 20-libc-gnu | 53 s |
| 21-libc-musl | 2 s |
| 30-runtimes | 2 m 31 s |
| 35-mimalloc | 9 s |
| 36-llvm-deps | 11 s |
| 40-llvm-stage2 | 5 m 55 s |
| 50-components | 1 m 51 s |
| 90-package | 1 m 52 s |
| 95-verify | 21 s |
| **Total** | **22 m 32 s** (user CPU 349 m 31 s) |

The run ended with `verification: 0 failure(s)`, including the almalinux:9 and ubuntu:22.04 container checks.
All `tests/stages/*.check.sh` passed with 0 failures. Linux CI runners with fewer cores will be slower, scaling roughly with core count.
