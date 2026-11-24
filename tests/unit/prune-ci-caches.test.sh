#!/usr/bin/env bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
prune="$ROOT_DIR/scripts/prune-ci-caches.sh"
old="$(date -d '-3 days' +%Y%m%d%H%M 2>/dev/null || date -v-3d +%Y%m%d%H%M)"
recent="$(date -d '-2 hours' +%Y%m%d%H%M 2>/dev/null || date -v-2H +%Y%m%d%H%M)"

# scope NAME AGE [stamp] — a cache scope whose files (and stamp, if asked) date from AGE.
scope() {
  mkdir -p "$T/c/$1/linux-amd64/ccache"
  echo x > "$T/c/$1/linux-amd64/ccache/obj"
  if [ "${3:-}" = stamp ]; then touch "$T/c/$1/.last-used"; fi
  find "$T/c/$1" -exec touch -t "$2" {} +
}

# Ample free space: only scopes idle for more than a day go.
scope review-1 "$old" stamp
scope review-2 "$old"
scope review-3 "$recent" stamp
scope review-4 "$recent"
scope review-9 "$old" stamp
scope main "$old"
scope release "$old"
out="$(PRUNE_MIN_FREE_GB=0 bash "$prune" "$T/c" review-9 2>&1)"
assert_eq "$?" 0 "prune succeeds"
[ -d "$T/c/review-1" ] && _fail "stale stamped review scope kept"
[ -d "$T/c/review-2" ] && _fail "stale unstamped review scope kept"
assert_file "$T/c/review-3"
assert_file "$T/c/review-4"
assert_file "$T/c/review-9/linux-amd64/ccache/obj"
assert_file "$T/c/main/linux-amd64/ccache/obj"
assert_file "$T/c/release/linux-amd64/ccache/obj"
assert_contains "$out" "removing review-1"
assert_not_contains "$out" "::warning::"
[ -n "$(find "$T/c/review-9/.last-used" -mmin -5)" ] || _fail "current scope not stamped"

# Low free space: scopes idle past PRUNE_BUSY_MINUTES go too, but not busier ones.
scope review-5 "$recent" stamp
mkdir -p "$T/c/review-6/linux-amd64" && touch "$T/c/review-6/.last-used"
out="$(PRUNE_MIN_FREE_GB=999999999 PRUNE_BUSY_MINUTES=60 bash "$prune" "$T/c" review-new 2>&1)"
[ -d "$T/c/review-5" ] && _fail "idle review scope kept under disk pressure"
assert_file "$T/c/review-6/.last-used"
assert_file "$T/c/review-new/.last-used"
assert_file "$T/c/main/linux-amd64/ccache/obj"
assert_contains "$out" "::warning::only"

assert_fails bash "$prune" "$T/c"
finish
