# Sanitizer feasibility spikes (throwaway)

**Date:** 2026-10-05
**Feeds:** `docs/superpowers/specs/2026-10-05-sanitizer-variants-design.md`,
`docs/superpowers/plans/2026-10-05-sanitizer-variants.md`

Everything here is **throwaway**. The spike scripts lived under the worktree's git-ignored
`out/spike/` and are not committed; the commands that matter are reproduced below.

## Setup

- Host: AMD Ryzen 9 9950X3D2 (32 threads), 92 GiB RAM, WSL2, kernel `6.6.114.1-microsoft-standard-WSL2+`.
- Input: the complete linux-amd64 build at `/home/sam/workspace/toolchains/native/out/linux-amd64/`,
  used **read-only**. The bundle was copied (`cp -a`, 3.0 GiB) to `out/spike/elide-toolchain/`
  and every experiment ran against that copy: its stage-2 clang 23.1.2, its two sysroots, and
  its libc++.
- LLVM sources: `/home/sam/workspace/toolchains/native/llvm` (read-only, `LLVM_REV=85ac560…`).
- Component sources (zlib-ng, zstd, brotli, snappy, lz4, crc32c, aws-lc, mimalloc, cflags) were
  rsync'ed without VCS metadata into `out/spike/root/` together with this repo's `scripts/`,
  so the repo's own component recipes could run unchanged. `GIT_CEILING_DIRECTORIES` stops
  `stage_source` from discovering the enclosing worktree.
- Parallelism: `ninja -j24` (the host was shared with other work).
- Bare compiler flags everywhere below: `--no-default-config -march=x86-64-v3 -mtune=znver3`.

## Spike A: standalone compiler-rt sanitizer build per triple

Runtimes build with the bundle's clang, bare `--target/--sysroot` (like stage 30), installed
libc++ supplying C++ headers and linking:

```bash
cmake -S llvm/runtimes -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_{C,CXX,ASM}_COMPILER="$TC/bin/clang{,++,}" -DCMAKE_{C,CXX,ASM}_COMPILER_TARGET="$t" \
  -DCMAKE_SYSROOT="$TC/sysroot/$t" -DCMAKE_AR/RANLIB/NM=llvm-* \
  -DCMAKE_C_FLAGS="$af" -DCMAKE_CXX_FLAGS="$af -stdlib=libc++" -DCMAKE_ASM_FLAGS="$af" \
  -DCMAKE_{EXE,SHARED,MODULE}_LINKER_FLAGS="-rtlib=compiler-rt -unwindlib=libunwind -stdlib=libc++ -fuse-ld=lld" \
  -DLLVM_ENABLE_RUNTIMES=compiler-rt -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
  -DCOMPILER_RT_INSTALL_PATH=lib/clang/23 -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
  -DCOMPILER_RT_BUILD_BUILTINS=OFF -DCOMPILER_RT_BUILD_CRT=OFF -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_SANITIZERS=ON -DCOMPILER_RT_BUILD_MEMPROF=ON -DCOMPILER_RT_BUILD_LIBFUZZER=ON \
  -DCOMPILER_RT_BUILD_GWP_ASAN=ON -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_ORC=OFF \
  -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF -DSANITIZER_CXX_ABI=libc++ -DSANITIZER_TEST_CXX=libc++ \
  -DCOMPILER_RT_INCLUDE_TESTS=OFF
ninja -C "$b" -k 0
```

| Triple | Result | Wall time (-j24) |
|---|---|---|
| `x86_64-unknown-linux-gnu` | **all 735 steps built**: asan (+`.so`, `_static`, `-preinit`, `_cxx`), lsan, tsan (+`.so`), msan, ubsan_standalone (+`.so`), ubsan_minimal (+`.so`), hwasan (+aliases), dfsan, cfi, safestack, scudo_standalone, gwp_asan, memprof, nsan, rtsan, tysan, libFuzzer | 29 s (216 CPU-s) |
| `x86_64-unknown-linux-musl` | **every sanitizer runtime built**; only **libFuzzer failed** (26 errors, all in its private libc++ copy: `__locale: error: unknown rune table for this platform` because that inner libc++ build is not told `LIBCXX_HAS_MUSL_LIBC=ON`) | 25 s |

