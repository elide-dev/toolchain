#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
{ [ "$HOST_OS" = linux ] && is_yes "${BUILD_PROPELLER:-yes}"; } || { echo "skip: linux with BUILD_PROPELLER only"; exit 0; }

g="$BUNDLE_DIR/bin/generate_propeller_profiles"
assert_file "$g"
help="$("$g" --helpfull 2>&1)"
assert_contains "$help" "--cc_profile" "propeller flags"
assert_contains "$help" "--dedubb_profile" "DeduBB flags"
needed=" $(needed_libs "$g" | xargs) "
assert_not_contains "$needed" " libelf" "no libelf"
assert_not_contains "$needed" " libcrypto" "no libcrypto"
assert_not_contains "$needed" " libstdc++" "no libstdc++"
assert_not_contains "$needed" " libc++" "static libc++"
assert_eq "$(glibc_floor_violations "$g")" "" "glibc floor"

# Golden profile from upstream's checked-in perf data (no PMU needed).
td="$ROOT_DIR/llvm-propeller/propeller/testdata"
tmp="$(mktemp -d)"
assert_ok "$g" --binary="$td/sample_with_bb_hash.bin" --profile="$td/sample_with_bb_hash.perfdata" \
  --cc_profile="$tmp/cc.txt" --ld_profile="$tmp/ld.txt"
assert_eq "$(grep -v '^h ' "$tmp/cc.txt" 2>/dev/null)" "$(grep -v '^h ' "$td/sample_with_bb_hash_cc_directives.golden.txt")" "cc profile matches upstream golden"
rm -rf "$tmp"
finish
