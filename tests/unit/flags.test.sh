#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
ELIDE_HOST_OS=linux ELIDE_HOST_ARCH=amd64 ELIDE_OUT_DIR="$(mktemp -d)"
export ELIDE_HOST_OS ELIDE_HOST_ARCH ELIDE_OUT_DIR
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"

gnu="$(target_cflags x86_64-unknown-linux-gnu)"
musl="$(target_cflags x86_64-unknown-linux-musl)"
assert_not_contains "$gnu" "pack-relative-relocs" "gnu drops DT_RELR below glibc 2.36"
assert_contains "$musl" "-Wl,-z,pack-relative-relocs" "musl keeps DT_RELR"
assert_contains "$gnu" "-march=x86-64-v3 -mtune=znver3" "arch override applied last"
assert_contains "$gnu" "$(read_flag_file "$ROOT_DIR/cflags.local/base.txt" | awk '{print $1}')" "cflags.local overlay applied"
assert_contains "$(target_exe_ldflags x86_64-unknown-linux-musl)" "-static"
assert_not_contains "$(target_exe_ldflags x86_64-unknown-linux-gnu)" "-static"
assert_not_contains "$(target_ldflags x86_64-unknown-linux-musl)" " -static"

darwin="$(target_cflags arm64-apple-darwin)"
assert_contains "$darwin" "-mcpu=apple-m1" "darwin uses the profile's cpu flag"
assert_not_contains "$darwin" "-march=x86-64" "no linux arch override on darwin"

# The filter only knows the standalone spelling; guard against the profile changing it.
others="$(grep -h 'pack-relative-relocs' "$ROOT_DIR"/cflags/*.txt | sed 's/#.*//' | grep -v '^[[:space:]]*$' | grep -vx -- '-Wl,-z,pack-relative-relocs' || true)"
assert_eq "$others" "" "cflags profile spells DT_RELR only as a standalone token"

GLIBC_FLOOR=2.36
assert_contains "$(target_cflags x86_64-unknown-linux-gnu)" "pack-relative-relocs" "kept when floor >= 2.36"

finish
