#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"

if [ "$HOST_OS" = linux ]; then
  for t in $ALL_TARGETS; do
    s="$(sysroot_of "$t")"
    assert_file "$s/usr/include/linux/version.h"
    assert_file "$s/usr/include/asm/unistd.h"
    assert_file "$s/usr/include/asm-generic/errno.h"
  done
fi
assert_ok "$ROOT_DIR/scripts/check-versions.sh"
finish
