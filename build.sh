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
  31-sanitizer-runtimes
  35-mimalloc
  36-llvm-deps
  40-llvm-stage2
  45-propeller
  50-components
  60-sanitizer-addons
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

Stages: 00-sources 10-llvm-stage1 20-libc-gnu 21-libc-musl 30-runtimes 31-sanitizer-runtimes
        35-mimalloc 36-llvm-deps 40-llvm-stage2 45-propeller 50-components 60-sanitizer-addons
        90-package 95-verify
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

LOG_DIR="$OUT_DIR/logs"
FAIL_TAIL_LINES="${FAIL_TAIL_LINES:-200}"

# stage_body STAGE — run one stage in a subshell (errexit re-enabled inside: callers capture rc).
stage_body() {
  (
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$STAGES_DIR/$1.sh"
    if declare -F stage_applies >/dev/null && ! stage_applies; then
      log "stage $1 does not apply to $HOST_OS-$HOST_ARCH; skipping"
      exit 0
    fi
    stage_main
  )
}

# run_stage STAGE — full output goes to $LOG_DIR/STAGE.log; the console gets start/finish lines
# (and the log tail on failure). VERBOSE=yes, or stage 95 (short ok/FAIL lines), also streams it.
run_stage() {
  local stage="$1" logf start rc stream=no
  mkdir -p "$LOG_DIR"
  logf="$LOG_DIR/$stage.log"
  if is_yes "${VERBOSE:-no}" || [ "$stage" = 95-verify ]; then stream=yes; fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::stage $stage"; fi
  log "stage $stage ($HOST_OS-$HOST_ARCH; targets: $TARGETS) → $logf"
  start=$SECONDS
  set +e
  if [ "$stream" = yes ]; then
    stage_body "$stage" 2>&1 | tee "$logf"
    rc=${PIPESTATUS[0]}
  else
    stage_body "$stage" > "$logf" 2>&1
    rc=$?
  fi
  set -e
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi
  if [ "$rc" -ne 0 ]; then
    if [ "$stream" = no ]; then
      log "last $FAIL_TAIL_LINES lines of $logf:"
      tail -n "$FAIL_TAIL_LINES" "$logf" >&2
    fi
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::stage $stage failed (exit $rc); full log: $logf"; fi
    die "stage $stage failed after $((SECONDS - start))s (exit $rc); full log: $logf"
  fi
  log "stage $stage done in $((SECONDS - start))s"
  stamp_done "$stage"
}

# Validate stage names before --clean can delete anything: a typo must not wipe a build.
if [ -n "$only" ]; then stage_index "$only" >/dev/null; fi
if [ -n "$from" ]; then stage_index "$from" >/dev/null; fi
check_stage1_source "$HOST_OS" "$HOST_ARCH" "$STAGE1_SOURCE"
if is_yes "${USE_CCACHE:-auto}" && ! command -v ccache >/dev/null 2>&1; then
  die "USE_CCACHE=$USE_CCACHE but ccache is not on PATH"
fi

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

log "parallelism: JOBS=$JOBS LINK_JOBS=$LINK_JOBS (cpus $(cpu_count), available memory ${MEM_GB:-unknown} GiB)"
log "compiler launcher: $(compiler_launcher | grep . || echo none)${CCACHE_DIR:+ (CCACHE_DIR=$CCACHE_DIR)}; downloads: $CACHE_DIR"
if [ "$HOST_OS" = linux ]; then log "stage 1: $STAGE1_SOURCE"; fi
for s in "${plan[@]}"; do run_stage "$s"; done
log "bundle: $BUNDLE_DIR"
