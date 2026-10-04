#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"

tmp="$(mktemp -d)"
for t in $TARGETS; do
  p="$(target_prefix "$t")"
  defs=() libs=()
  for c in $(enabled_components); do
    found=no
    IFS='|' read -r -a alts <<< "$(component_artifact "$c")"
    for a in "${alts[@]}"; do [ -e "$p/$a" ] && found=yes; done
    assert_eq "$found" yes "$c installed for $t"
    link="$(component_link "$c")"
    if [ -n "$link" ]; then defs+=("-D${link%%|*}"); read -r -a more <<< "${link#*|}"; libs+=("${more[@]}"); fi
  done
  if [ "$(triple_libc "$t")" != musl ]; then defs+=(-DHAVE_MIMALLOC); libs+=(-lmimalloc); fi
  static=(); [ "$(triple_libc "$t")" = musl ] && static=(-static)
  assert_ok "$BUNDLE_DIR/bin/$t-clang" "${defs[@]}" -c "$ROOT_DIR/tests/fixtures/components.c" -o "$tmp/c-$t.o"
  assert_ok "$BUNDLE_DIR/bin/$t-clang++" "${static[@]}" "$tmp/c-$t.o" "${libs[@]}" -lpthread -o "$tmp/c-$t"
  assert_ok "$tmp/c-$t"
done
rm -rf "$tmp"
finish