CMake evidence (`compiler-rt/cmake/config-ix.cmake`, LLVM 23.1.2): sanitizer gating is by
`OS_NAME` only. musl is `Linux` to CMake, so the build-time matrix cannot tell musl and glibc
apart: `COMPILER_RT_HAS_MSAN` = `Linux|FreeBSD|NetBSD` (line 836), `_TSAN` = `Linux|Darwin|FreeBSD|NetBSD`
(872), `_HWASAN` = `Linux|Android|Fuchsia` (800), `_LSAN` = `Android|Darwin|Linux|NetBSD|Fuchsia` (829),
`_UBSAN` includes Darwin and Linux (890), `_ASAN` = any OS with sanitizer_common (793). Static
runtimes exist only for `Linux|FreeBSD|Windows|NetBSD|SunOS` (`COMPILER_RT_ASAN_HAS_STATIC_RUNTIME`,
813; `_TSAN_HAS_STATIC_RUNTIME`, 883), so Darwin sanitizers are dylib-only. Arch lists
(`cmake/Modules/AllSupportedArchDefs.cmake`): x86_64 and arm64 are in the ASan, LSan, TSan, MSan,
HWASan, UBSan and libFuzzer lists; NSan and MemProf are x86_64-only. The clang driver
(`clang/lib/Driver/ToolChains/Linux.cpp:969`) offers MSan, TSan, HWASan and LSan on x86_64 and
aarch64 Linux with no musl exception. Darwin (`Darwin.cpp:4044`) offers Address, Leak, Thread
(x86_64/arm64), UBSan, Fuzzer and Realtime, but not Memory.

**The unmodified bundle cannot link any sanitizer today.** `-fsanitize=address` compiles, then
fails at link: `cannot open …/lib/clang/23/lib/x86_64-unknown-linux-gnu/libclang_rt.asan_static.a`.
The resource dir also lacks `include/sanitizer/*.h` and `share/*_ignorelist.txt`. The spike
installed those from the gnu build.

## Spike B: trigger programs and false-positive checks (x86_64)

Fixtures (all tiny): heap overflow (`asan.c`), unsynchronised `g++` from two threads (`tsan.c`),
`INT_MAX + argc` (`ubsan.c`), a dropped `malloc` (`lsan.c`), a branch on an uninitialised local
(`msan.c`), an out-of-bounds write (`hwasan.c`), `clean.cpp` (vector<string> plus concatenation),
`exc.cpp` (throw and catch, then an uninitialised read), and `workload.c`, which round-trips 64
KiB through zlib, zstd, lz4, brotli and snappy, hashes it with aws-lc SHA-256 and crc32c, and
branches on every output. Front-end: `bin/<triple>-clang` (the shipped cfg) plus `-fsanitize=…`.
musl dynamic links used `-Wl,--dynamic-linker=<sysroot>/lib/ld-musl-x86_64.so.1 -Wl,-rpath,<sysroot>/usr/lib`
because the host has no musl loader.

### gnu (`x86_64-unknown-linux-gnu`), main-bundle libc++ and components

