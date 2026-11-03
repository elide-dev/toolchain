# Toolchain 2026.11 consumer migration

This toolchain change does not update or publish Elide or ACCP. The consuming agent
must coordinate the following changes before adopting its archives.

| Toolchain pin | Required consumer alignment |
| --- | --- |
| AWS-LC 5.12.0 | aws-lc-rs 1.19.0 and aws-lc-sys 0.47.0; regenerate Cargo.lock |
| AWS-LC 5.12.0 | Rebuild and release the Elide ACCP static JNI adapter against 5.12.0; update the Maven version, adapter checksums and mirror artifacts |
| SQLite 3.54.1 | org.xerial:sqlite-jdbc 3.54.1.0; regenerate tools/deps.* through the supported generator |
| cflags 61d9374 | Rebuild every C/C++ dependency and invalidate native/ThinLTO caches; relative-vtable objects must not survive |

The inspected Elide runtime main revision was `2daeedccb`. It still pinned
aws-lc-rs 1.18.2, aws-lc-sys 0.46.0, sqlite-jdbc 3.53.4.0, and ACCP
2.6.0-elide.3. That ACCP release explicitly requires AWS-LC 5.11.0. Do not
combine it with this toolchain's new libcrypto without rebuilding the adapter.
Preserve the shared unprefixed AWS-LC symbol contract (`AWS_LC_SYS_NO_PREFIX`),
per-target staging and header/archive alignment.

The upstream [aws-lc-rs 1.19.0 release](https://github.com/aws/aws-lc-rs/releases/tag/v1.19.0)
identifies aws-lc-sys 0.47.0 as bundling AWS-LC 5.12.0. The
[sqlite-jdbc 3.54.1.0 release](https://github.com/xerial/sqlite-jdbc/releases/tag/3.54.1.0)
matches SQLite 3.54.1. The toolchain also backports its two JNI lifetime fixes
into the pinned sqlite-jni shim. Elide has its own `crates/db/src/sqlite3jni.c`:
check its duplicate-open and serialize-array-release paths for the same fixes.

Consumer validation should cover Rust TLS, ACCP cryptography through Native Image,
SQLite JDBC open/close/serialize/deserialize, rusqlite transactions, and native
links for GNU, musl and macOS. This migration does not claim those downstream
checks have run.

## Dependency audit

Updated Brotli 1.2.1, hiredis 1.5.0, mimalloc 3.6.1, OpenSSL 4.1.0,
SQLCipher 4.20.0, AWS-LC 5.12.0, SQLite 3.54.1, Linux LTS headers 6.18.60,
Propeller `ea240c1`, the cflags pin, Action packages and pinned CI actions.
SQLCipher 4.20 uses OpenSSL's EVP_MAC API and no longer builds with AWS-LC's
OpenSSL-compatible headers. Enable it with `BUILD_OPENSSL=yes BUILD_AWS_LC=no`;
the configuration check rejects the unsupported combination before building.

SQLite now uses the canonical sqlite/sqlite remote: the old elide-tools fork
has no release tags and cannot serve the pinned release in a clean checkout.

LLVM stays at published 23.1.4: a 23.1.5 Git tag existed during this audit,
but no published release or bootstrap assets existed. The updater now holds
LLVM to LLVM_VERSION so source and checksummed bootstrap assets cannot diverge.
Propeller's Abseil, Protobuf, googletest and quipper pins follow its CMake inputs.
The patched musl fork and glibc 2.17 compatibility floor remain deliberate
platform contracts. Other native components were already at their latest stable tags.

Strong stack canaries, conventional C++ vtables and object identity, and a true
x86-64-v3 baseline accompany existing ThinLTO/O3, PIC, RELRO and non-executable
stack flags. No end-to-end Elide speedup is claimed; benchmark the rebuilt consumer.

## Local validation

The shell unit suite and ShellCheck pass, as do Action typechecking and 15 tests.
cflags' LLVM 23.1.4 CI passed Linux amd64, Linux arm64 and Darwin arm64.
A source build of LLVM 23.1.4 passed clangd LSP checks on GNU and musl from a
renamed bundle path with spaces, the Xcode 27 TAPI fixture link, and all six
DeduBB RUN-line tests. The rebased Propeller executable builds and exposes its
DeduBB options; directive generation, DeduBB codegen and inertness integration checks pass.
The built clangd and Propeller reference no GLIBC version above 2.16. Rust TSAN linked with `-Zbuild-std` through the relocated GNU
wrapper and the corrected libgcc_s script.

Brotli, hiredis, AWS-LC and SQLite built for GNU and musl using the new flags;
combined Brotli/crypto/SQLite smoke executables ran for both. Mimalloc, OpenSSL
and SQLCipher built on GNU; SQLCipher encrypted writes and reopen/read succeeded.
The JNI fixes were compiled into the rebuilt SQLite amalgamation. These are
targeted Linux checks, not a complete three-platform release build or Elide test run.

A local in-memory SQLite workload (500,000 prepared inserts plus a checked sum,
nine alternating runs) measured median 0.109257 s for the existing archive and
0.110365 s for the upgraded archive, about +1.0%. This compares both library and
flag changes on one host, not isolated canary overhead or overall Elide performance.
