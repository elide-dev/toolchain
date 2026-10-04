#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"

T="$(mktemp -d)"
STAGES="00-sources 10-llvm-stage1 20-libc-gnu 21-libc-musl 30-runtimes 35-mimalloc 36-llvm-deps 40-llvm-stage2 50-components 90-package 95-verify"
mkdir -p "$T/stages"
for s in $STAGES; do
  cat > "$T/stages/$s.sh" <<EOF
stage_main() {
  [ "\${FAIL_STAGE:-}" = "$s" ] && return 1
  echo "$s \$TARGETS" >> "\$ELIDE_TEST_LOG"
}
EOF
done
# shellcheck disable=SC2016
echo 'stage_applies() { [ "$HOST_OS" = darwin ]; }' >> "$T/stages/20-libc-gnu.sh"

run() { # run build.sh with stub stages; log goes to $T/log
  : > "$T/log"
  env ELIDE_STAGES_DIR="$T/stages" ELIDE_OUT_DIR="$T/out" ELIDE_HOST_OS=linux ELIDE_HOST_ARCH=amd64 \
      ELIDE_TEST_LOG="$T/log" "$ROOT_DIR/build.sh" "$@" >/dev/null 2>&1
}
ran() { awk '{print $1}' "$T/log" | xargs; }

run;                       assert_eq "$(ran)" "00-sources 10-llvm-stage1 21-libc-musl 30-runtimes 35-mimalloc 36-llvm-deps 40-llvm-stage2 50-components 90-package 95-verify" "full run (20 skipped by stage_applies)"
assert_file "$T/out/stamps/95-verify.done"
assert_file "$T/out/stamps/20-libc-gnu.done"
run;                       assert_eq "$(ran)" "" "second run is a no-op"
run --from 50-components;  assert_eq "$(ran)" "50-components 90-package 95-verify" "--from"
run --only 30-runtimes;    assert_eq "$(ran)" "30-runtimes" "--only"
run --dry-run --from 90-package; assert_eq "$(ran)" "" "--dry-run executes nothing"

# --from invalidates later stamps, so a failure mid-way leaves them to be rerun
FAIL_STAGE=90-package run --from 50-components; status=$?
assert_eq "$status" 1 "failing stage fails the build"
assert_fails test -f "$T/out/stamps/95-verify.done"
assert_fails test -f "$T/out/stamps/90-package.done"
run;                       assert_eq "$(ran)" "90-package 95-verify" "resume after failure"

run --only 50-components --targets x86_64-unknown-linux-gnu
assert_eq "$(cat "$T/log")" "50-components x86_64-unknown-linux-gnu" "--targets narrows TARGETS"
run --targets aarch64-unknown-linux-gnu; assert_eq "$?" 1 "foreign target rejected"
run --only 99-nope;        assert_eq "$?" 1 "unknown stage rejected"
run --bogus;               assert_eq "$?" 2 "unknown flag rejected"

run --clean --only 00-sources
assert_fails test -f "$T/out/stamps/95-verify.done"

rm -rf "$T"
finish