| Case | Result |
|---|---|
| asan / tsan / ubsan / ubsan-minimal / lsan / asan-as-leak-checker / msan triggers | **all trip** (`heap-buffer-overflow`, `data race`, `signed integer overflow`, `add-overflow`, `detected memory leaks`, `use-of-uninitialized-value`) |
| hwasan trigger | builds; at run time: `FATAL: HWAddressSanitizer requires a kernel with tagged address ABI` (x86_64 needs LAM; this kernel lacks it) |
| asan / tsan / ubsan + `clean.cpp` (uninstrumented libc++) | clean |
| asan / tsan / ubsan + `workload.c` with every component (uninstrumented) | clean |
| asan + `-flto=thin` (trigger, and workload over bitcode components plus fat-LTO libc++) | trips / clean |
| **msan + `clean.cpp`** (uninstrumented libc++) | **false positive**: `use-of-uninitialized-value` |
| **msan + `workload.c`** (uninstrumented components) | **false positive** |
| asan / tsan / msan with `-static` | link fails: `undefined symbol: _DYNAMIC` |
| ubsan and ubsan-minimal with `-static` | trip |
| asan + `-lmimalloc` (shipped `MI_OVERRIDE=ON` archive), no `mi_*` call | trips (mimalloc's object is never pulled in) |
| **asan + `-lmimalloc` with an `mi_malloc` call** | **SIGSEGV** at startup |
| **tsan + `-lmimalloc` with an `mi_malloc` call** | **SIGSEGV** in `__interceptor_pthread_mutex_lock` ← `mi_lock_acquire` ← `mi_process_init` |

### musl (`x86_64-unknown-linux-musl`)

| Case | Result |
|---|---|
| Static (`-static`) ubsan / ubsan-minimal, on the **shipped** musl (mimalloc inside `libc.a`) | trip |
| asan / tsan / msan, `-static` | link fails (`undefined hidden symbol: _DYNAMIC`) |
| **Any dynamically linked musl executable on the shipped sysroot, sanitized or not** (`int main` plus printf) | **SIGSEGV before main**: `_mi_thread_init_with_heap ← mi_process_init_once ← _mi_auto_process_init ← do_init_fini` inside `libc.so` (the dynamic loader). **Pre-existing bundle bug, independent of sanitizers.** `check_components_shared` builds musl `.so` files but never runs a dynamic musl executable, so verification misses it |
| Rebuilt musl with `--with-malloc=mallocng`, no LTO, in a copy of the sysroot (`sysroot/x86_64-unknown-linux-musl-san`): asan, tsan, ubsan, ubsan-minimal, lsan, asan-leak and msan triggers | **all trip** |
| … same sysroot: asan / tsan / ubsan with `clean.cpp` and with `workload.c` (incl. `-flto=thin`) | clean |
| … same sysroot: msan with `clean.cpp` / `workload.c` | false positive (uninstrumented libc++/components, as on gnu) |

musl TSan and MSan passing a trivial case does **not** make them supported: upstream does not test
musl for either. See the spec for the support decision.

## Spike C: instrumented libc++ / libc++abi (sizes and correctness)

Same options as stage 30's cxx pass (static, fat ThinLTO, `LIBCXX_HARDENING_MODE=fast`,
libc++abi merged into libc++.a), plus `-DLLVM_USE_SANITIZER=<MemoryWithOrigins|Address|Thread>`.
Build: 5–14 s wall each (-j24).

Findings:

1. **An instrumented unwinder breaks MSan.** With libunwind built under `LLVM_USE_SANITIZER=MemoryWithOrigins`
   (the runtimes build instruments every runtime, including libunwind, which has no opt-out of
   its own), both a plain C program, which links `-lunwind` because of `-unwindlib=libunwind`,
   and a throwing C++ program die with `MemorySanitizer: stack-overflow … nested bug in the same thread`.
   Removing `libunwind.a` from the variant dir fixed C but not C++, because
   `LIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=ON` merges the instrumented unwinder into
   libc++abi.a. Passing `-fno-sanitize=all` via `LIBUNWIND_ADDITIONAL_COMPILE_FLAGS` *also*
   de-instrumented libc++abi: the flags leak into libc++abi's static objects, leaving 0 `__msan`
   refs. **Working recipe:** keep `LIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=OFF` in variants, do
   not ship the variant `libunwind.a`, and `-lunwind` resolves to the main (uninstrumented) one.
   Then libc++.a has 1912 `__msan` refs and libc++abi.a 504, and `exc.cpp` reports the real
   uninitialised read at `exc.cpp:4`.
2. `__config_site`: identical to the main one for MSan and TSan. **ASan differs**:
   `_LIBCPP_INSTRUMENTED_WITH_ASAN 1` (main: `0`). An ASan variant therefore needs its own
   `__config_site`, put first on the include path via `-isystem include/<T>/asan/c++/v1`.
3. Vector container-overflow (`container.cpp`) is reported **both** with the ASan variant and
   with plain `-fsanitize=address` over the main libc++: the vector annotations live in headers.
   The variant matters for annotations compiled into the library, e.g. `std::string` (not tested,
   **uncertain**).

