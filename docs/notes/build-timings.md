# Build timings

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
