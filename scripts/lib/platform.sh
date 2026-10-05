# shellcheck shell=bash
# Host detection and target-triple mapping.

detect_host_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo darwin ;;
    *) die "unsupported host OS: $(uname -s)" ;;
  esac
}

detect_host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unsupported host arch: $(uname -m)" ;;
  esac
}

# bundle_triples OS ARCH — target triples contained in the bundle for OS/ARCH.
bundle_triples() {
  case "$1-$2" in
    linux-amd64)  echo "x86_64-unknown-linux-musl x86_64-unknown-linux-gnu" ;;
    linux-arm64)  echo "aarch64-unknown-linux-musl aarch64-unknown-linux-gnu" ;;
    darwin-amd64) die "darwin-amd64 is not a supported bundle (use darwin-arm64)" ;;
    darwin-arm64) echo "arm64-apple-darwin" ;;
    *) die "unsupported bundle: $1-$2" ;;
  esac
}

triple_cpu() { printf '%s\n' "${1%%-*}"; }

triple_libc() {
  case "$1" in
    *-linux-musl) echo musl ;;
    *-linux-gnu) echo gnu ;;
    *-apple-darwin) echo darwin ;;
    *) die "unknown triple: $1" ;;
  esac
}

triple_os() {
  local libc
  libc="$(triple_libc "$1")" || return 1
  if [ "$libc" = darwin ]; then echo darwin; else echo linux; fi
}

cpu_to_arch() {
  case "$1" in
    x86_64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unknown cpu: $1" ;;
  esac
}

kernel_arch() {
  case "$1" in
    x86_64) echo x86 ;;
    aarch64) echo arm64 ;;
    *) die "no kernel arch for cpu $1" ;;
  esac
}

# glibc_loader CPU — sysroot-relative path of the glibc dynamic loader (PT_INTERP minus leading /).
glibc_loader() {
  case "$1" in
    x86_64) echo lib64/ld-linux-x86-64.so.2 ;;
    aarch64) echo lib/ld-linux-aarch64.so.1 ;;
    *) die "no glibc loader for cpu $1" ;;
  esac
}

musl_loader() { printf 'lib/ld-musl-%s.so.1\n' "$1"; }

# memprof_supported TRIPLE — compiler-rt's memprof runtime exists for x86_64 Linux only
# (AllSupportedArchDefs.cmake:96, config-ix.cmake:842) and refuses static linking
# (memprof_rtl.cpp:181), which rules out musl. Profiles from it apply to every triple.
memprof_supported() { [ "$1" = x86_64-unknown-linux-gnu ]; }

# elidealloc_backend TRIPLE — libelidealloc-shim's build-time backend: mimalloc where mimalloc is
# the process allocator (gnu, linked with -lmimalloc; musl with MUSL_USE_MIMALLOC), else forward.
elidealloc_backend() {
  case "$(triple_libc "$1")" in
    gnu) echo mimalloc ;;
    musl) if is_yes "${MUSL_USE_MIMALLOC:-yes}"; then echo mimalloc; else echo forward; fi ;;
    *) echo forward ;;
  esac
}

# musl_gcc_prefix TRIPLE — GCC-style prefix GraalVM looks for, e.g. x86_64-linux-musl.
musl_gcc_prefix() { printf '%s-linux-musl\n' "$(triple_cpu "$1")"; }

rust_triple() {
  case "$1" in
    arm64-apple-darwin) echo aarch64-apple-darwin ;;
    *) echo "$1" ;;
  esac
}

# bundle_triple_for_libc LIBC — the bundle triple (from $ALL_TARGETS) using LIBC (musl|gnu).
bundle_triple_for_libc() {
  local t
  for t in $ALL_TARGETS; do
    if [ "$(triple_libc "$t")" = "$1" ]; then echo "$t"; return 0; fi
  done
  return 1
}

sysroot_of() { printf '%s/sysroot/%s\n' "$BUNDLE_DIR" "$1"; }

march_for() {
  case "$1" in
    x86_64-unknown-linux-*) echo "$MARCH_AMD64" ;;
    aarch64-unknown-linux-*) echo "$MARCH_ARM64" ;;
    *) echo "" ;;
  esac
}

mtune_for() {
  case "$1" in
    x86_64-unknown-linux-*) echo "$MTUNE_AMD64" ;;
    aarch64-unknown-linux-*) echo "$MTUNE_ARM64" ;;
    *) echo "" ;;
  esac
}

# arch_flags TRIPLE — -march/-mtune for Linux triples; empty for darwin (cflags profile decides).
arch_flags() {
  local m
  m="$(march_for "$1")"
  if [ -n "$m" ]; then printf -- '-march=%s -mtune=%s\n' "$m" "$(mtune_for "$1")"; else echo ""; fi
}
