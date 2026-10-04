#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"

[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }
t="$(bundle_triple_for_libc musl)"; s="$(sysroot_of "$t")"
for f in usr/lib/libc.a usr/lib/crt1.o usr/lib/crti.o usr/lib/crtn.o usr/lib/rcrt1.o usr/include/stdio.h usr/include/linux/version.h; do
  assert_file "$s/$f"
done
finish
