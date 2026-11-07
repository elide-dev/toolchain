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
the new cache entries; subsequent builds can reuse them.
CI now prints verbose ccache statistics so bypass reasons are visible.

The macOS job in [the cancelled 2026.11.3 release run](https://github.com/elide-dev/toolchain/actions/runs/42304760774)
completed before cancellation for issue #18. Cacheable calls rose from 601/4949
(12.14%) to 4915/4944 (99.41%). This cold fill had 4799 misses; LLVM took 576 s
versus 460 s in the baseline, so it is evidence of restored caching, not yet a
warm-build speed measurement. All macOS bundle checks passed.

The macOS job in [the 2026.11.4 release run](https://github.com/elide-dev/toolchain/actions/runs/42309093316)
then demonstrated warm-cache savings on the same 16-CPU runner class:

| Stage | 2026.11.2 | 2026.11.4 |
|---|---:|---:|
| LLVM | 460 s | 74 s |
| Components | 30 s | 38 s |
| Package | 84 s | 82 s |
| Verify | 60 s | 60 s |

The LLVM stage was 84% faster (6.2x); all toolchain stages together took about
4m19s. ccache reported 4915/4944 cacheable calls (99.41%), with 4510 hits
(91.76% of cacheable calls) and 405 misses. Bundle verification passed with zero
failures. These are observed CI timings, not a controlled benchmark; cold-cache
and Linux builds have different costs.

The same release's Linux builds were mostly cache fills:

| Measurement | linux-amd64 | linux-arm64 |
|---|---:|---:|
| Cacheable calls | 9478/9593 (98.80%) | 7751/7800 (99.37%) |
| Hits / cacheable calls | 2495 (26.32%) | 1980 (25.55%) |
| Misses | 6983 | 5771 |
| Shipped LLVM | 1777 s | 1313 s |
| Components | 348 s | 362 s |
| Sanitizer add-ons | 503 s | — |
| Package | 452 s | 231 s |
| Verify | 294 s | 179 s |

These runs do not demonstrate a Linux speedup: shipped LLVM took longer than
the baseline on both architectures. Both glibc and musl distributed ThinLTO and
SQLite authorizer checks passed, including authorizer checks for all three
amd64 sanitizer add-ons; verification reported zero failures on both platforms.

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
