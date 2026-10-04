#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"

[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }
t="$(bundle_triple_for_libc gnu)"; s="$(sysroot_of "$t")"; cpu="$(triple_cpu "$t")"
for f in usr/lib/libc.so.6 usr/lib/libc.so usr/lib/libc.a usr/lib/crt1.o usr/lib/libc_nonshared.a usr/include/stdio.h "$(glibc_loader "$cpu")"; do
  assert_file "$s/$f"
done
maxdef="$(readelf -V "$s/usr/lib/libc.so.6" | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -1)"
assert_eq "$maxdef" "GLIBC_$GLIBC_FLOOR" "libc.so.6 defines up to the floor"
loader_target="$(readlink "$s/$(glibc_loader "$cpu")" || true)"
assert_not_contains "x$loader_target" "x/" "loader link is relative"
assert_file "$OUT_DIR/glibc-files.txt"
tmp="$(mktemp -d)"
echo 'int main(void){return 0;}' > "$tmp/t.c"
assert_ok gcc --sysroot="$s" "$tmp/t.c" -o "$tmp/t"
assert_ok "$tmp/t"
rm -rf "$tmp"
finish
