#!/usr/bin/env bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
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
assert_eq "$(rust_host_triple linux amd64)" x86_64-unknown-linux-gnu
assert_eq "$(rust_host_triple darwin arm64)" aarch64-apple-darwin
assert_fails rust_host_triple darwin amd64
assert_eq "$RUST_TOOLCHAIN" "$(cat "$ROOT_DIR/rustversion")" "versions.env pins the rustversion toolchain"
for host in "linux amd64" "linux arm64" "darwin arm64"; do
  # shellcheck disable=SC2086
  for pin in "rustc $(rust_host_triple $host)" "cargo $(rust_host_triple $host)" \
      $(for t in $(bundle_triples $host); do printf 'rust-std:%s ' "$(rust_triple "$t")"; done); do
    pin="${pin/:/ }"
    # shellcheck disable=SC2086
    assert_eq "$(rust_pin $pin sha256 | wc -c | xargs)" 65 "sha256 pin for Rust $pin"
  done
done
# shellcheck disable=SC2034 # read indirectly by rust_pin
RUST_TOOLCHAIN=nightly-2026-01-02 RUST_SHA256_RUST_STD_X86_64_UNKNOWN_LINUX_MUSL=abc
assert_eq "$(rust_pin rust-std x86_64-unknown-linux-musl url)" https://static.rust-lang.org/dist/2026-01-02/rust-std-nightly-x86_64-unknown-linux-musl.tar.xz
assert_eq "$(rust_pin rust-std x86_64-unknown-linux-musl sha256)" abc
assert_eq "$(rust_pin cargo riscv64gc-unknown-linux-gnu sha256)" ""

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

# Prebuilt stage 1: pinned release per arch, default knob
for a in amd64 arm64; do
  u="$(llvm_prebuilt_pin linux "$a" url)"
  assert_contains "$u" "/llvmorg-$LLVM_VERSION/LLVM-$LLVM_VERSION-Linux-" "linux-$a pin is the LLVM_VERSION release"
  assert_eq "${#u}" "${#u}"
  case "$(llvm_prebuilt_pin linux "$a" sha256)" in
    [0-9a-f]*) assert_eq "${#LLVM_PREBUILT_LINUX_AMD64_SHA256}" 64 ;;
    *) _fail "no sha256 pin for linux-$a" ;;
  esac
done
assert_contains "$(llvm_prebuilt_pin linux amd64 url)" "Linux-X64.tar.xz"
assert_contains "$(llvm_prebuilt_pin linux arm64 url)" "Linux-ARM64.tar.xz"
assert_eq "$(llvm_prebuilt_pin linux arm64 sha256)" "$LLVM_PREBUILT_LINUX_ARM64_SHA256"
assert_eq "$(llvm_prebuilt_pin darwin arm64 url)" "" "no prebuilt on darwin"
assert_eq "$(default_stage1_source linux amd64)" prebuilt
assert_eq "$(default_stage1_source linux arm64)" prebuilt
assert_eq "$(default_stage1_source darwin arm64)" build "darwin builds its LLVM"
assert_eq "$(LLVM_PREBUILT_LINUX_ARM64_URL='' default_stage1_source linux arm64)" build "no pin -> build"
assert_ok check_stage1_source linux amd64 prebuilt
assert_ok check_stage1_source linux amd64 build
assert_ok check_stage1_source darwin arm64 build
assert_fails check_stage1_source darwin arm64 prebuilt
assert_fails check_stage1_source linux amd64 source
assert_fails env LLVM_PREBUILT_LINUX_AMD64_SHA256= bash -c "source '$ROOT_DIR/scripts/lib/common.sh'; source '$ROOT_DIR/scripts/lib/platform.sh'; check_stage1_source linux amd64 prebuilt"

finish
