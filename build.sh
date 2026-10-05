#!/usr/bin/env bash
# Build an elide-toolchain bundle for the host OS/arch.
# Spec: docs/superpowers/specs/2026-10-04-universal-native-toolchain-design.md
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "ERROR: bash >= 4 is required (macOS: brew install bash)" >&2
  exit 1
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export ROOT_DIR

STAGES=(
  00-sources
  10-llvm-stage1
  20-libc-gnu
  21-libc-musl
  30-runtimes
  35-mimalloc
  36-llvm-deps
  40-llvm-stage2
  50-components
  90-package
  95-verify
)
STAGES_DIR="${ELIDE_STAGES_DIR:-$ROOT_DIR/scripts/stages}"

usage() {
  cat <<'EOF'
Usage: ./build.sh [options]

  --from STAGE      run STAGE and every later stage, ignoring (and clearing) their stamps
  --only STAGE      run only STAGE, ignoring its stamp
  --targets LIST    comma-separated triples for per-target stages (default: all in bundle)
  --clean           delete out/<os>-<arch> first
  --dry-run         print the stages that would run, then exit
  -h, --help        show this help

Stages: 00-sources 10-llvm-stage1 20-libc-gnu 21-libc-musl 30-runtimes 35-mimalloc
        36-llvm-deps 40-llvm-stage2 50-components 90-package 95-verify
EOF
}

from="" only="" clean=no dry_run=no targets_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) from="${2:?--from needs a stage}"; shift 2 ;;
    --only) only="${2:?--only needs a stage}"; shift 2 ;;
    --targets) targets_arg="${2:?--targets needs a list}"; shift 2 ;;
    --clean) clean=yes; shift ;;
    --dry-run) dry_run=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"

if [ -n "$targets_arg" ]; then
  TARGETS=""
  for t in ${targets_arg//,/ }; do
    case " $ALL_TARGETS " in
      *" $t "*) TARGETS="$TARGETS $t" ;;
      *) die "target $t is not in the $HOST_OS-$HOST_ARCH bundle ($ALL_TARGETS)" ;;
    esac
  done
  TARGETS="${TARGETS# }"
  export TARGETS
fi

stage_index() {
  local i
  for i in "${!STAGES[@]}"; do
    if [ "${STAGES[$i]}" = "$1" ]; then echo "$i"; return 0; fi
  done
  die "unknown stage: $1"
}

run_stage() {
  local stage="$1"
  log "stage $stage ($HOST_OS-$HOST_ARCH; targets: $TARGETS)"
  (
    # shellcheck source=/dev/null
    source "$STAGES_DIR/$stage.sh"
    if declare -F stage_applies >/dev/null && ! stage_applies; then
      log "stage $stage does not apply to $HOST_OS-$HOST_ARCH; skipping"
      exit 0
    fi
    stage_main
  )
  stamp_done "$stage"
}

# Validate stage names before --clean can delete anything: a typo must not wipe a build.
if [ -n "$only" ]; then stage_index "$only" >/dev/null; fi
if [ -n "$from" ]; then stage_index "$from" >/dev/null; fi

if [ "$clean" = yes ] && [ "$dry_run" = no ]; then
  log "cleaning $OUT_DIR"
  rm -rf "$OUT_DIR"
fi

plan=()
if [ -n "$only" ]; then
  stage_index "$only" >/dev/null
  plan=("$only")
else
  start=0
  if [ -n "$from" ]; then start="$(stage_index "$from")"; fi
  for i in "${!STAGES[@]}"; do
    s="${STAGES[$i]}"
    [ "$i" -ge "$start" ] || continue
    if [ -z "$from" ] && [ "$clean" = no ] && stamp_exists "$s"; then continue; fi
    plan+=("$s")
  done
fi

if [ "$dry_run" = yes ]; then
  [ "${#plan[@]}" -eq 0 ] || printf '%s\n' "${plan[@]}"
  exit 0
fi

if [ -n "$from" ]; then
  for s in "${plan[@]}"; do stamp_clear "$s"; done
fi

if [ "${#plan[@]}" -eq 0 ]; then
  log "nothing to do (all stages stamped; use --from or --clean)"
  exit 0
fi

for s in "${plan[@]}"; do run_stage "$s"; done
log "bundle: $BUNDLE_DIR"
