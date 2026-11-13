#!/usr/bin/env bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"

r="$BUNDLE_DIR/rust"
vv="$("$r/bin/rustc" -vV)"
assert_eq "$(sed -n 's/^release: //p' <<< "$vv")" "$RUST_VERSION" "bundled rustc release"
assert_eq "$(sed -n 's/^commit-hash: //p' <<< "$vv")" "$RUST_REV" "bundled rustc revision"
assert_eq "$(sed -n 's/^host: //p' <<< "$vv")" "$(rust_host_triple "$HOST_OS" "$HOST_ARCH")" "bundled rustc host"
assert_eq "$("$r/bin/rustc" --print sysroot)" "$r" "rustc finds its sysroot beside itself"
assert_ok "$r/bin/cargo" --version
for t in $ALL_TARGETS; do
  assert_eq "$(find "$r/lib/rustlib/$(rust_triple "$t")/lib" -name 'libstd-*.rlib' | wc -l | xargs)" 1 "std for $t"
done
assert_eq "$(find "$r" -name manifest.in | head -1)" "" "no installer manifests"
assert_fails test -e "$r/share"
for f in rustc/COPYRIGHT rustc/LICENSE-APACHE rustc/LICENSE-MIT cargo/LICENSE-APACHE cargo/LICENSE-MIT cargo/LICENSE-THIRD-PARTY; do
  assert_file "$BUNDLE_DIR/share/elide-toolchain/licenses/rust/$f"
done
finish
