# glibc 2.34 with host GCC 15 (spike)

Result: glibc `release/2.34/master` builds cleanly with host GCC 15.2 using stock
flags. **No source patches are needed** (`src/patches/glibc/` is not created).
Two configure-level adjustments were needed, both caused by the host environment
rather than glibc source (see below).

- Host: Ubuntu 25.10, `gcc (Ubuntu 15.2.0-4ubuntu4) 15.2.0`, `GNU ld (GNU Binutils for Ubuntu) 2.45`
- glibc: `release/2.34/master` @ `2b656ff94d` (posix: Reset wordexp_t fields with WRDE_REUSE)
- Build time: `make -j32` about 31-36 s wall (about 310 s user), 32 cores

## Final configure line (run from an empty build dir; reuse verbatim in stage 20)

```bash
env -u CFLAGS -u CXXFLAGS -u LDFLAGS ../../../glibc/configure \
  CC=gcc CXX=false CFLAGS="-O2 -std=gnu11" \
  --prefix=/usr --libdir=/usr/lib --libexecdir=/usr/lib libc_cv_slibdir=/usr/lib \
  --with-headers="$SYSROOT/usr/include" \
  --enable-kernel=4.18 --enable-stack-protector=strong --enable-bind-now \
  --disable-werror --disable-profile --without-selinux
make -j"$(nproc)"
make install DESTDIR="$SYSROOT"
```

## Deviations from the spec's line (no patch required)

1. `CXX=false` instead of `CXX=g++`. With a C++ compiler configured, glibc builds
   the test-support helper `support/links-dso-program` against the host
   `libstdc++`/`libgcc_s`, which reference symbols newer than 2.34
   (`_dl_find_object@GLIBC_2.35`, `arc4random@GLIBC_2.36`,
   `__isoc23_strtoul@GLIBC_2.38`) -> link failure. `CXX=false` makes configure's
   C++ link check fail, so `CXX=` is empty and glibc uses `links-dso-program-c`.
   (`CXX=` alone does not work; configure falls back to g++.) glibc itself needs no C++.
2. `--without-selinux`. configure auto-detects host libselinux, then the build uses
   `-nostdinc` and cannot find `selinux/selinux.h` in `links-dso-program-c.c`.
   Disabling it is also desirable for a portable sysroot.

## Patches

None.

## Verification

- `readelf -V usr/lib/libc.so.6`: max symbol version `GLIBC_2.34`
- `usr/lib/ld-linux-x86-64.so.2` exists (238448 bytes)
- `lib64/ld-linux-x86-64.so.2` is NOT created by glibc with `--libdir=/usr/lib
  libc_cv_slibdir=/usr/lib`; **Task 8 must create the `lib64/ld-linux-x86-64.so.2 ->
  ../usr/lib/ld-linux-x86-64.so.2` link**. A test program linked with `--sysroot`
  has interpreter `/lib64/ld-linux-x86-64.so.2`.
- `gcc --sysroot=... t.c` links; `LINK-OK` (ran via the host loader because the
  sysroot lacks the lib64 link); also ran via the new loader with `--library-path`.

## Kernel headers (for Task 7)

- Longterm kernel: `6.18.55` (picked as newest `longterm` in kernel.org releases.json)
- URL: `https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.55.tar.xz`
- sha256: `f410638061a165c12f42ab871d2f3fcd525515359b5faeee80969cff84524df9`
- `make ARCH=x86 INSTALL_HDR_PATH=<sysroot>/usr headers_install`

## Submodule notes

`git submodule add --depth 1 -b release/2.34/master` fails (the shallow clone
fetches only the default branch). The submodule was added without `--depth`
(full clone) and `shallow = true` / `ignore = dirty` set in `.gitmodules`.
