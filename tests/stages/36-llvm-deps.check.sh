#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }
d="$OUT_DIR/llvm-deps"
for f in lib/libz.a lib/libzstd.a include/zlib.h include/zstd.h; do assert_file "$d/$f"; done
finish
