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

# A series of adjacent (non-overlapping) patches re-applies as a no-op; '# requires: VAR'
# gates a patch on a knob; unapply_patches restores the pristine tree and is idempotent.
work="$ROOT_DIR/out/test-tmp/series"; rm -rf "$work"; mkdir -p "$work/src" "$work/patches/demo"
printf 'a\nb\nc\nd\ne\nf\ng\n' > "$work/src/f.txt"; printf 'x\n' > "$work/src/g.txt"
cat > "$work/patches/demo/0001-a.patch" <<'EOF'
--- a/f.txt
+++ b/f.txt
@@ -1,3 +1,3 @@
-a
+A
 b
 c
EOF
cat > "$work/patches/demo/0002-g.patch" <<'EOF'
# upstream: none (test)
--- a/f.txt
+++ b/f.txt
@@ -5,3 +5,3 @@
 e
 f
-g
+G
EOF
cat > "$work/patches/demo/0003-gated.patch" <<'EOF'
# requires: DEMO_KNOB
--- a/g.txt
+++ b/g.txt
@@ -1 +1 @@
-x
+X
EOF
series() { # KNOB FUNCTION
  env PATCHES_DIR="$work/patches" DEMO_KNOB="$1" bash -c "source '$ROOT_DIR/scripts/lib/common.sh'; ROOT_DIR='$ROOT_DIR' $2 demo '$work/src'"
}
assert_ok series no apply_patches
assert_eq "$(head -1 "$work/src/f.txt")$(tail -1 "$work/src/f.txt")$(cat "$work/src/g.txt")" "AGx" "series applied, gated patch skipped"
assert_ok series no apply_patches
assert_ok series yes apply_patches
assert_eq "$(cat "$work/src/g.txt")" "X" "gated patch applied when the knob is yes"
assert_ok series yes apply_patches
assert_ok series yes unapply_patches
assert_eq "$(tr -d '\n' < "$work/src/f.txt")$(cat "$work/src/g.txt")" "abcdefgx" "unapply restores the pristine tree"
assert_ok series yes unapply_patches
assert_eq "$(patch_required_var "$work/patches/demo/0003-gated.patch")" "DEMO_KNOB" "requires header parsed"
assert_eq "$(patch_required_var "$work/patches/demo/0002-g.patch")" "" "no requires header"
rm -rf "$ROOT_DIR/out/test-tmp"

# OOM guard: memory-aware parallelism
assert_eq "$(ELIDE_MEM_GB=64 mem_gb)" 64 "ELIDE_MEM_GB overrides detection"
assert_eq "$(ELIDE_CPU_COUNT=12 cpu_count)" 12 "ELIDE_CPU_COUNT overrides detection"
case "$(mem_gb)" in ''|*[!0-9]*) [ -z "$(mem_gb)" ] || _fail "mem_gb not numeric: $(mem_gb)" ;; esac
assert_eq "$(default_jobs 32 16)" 8 "memory-bound: 16 GiB -> 8 jobs"
assert_eq "$(default_jobs 4 64)" 4 "cpu-bound"
assert_eq "$(default_jobs 8 1)" 1 "at least one job"
assert_eq "$(default_jobs 8 0)" 1 "at least one job (0 GiB)"
assert_eq "$(default_jobs 8 '')" 8 "unknown memory: all cpus"
assert_eq "$(default_link_jobs 7)" 1 "< 8 GiB: one link"
assert_eq "$(default_link_jobs 16)" 2
assert_eq "$(default_link_jobs 31)" 3
assert_eq "$(default_link_jobs 256)" 4 "capped at 4"
assert_eq "$(default_link_jobs '')" 2 "unknown memory"


finish
