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

# cpu_count — host CPUs (ELIDE_CPU_COUNT overrides, for tests).
cpu_count() {
  if [ -n "${ELIDE_CPU_COUNT:-}" ]; then echo "$ELIDE_CPU_COUNT"; return 0; fi
  if command -v nproc >/dev/null 2>&1; then nproc; else sysctl -n hw.ncpu; fi
}

# mem_gb — memory available to the build in whole GiB: Linux MemAvailable, darwin total RAM
# (ELIDE_MEM_GB overrides, for tests). Empty when it cannot be determined.
mem_gb() {
  if [ -n "${ELIDE_MEM_GB:-}" ]; then echo "$ELIDE_MEM_GB"; return 0; fi
  if [ -r /proc/meminfo ]; then
    awk '/^MemAvailable:/ {printf "%d\n", $2 / 1048576; exit}' /proc/meminfo
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d\n", $1 / 1073741824}'
  fi
  return 0
}

# default_jobs CPUS MEM_GB — compile parallelism: one job per CPU, but at most one per 2 GiB
# (LLVM's heaviest translation units need ~1.5 GiB each). Unknown memory: CPUS.
default_jobs() {
  local cpus="$1" mem="${2:-}" by_mem
  if [ -z "$mem" ]; then echo "$cpus"; return 0; fi
  by_mem=$(( mem / 2 )); [ "$by_mem" -ge 1 ] || by_mem=1
  if [ "$by_mem" -lt "$cpus" ]; then echo "$by_mem"; else echo "$cpus"; fi
}

# default_link_jobs MEM_GB — concurrent heavy links (static clang/lld/bolt link at several GiB
# each): one per 8 GiB, between 1 and 4. Unknown memory: 2.
default_link_jobs() {
  local mem="${1:-}" n
  if [ -z "$mem" ]; then echo 2; return 0; fi
  n=$(( mem / 8 )); [ "$n" -ge 1 ] || n=1; [ "$n" -le 4 ] || n=4
  echo "$n"
}

# is_release_build — RELEASE_BUILD=yes|no decides; otherwise a TOOLCHAIN_VERSION without a
# -dev or + suffix is a release.
is_release_build() {
  if [ -n "${RELEASE_BUILD:-}" ]; then is_yes "$RELEASE_BUILD"; return; fi
  case "${TOOLCHAIN_VERSION:-}" in *-dev*|*+*) return 1 ;; *) return 0 ;; esac
}

# xz_level — XZ_LEVEL, else 9 for release builds and 6 otherwise (much faster, slightly larger).
xz_level() {
  if [ -n "${XZ_LEVEL:-}" ]; then
    case "$XZ_LEVEL" in [0-9]) echo "$XZ_LEVEL" ;; *) die "XZ_LEVEL must be 0-9 (got $XZ_LEVEL)" ;; esac
  elif is_release_build; then echo 9; else echo 6; fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# fetch_pinned URL SHA256 DEST — download URL to DEST (once), verifying SHA256; a cached file
# with the wrong checksum is re-downloaded. The download is verified before it lands at DEST, and
# its temporary name is unique, so concurrent jobs sharing a cache directory cannot collide.
fetch_pinned() {
  local url="$1" sha="$2" dest="$3" actual part
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && [ "$(sha256_of "$dest")" != "$sha" ]; then
    warn "cached $dest has wrong sha256; removing and re-downloading"
    rm -f "$dest"
  fi
  if [ ! -f "$dest" ]; then
    log "downloading $(basename "$dest")"
    part="$dest.part.$$"
    curl -fsSL --retry 3 -o "$part" "$url" || { rm -f "$part"; die "download failed: $url"; }
    actual="$(sha256_of "$part")"
    if [ "$actual" != "$sha" ]; then
      rm -f "$part"
      die "sha256 mismatch for $url: expected $sha, got $actual"
    fi
    mv -f "$part" "$dest"
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

# patch_required_var PATCH — VAR from a leading "# requires: VAR" line (empty if none). Such a
# patch is applied only when VAR is yes (a vars.sh knob).
patch_required_var() { head -n1 "$1" | sed -n 's/^# requires: *\([A-Za-z_][A-Za-z0-9_]*\) *$/\1/p'; }

# apply_patches COMPONENT DIR — apply PATCHES_DIR/COMPONENT/*.patch to DIR, idempotently.
# GIT_CEILING_DIRECTORIES stops git from discovering the enclosing repo, so patch paths are
# always relative to DIR (a submodule root, or a source copy under out/). Patches of one
# component must not overlap hunks: "already applied" is detected per patch by a reverse check.
apply_patches() {
  local component="$1" dir="$2" patch_dir patch req
  patch_dir="${PATCHES_DIR:-$ROOT_DIR/src/patches}/$component"
  [ -d "$patch_dir" ] || return 0
  for patch in "$patch_dir"/*.patch; do
    [ -e "$patch" ] || continue
    req="$(patch_required_var "$patch")"
    if [ -n "$req" ] && ! is_yes "${!req:-}"; then
      log "skipping $(basename "$patch") ($req is not yes)"; continue
    fi
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

# unapply_patches COMPONENT DIR — reverse every applied PATCHES_DIR/COMPONENT patch, last first,
# so DIR is back at its pinned commit (stage 00's clean-tree check runs after this).
unapply_patches() {
  local component="$1" dir="$2" patch_dir patches=() p i
  patch_dir="${PATCHES_DIR:-$ROOT_DIR/src/patches}/$component"
  [ -d "$patch_dir" ] || return 0
  for p in "$patch_dir"/*.patch; do [ -e "$p" ] && patches+=("$p"); done
  for (( i=${#patches[@]}-1; i>=0; i-- )); do
    p="${patches[$i]}"
    if (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$dir")" git apply --reverse --check "$p" 2>/dev/null); then
      log "un-applying $(basename "$p") from $component"
      (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$dir")" git apply --reverse "$p")
    fi
  done
  return 0
}
