#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/platform.sh
source "$ROOT_DIR/scripts/lib/platform.sh"
# shellcheck source=versions.env
source "$ROOT_DIR/versions.env"

assert_eq "$(bundle_triples linux amd64)" "x86_64-unknown-linux-musl x86_64-unknown-linux-gnu"
assert_eq "$(bundle_triples linux arm64)" "aarch64-unknown-linux-musl aarch64-unknown-linux-gnu"
assert_fails bundle_triples darwin amd64
assert_eq "$(bundle_triples darwin arm64)" "arm64-apple-darwin"
assert_fails bundle_triples windows amd64

assert_eq "$(triple_cpu aarch64-unknown-linux-gnu)" aarch64
assert_eq "$(triple_libc x86_64-unknown-linux-musl)" musl
assert_eq "$(triple_libc x86_64-unknown-linux-gnu)" gnu
assert_eq "$(triple_libc arm64-apple-darwin)" darwin
assert_eq "$(triple_os arm64-apple-darwin)" darwin
assert_eq "$(triple_os aarch64-unknown-linux-musl)" linux
assert_fails triple_libc x86_64-pc-windows-msvc

assert_eq "$(cpu_to_arch x86_64)" amd64
assert_eq "$(cpu_to_arch arm64)" arm64
assert_eq "$(kernel_arch x86_64)" x86
assert_eq "$(kernel_arch aarch64)" arm64
assert_eq "$(glibc_loader x86_64)" lib64/ld-linux-x86-64.so.2
assert_eq "$(glibc_loader aarch64)" lib/ld-linux-aarch64.so.1
assert_eq "$(musl_loader x86_64)" lib/ld-musl-x86_64.so.1
assert_eq "$(musl_gcc_prefix x86_64-unknown-linux-musl)" x86_64-linux-musl
assert_eq "$(rust_triple arm64-apple-darwin)" aarch64-apple-darwin
assert_eq "$(rust_triple x86_64-unknown-linux-gnu)" x86_64-unknown-linux-gnu

ALL_TARGETS="x86_64-unknown-linux-musl x86_64-unknown-linux-gnu"
assert_eq "$(bundle_triple_for_libc gnu)" x86_64-unknown-linux-gnu
assert_eq "$(bundle_triple_for_libc musl)" x86_64-unknown-linux-musl
assert_fails bundle_triple_for_libc darwin

BUNDLE_DIR=/b
assert_eq "$(sysroot_of x86_64-unknown-linux-gnu)" /b/sysroot/x86_64-unknown-linux-gnu

assert_eq "$(arch_flags x86_64-unknown-linux-gnu)" "-march=x86-64-v3 -mtune=znver3"
assert_eq "$(arch_flags aarch64-unknown-linux-musl)" "-march=armv8.2-a+crypto+crc+dotprod -mtune=generic"
assert_eq "$(arch_flags arm64-apple-darwin)" ""

case "$(uname -s)" in Linux) assert_eq "$(detect_host_os)" linux ;; Darwin) assert_eq "$(detect_host_os)" darwin ;; esac

assert_ok memprof_supported x86_64-unknown-linux-gnu
assert_fails memprof_supported x86_64-unknown-linux-musl
assert_fails memprof_supported aarch64-unknown-linux-gnu
assert_fails memprof_supported arm64-apple-darwin
assert_eq "$(elidealloc_backend x86_64-unknown-linux-gnu)" mimalloc
assert_eq "$(MUSL_USE_MIMALLOC=yes elidealloc_backend x86_64-unknown-linux-musl)" mimalloc
assert_eq "$(MUSL_USE_MIMALLOC=no elidealloc_backend x86_64-unknown-linux-musl)" forward
assert_eq "$(elidealloc_backend arm64-apple-darwin)" forward

finish
