#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

# version_lt
assert_ok version_lt 2.34 2.36
assert_fails version_lt 2.36 2.34
assert_fails version_lt 2.34 2.34
assert_ok version_lt 2.2.5 2.34

# is_yes
assert_ok is_yes yes
assert_ok is_yes ON
assert_fails is_yes no
assert_fails is_yes ""

# die exits non-zero
assert_fails die "boom"

# stamps
STAMPS_DIR="$(mktemp -d)/stamps"
assert_fails stamp_exists 10-llvm-stage1
stamp_done 10-llvm-stage1
assert_ok stamp_exists 10-llvm-stage1
stamp_clear 10-llvm-stage1
assert_fails stamp_exists 10-llvm-stage1

# fresh_dir
d="$(mktemp -d)/x"; mkdir -p "$d"; touch "$d/stale"
fresh_dir "$d"
assert_eq "$(ls -A "$d")" "" "fresh_dir empties"

# sha256_of
f="$(mktemp)"; printf 'abc' > "$f"
assert_eq "$(sha256_of "$f")" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

# is_elf
assert_fails is_elf "$f"
assert_ok is_elf "$(command -v ls)"

# apply_patches — the directory lives inside this repo's work tree (as real stage dirs do),
# to prove patches apply relative to DIR, not the enclosing repo.
work="$ROOT_DIR/out/test-tmp/patch"; rm -rf "$work"; mkdir -p "$work/src" "$work/patches/demo"
printf 'hello\n' > "$work/src/file.txt"
cat > "$work/patches/demo/0001-greet.patch" <<'EOF'
--- a/file.txt
+++ b/file.txt
@@ -1 +1 @@
-hello
+hello patched
EOF
PATCHES_DIR="$work/patches" apply_patches demo "$work/src"
assert_eq "$(cat "$work/src/file.txt")" "hello patched" "patch applied"
assert_ok env PATCHES_DIR="$work/patches" bash -c "source '$ROOT_DIR/scripts/lib/common.sh'; ROOT_DIR='$ROOT_DIR' apply_patches demo '$work/src'"
assert_eq "$(cat "$work/src/file.txt")" "hello patched" "re-apply is a no-op"
printf 'unrelated\n' > "$work/src/file.txt"
assert_fails env PATCHES_DIR="$work/patches" bash -c "source '$ROOT_DIR/scripts/lib/common.sh'; ROOT_DIR='$ROOT_DIR' apply_patches demo '$work/src'"
rm -rf "$ROOT_DIR/out/test-tmp"

finish
