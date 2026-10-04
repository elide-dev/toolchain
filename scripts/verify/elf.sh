# shellcheck shell=bash
# ELF inspection helpers for floor and interpreter checks.

readelf_bin() {
  if [ -n "${READELF:-}" ]; then echo "$READELF"; return; fi
  local c
  for c in "$BUNDLE_DIR/bin/llvm-readelf" "$STAGE1_DIR/bin/llvm-readelf"; do
    if [ -x "$c" ]; then echo "$c"; return; fi
  done
  command -v llvm-readelf || command -v readelf
}

# glibc_needs FILE — GLIBC_* version names FILE requires (from .gnu.version_r), sorted.
glibc_needs() {
  "$(readelf_bin)" -V "$1" 2>/dev/null \
    | awk '/Version needs section/{n=1} n { for (i = 1; i <= NF; i++) if ($i ~ /^GLIBC_/) print $i }' \
    | sort -uV
}

# glibc_floor_violations FILE — one line per requirement above GLIBC_FLOOR, plus any
# GLIBC_ABI_* (e.g. DT_RELR, DT_X86_64_PLT: absent from stock 2.34 hosts) or GLIBC_PRIVATE.
glibc_floor_violations() {
  local f="$1" v
  for v in $(glibc_needs "$f"); do
    case "$v" in
      GLIBC_ABI_*|GLIBC_PRIVATE) echo "$f: needs $v" ;;
      GLIBC_[0-9]*) if version_lt "$GLIBC_FLOOR" "${v#GLIBC_}"; then echo "$f: needs $v (floor $GLIBC_FLOOR)"; fi ;;
    esac
  done
  return 0
}

needed_libs() {
  "$(readelf_bin)" -d "$1" 2>/dev/null | awk '/\(NEEDED\)/ { gsub(/[][]/, "", $NF); print $NF }'
}

interp_of() {
  "$(readelf_bin)" -l "$1" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p'
}