| Payload (x86_64-gnu) | raw | xz -9 |
|---|---|---|
| msan libc++.a + libc++abi.a | 27.3 MiB | 5.8 MiB |
| asan libc++.a + libc++abi.a | 27.7 MiB | 4.9 MiB |
| tsan libc++.a + libc++abi.a | 19.3 MiB | 3.1 MiB |
| (main bundle's `lib/x86_64-unknown-linux-gnu/`, for comparison) | 9.4 MiB | n/a |

## Spike D: instrumented components through the repo's own recipes

`scripts/lib/env.sh` sourced with `ROOT_DIR=out/spike/root`, then `target_cflags` wrapped to
prepend `--config=<triple>-<san>.cfg`, then `build_<component>` called for the seven default-on
components into a staging prefix. aws-lc was static-only, plus `-DOPENSSL_NO_ASM=1` for MSan
(uninstrumented assembly writes would look uninitialised).

| Variant | Build (all 7) | raw | xz -9 | Instrumented? |
|---|---|---|---|---|
| msan | 43 s | 51.1 MiB | 21.6 MiB | every archive references `__msan_*` (libz 28 … libcrypto 6807 refs) |
| asan | 35 s | 49.6 MiB | 18.6 MiB | yes |
| tsan | 34 s | 33.7 MiB | 12.5 MiB | yes |

With instrumented libc++ and components behind a layered cfg, `run-variant.sh` per sanitizer
(fixtures `clean.cpp`, `workload.c`, each with and without `-flto=thin`, plus the trigger) gave:

```
              cxx-clean  cxx-clean-thinlto  components  components-thinlto  trigger
msan          clean      clean              clean       clean               trips
asan          clean      clean              clean       clean               trips
tsan          clean      clean              clean       clean               trips
```

**All variant payloads together (x86_64-gnu, asan+tsan+msan libc++ and components): 208.7 MiB raw, 63.6 MiB xz.**
For scale, the main linux-amd64 bundle is 525.7 MiB xz.

## Spike E: mimalloc under sanitizers

| mimalloc build | asan | tsan | msan |
|---|---|---|---|
| shipped `libmimalloc.a` (`MI_OVERRIDE=ON`) + `mi_*` call | SIGSEGV | SIGSEGV | n/a |
| `MI_OVERRIDE=OFF`, built with the variant cfg | malloc overflow trips; `mi_malloc` overflow **not seen** | clean | **false positive** in `_mi_strnstr ← _mi_prim_mem_init` (mimalloc reads `/proc` through raw syscalls MSan cannot see) |
| `MI_OVERRIDE=OFF MI_TRACK=ASAN` | `mi_malloc` overflow still **not seen** (cause not investigated, **uncertain**) | n/a | n/a |
| **forwarding shim** (`mi_*` → `malloc`/`calloc`/`realloc`/`aligned_alloc`/`free`, ThinLTO, built with the variant cfg) | **both overflows trip** | clean | clean |

## Spike F: selecting a variant from the front-ends

| Mechanism | Result |
|---|---|
| symlink `bin/x86_64-unknown-linux-gnu-msan-clang → clang` + `x86_64-unknown-linux-gnu-msan.cfg` | `error: version '-msan' in target triple 'x86_64-unknown-linux-gnu-msan' is invalid` |
| symlink `bin/x86_64-unknown-linux-gnu-clang-msan` | suffix ignored; loads only `x86_64-unknown-linux-gnu.cfg` |
| `<triple>-clang --config=<file>` | **both** cfgs load: the default `<triple>.cfg` first, then the explicit one, so the explicit file's `--sysroot` wins. A name with no directory part is searched in `bin/`; an absolute path works from any cwd |
| `@other.cfg` inside a cfg | works; the nested `<CFGDIR>` is the nested file's directory |
| cfg `-L<CFGDIR>/../lib/<T>/<san>` | appears before the driver's own `-L…/lib/<T>`, so the variant `libc++.a` wins |
| POSIX-sh wrapper `bin/<T>-<san>-clang{,++}` → `exec <T>-clang{,++} --config=<abs>/share/elide-toolchain/sanitizers/<T>-<san>.cfg "$@"` | works; keeps `bin/*.cfg` (what `elide-toolchain targets` lists) clean |

**CMake finds libraries by absolute path inside `CMAKE_SYSROOT`**, so `find_package(ZLIB)` returns
`sysroot/<T>/usr/lib/libz.a` and bypasses any `-L` override. Fix prototyped: a **symlink-farm
variant sysroot** `sysroot/<T>+<san>/`. Every entry is a relative symlink into `sysroot/<T>/`
except the instrumented archives, which are real files. The variant cfg passes `--sysroot` to it,
and a variant toolchain file `share/elide-toolchain/cmake/<T>-<san>.cmake` points the compilers
at the wrappers and `CMAKE_SYSROOT` at the farm. Result for all three sanitizers:
`Found ZLIB: …/sysroot/x86_64-unknown-linux-gnu+<san>/usr/lib/libz.a`, and the CMake-built
workload ran clean.

## Spike G: Rust interop

`rustc +nightly-2026-09-29` (1.101.0-nightly, **LLVM 23.1.1**), C side compiled by the bundle,
linked by the bundle's clang + lld:

| Case | clean run | trip |
|---|---|---|
| `-Zsanitizer=address` (rustc's own runtime), C with `-fsanitize=address` | rc 0 | `heap-buffer-overflow` |
| `-Zsanitizer=address -Zexternal-clangrt -Clinker=<T>-asan-clang` (clang's runtime) | rc 0 | trips |
| both of the above plus `-Clinker-plugin-lto` and C `-flto=thin` (cross-language ThinLTO) | rc 0 | trips |
| rustc runtime **and** `-Clink-arg=-fsanitize=address` | **link fails**: `duplicate symbol: __asan::AsanMapUnmapCallback::OnMap…` | n/a |

`--print link-args` confirms `-Zexternal-clangrt` drops `librustc-nightly_rt.asan.a`, and the
last `-Clinker` wins. Rust MSan/TSan (`-Zbuild-std` required) was **not tested**.

## Spike H: shared runtime (JNI shape) and glibc floor

An ASan-instrumented `.so` built with `-shared-libsan`, `dlopen`ed by an uninstrumented host:
without `LD_PRELOAD` it fails (`libclang_rt.asan.so: cannot open shared object file`); with
`LD_PRELOAD=<bundle>/lib/clang/23/lib/<T>/libclang_rt.asan.so ASAN_OPTIONS=detect_leaks=0` it
reports `heap-buffer-overflow`. Every sanitizer `.so` from spike A needs at most `GLIBC_2.34`
(ubsan_minimal: `GLIBC_2.2`), with `NEEDED` ⊆ {libc.so.6, libm.so.6, ld-linux-x86-64.so.2}:
no libstdc++ and no libgcc_s.

## Runtime-set sizes (x86_64-gnu)

| Set | raw | xz -9 |
|---|---|---|
| asan, lsan, tsan, ubsan_standalone, ubsan_minimal, msan (static + `.so` + `.syms`) | 24.3 MiB | 2.1 MiB |
| … + libFuzzer | 31.2 MiB | 2.7 MiB |
| everything spike A built | 66.6 MiB | 4.5 MiB |

## Not verified (uncertain)

- **aarch64** (no arm64 host or arm64 build here): runtime builds, HWASan (needs the kernel's
  tagged-address ABI; `PR_SET_TAGGED_ADDR_CTRL`, Linux ≥ 5.4), TSan VMA layouts.
- **darwin**: compiler-rt sanitizer dylibs with `SANITIZER_MIN_OSX_VERSION=12.0`, ad-hoc signing,
  `minos` of the dylibs.
- Rust `-Zsanitizer=memory|thread` with `-Zbuild-std`; GraalVM native-image (not attempted).
- Wrappers and farm sysroots under a bundle path containing spaces; aws-lc's CMake package files
  resolving through the farm's `usr/lib/cmake` symlink.
- Why `MI_TRACK=ASAN` did not expose `mi_malloc` overflows.
- Root cause of the dynamic-musl startup crash (mimalloc init inside `libc.so`).

## Addendum: repeated `--config`

`<T>-clang --config=a.cfg --config=b.cfg` loads `a.cfg`, `b.cfg` **and** the default `<T>.cfg`
(all three appear under `Configuration file:` in `-###`, and both layers' flags take effect).
So a wrapper can stack a runtime-only sanitizer layer and an optional overlay layer.

## Addendum: final layout re-test

The bundle copy was then cut down to exactly the proposed layout: `lib/<G>/<san>/` holds only
`libc++{,abi,experimental}.a`, components and the mimalloc shim exist only as real files in
`sysroot/<G>+<san>/usr/lib`, and the farm drops `libcrypto.so`/`libssl.so`. `run-variant.sh`
for msan, asan and tsan (cxx-clean, cxx-clean-thinlto, components, components-thinlto, trigger)
was all PASS again, and the MSan workload's `NEEDED` is only libc/libm/libresolv.
**Negative control:** with the `libcrypto.so` symlink restored in the msan farm, lld links the
uninstrumented shared aws-lc and the workload reports `use-of-uninitialized-value … in
MemcmpInterceptorCommon`. Dropping replaced `.so` symlinks is therefore mandatory.
