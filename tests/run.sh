#!/usr/bin/env bash
# Run shell unit tests (tests/unit/*.test.sh) and shellcheck.
# Usage: tests/run.sh [name-filter]
set -uo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export ROOT_DIR
filter="${1:-}"
failed=0

for t in "$ROOT_DIR"/tests/unit/*.test.sh; do
  [ -e "$t" ] || continue
  case "$(basename "$t")" in *"$filter"*) ;; *) continue ;; esac
  echo "$(basename "$t")"
  bash "$t" || failed=1
done

if [ -z "$filter" ] && command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck"
  cd "$ROOT_DIR" || exit 1
  bash_files=$(ls build.sh scripts/*.sh scripts/lib/*.sh scripts/stages/*.sh scripts/components/*.sh \
    scripts/verify/*.sh tests/run.sh tests/lib/*.sh tests/unit/*.sh tests/stages/*.sh 2>/dev/null)
  # shellcheck disable=SC2086
  shellcheck -x $bash_files || failed=1
  sh_files=$(ls src/elide-toolchain src/shims/musl-gcc 2>/dev/null || true)
  # shellcheck disable=SC2086
  [ -z "$sh_files" ] || shellcheck -s sh $sh_files || failed=1
fi
exit "$failed"
