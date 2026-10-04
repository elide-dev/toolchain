#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"

if [ "$HOST_OS" = linux ]; then
  for f in clang clang++ ld.lld llvm-ar llvm-ranlib llvm-nm llvm-readelf llvm-objcopy llvm-strip; do
    assert_file "$STAGE1_DIR/bin/$f"
  done
  assert_contains "$("$STAGE1_DIR/bin/clang" --version)" "clang version $LLVM_VERSION"
  assert_eq "$(readlink "$STAGE1_DIR/sysroot")" "$BUNDLE_DIR/sysroot"
else
  t="$ALL_TARGETS"
  assert_contains "$("$BUNDLE_DIR/bin/clang" --version)" "clang version $LLVM_VERSION"
  assert_file "$BUNDLE_DIR/lib/clang/$LLVM_MAJOR/lib/darwin/libclang_rt.osx.a"
  assert_file "$BUNDLE_DIR/lib/clang/$LLVM_MAJOR/lib/darwin/libclang_rt.profile_osx.a"
  assert_file "$BUNDLE_DIR/bin/ld64.lld"
  assert_file "$BUNDLE_DIR/bin/$t.cfg"
  bad="$(otool -L "$BUNDLE_DIR/bin/clang" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/|@rpath/|@loader_path/|@executable_path/)' || true)"
  assert_eq "$bad" "" "clang links only system dylibs"
  tmp="$(mktemp -d)"; printf '#include <stdio.h>\nint main(void){puts("ok");return 0;}\n' > "$tmp/h.c"
  assert_ok "$BUNDLE_DIR/bin/$t-clang" "$tmp/h.c" -o "$tmp/h"
  assert_eq "$("$tmp/h")" "ok"
  rm -rf "$tmp"
fi
finish
