# shellcheck shell=bash
# Stage 36: static zlib-ng + zstd for the gnu triple, built with stage-1 clang. Stage 2 links
# them so the shipped lld supports --compress-debug-sections=zstd (used by cflags/linux-bin.txt).
# Not shipped.

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t prefix="$OUT_DIR/llvm-deps"
  t="$(bundle_triple_for_libc gnu)"
  export TOOLCHAIN_ROOT="$STAGE1_DIR"
  fresh_dir "$prefix"
  build_zlib_ng "$t" "$prefix"
  build_zstd "$t" "$prefix"
}
