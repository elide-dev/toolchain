# shellcheck shell=bash
# Flags for target code: cflags profile + cflags.local overlay, filtered for the triple's
# floors, followed by -march/-mtune (last one wins). Toolchain-layer builds (libc, runtimes,
# LLVM, mimalloc) use their own flags and do not call these.

read_flag_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  sed -e 's/#.*$//' -e 's/[[:space:]]\{1,\}$//' "$f" | grep -v '^[[:space:]]*$' | xargs || true
}

# profile_flags OS ARCH — upstream compile rollup (base → os → os-arch), then local overlay.
profile_flags() {
  local os="$1" arch="$2" out f content
  out="$("$ROOT_DIR/cflags/cli/cflags.sh" "$os" "$arch")"
  for f in base "$os" "$os-$arch"; do
    content="$(read_flag_file "$ROOT_DIR/cflags.local/$f.txt")"
    if [ -n "$content" ]; then out="$out $content"; fi
  done
  printf '%s\n' "$out"
}

# filter_flags_for_triple TRIPLE FLAG... — drop flags that would raise the triple's floor.
filter_flags_for_triple() {
  local triple="$1" f out="" drop_relr=no
  shift
  if [ "$(triple_libc "$triple")" = gnu ] && version_lt "$GLIBC_FLOOR" 2.36; then drop_relr=yes; fi
  for f in "$@"; do
    # DT_RELR makes lld emit a GLIBC_ABI_DT_RELR version need (glibc >= 2.36).
    if [ "$drop_relr" = yes ] && [ "$f" = "-Wl,-z,pack-relative-relocs" ]; then continue; fi
    out="$out $f"
  done
  printf '%s\n' "${out# }"
}

target_cflags() {
  local t="$1" os arch
  os="$(triple_os "$t")"
  arch="$(cpu_to_arch "$(triple_cpu "$t")")"
  # sanitizer_layer_flags (scripts/lib/sanitizers.sh) is empty unless stage 60 sets SANITIZER_LAYER.
  # shellcheck disable=SC2046
  printf '%s%s %s\n' "$(sanitizer_layer_flags "$t")" \
    "$(filter_flags_for_triple "$t" $(profile_flags "$os" "$arch"))" "$(arch_flags "$t")"
}

target_cxxflags() { target_cflags "$1"; }

# Link flags for shared objects and archives (no -static).
target_ldflags() { target_cflags "$1"; }

# Link flags for executables: musl executables are fully static (the build host has no musl loader).
target_exe_ldflags() {
  if [ "$(triple_libc "$1")" = musl ]; then
    printf '%s -static\n' "$(target_ldflags "$1")"
  else
    target_ldflags "$1"
  fi
}
