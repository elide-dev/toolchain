# shellcheck shell=bash disable=SC2034
# Local build knobs. Each may also be set in the environment.

# Components (registry and build order: scripts/lib/components.sh)
BUILD_ZLIB_NG=${BUILD_ZLIB_NG:-yes}
BUILD_ZSTD=${BUILD_ZSTD:-yes}
BUILD_BROTLI=${BUILD_BROTLI:-yes}
BUILD_SNAPPY=${BUILD_SNAPPY:-yes}
BUILD_LZ4=${BUILD_LZ4:-yes}
BUILD_CRC32C=${BUILD_CRC32C:-yes}
BUILD_AWS_LC=${BUILD_AWS_LC:-yes}
BUILD_OPENSSL=${BUILD_OPENSSL:-no}
BUILD_ZLIB=${BUILD_ZLIB:-no}
BUILD_SQLITE=${BUILD_SQLITE:-no}
BUILD_SQLCIPHER=${BUILD_SQLCIPHER:-no}
BUILD_CAPNP=${BUILD_CAPNP:-no}
BUILD_HIREDIS=${BUILD_HIREDIS:-no}
BUILD_LEVELDB=${BUILD_LEVELDB:-no}

# musl
MUSL_USE_MIMALLOC=${MUSL_USE_MIMALLOC:-yes}
MUSL_USE_LTO=${MUSL_USE_LTO:-yes}

# mimalloc
MIMALLOC_SECURE=${MIMALLOC_SECURE:-OFF}
MIMALLOC_GUARDED=${MIMALLOC_GUARDED:-OFF}

# LLVM feature patches (src/patches/llvm, '# requires:' headers) and tools
LLVM_DEDUBB=${LLVM_DEDUBB:-yes}           # DeduBB codegen; inert without -dedubb-directives
BUILD_PROPELLER=${BUILD_PROPELLER:-yes}   # stage 45: generate_propeller_profiles (Linux)

# Verification
REQUIRE_LBR=${REQUIRE_LBR:-no}            # yes: the live Propeller check fails instead of skipping

# Build behaviour
USE_SCCACHE=${USE_SCCACHE:-no}
USE_CCACHE=${USE_CCACHE:-auto}            # ccache for CMake builds (auto: when on PATH); wins over sccache
# Sanitizers: runtimes (+ libFuzzer) in the main bundle; per-sanitizer add-on archives (Linux gnu
# triples; CI builds them only on push to main and on release).
BUILD_SANITIZERS=${BUILD_SANITIZERS:-yes}
BUILD_SANITIZER_VARIANTS=${BUILD_SANITIZER_VARIANTS:-no}
REQUIRE_CONTAINER_CHECKS=${REQUIRE_CONTAINER_CHECKS:-no}
