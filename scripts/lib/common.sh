# shellcheck shell=bash
# Shared build helpers: logging, stamps, patches, version comparison.

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

is_yes() { case "${1:-}" in yes|YES|on|ON|true|1) return 0 ;; *) return 1 ;; esac; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# version_lt A B — true when version A sorts strictly before version B.
version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

cpu_count() {
  if command -v nproc >/dev/null 2>&1; then nproc; else sysctl -n hw.ncpu; fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

is_elf() {
  [ -f "$1" ] && [ "$(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' \n')" = '177ELF' ]
}

stamp_path()   { printf '%s/%s.done\n' "$STAMPS_DIR" "$1"; }
stamp_exists() { [ -f "$(stamp_path "$1")" ]; }
stamp_done()   { mkdir -p "$STAMPS_DIR"; date -u +%Y-%m-%dT%H:%M:%SZ > "$(stamp_path "$1")"; }
stamp_clear()  { rm -f "$(stamp_path "$1")"; }

# fresh_dir DIR — remove and recreate a directory; every stage starts from a clean build dir.
fresh_dir() { rm -rf "$1"; mkdir -p "$1"; }

# apply_patches COMPONENT DIR — apply PATCHES_DIR/COMPONENT/*.patch to DIR, idempotently.
# GIT_CEILING_DIRECTORIES stops git from discovering the enclosing repo, so patch paths are
# always relative to DIR (a submodule root, or a source copy under out/).
apply_patches() {
  local component="$1" dir="$2" patch_dir patch
  patch_dir="${PATCHES_DIR:-$ROOT_DIR/src/patches}/$component"
  [ -d "$patch_dir" ] || return 0
  for patch in "$patch_dir"/*.patch; do
    [ -e "$patch" ] || continue
    if (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$dir")" git apply --check "$patch" 2>/dev/null); then
      log "applying $(basename "$patch") to $component"
      (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$dir")" git apply "$patch")
    elif (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$dir")" git apply --reverse --check "$patch" 2>/dev/null); then
      log "already applied: $(basename "$patch")"
    else
      die "cannot apply $patch to $dir"
    fi
  done
  return 0
}
