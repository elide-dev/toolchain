# shellcheck shell=bash
# Minimal assertion helpers for shell unit tests. Source, assert, end with `finish`.
ASSERTIONS=0
FAILURES=0

_fail() {
  FAILURES=$((FAILURES + 1))
  printf '  FAIL: %s\n' "$*" >&2
}

assert_eq() { # ACTUAL EXPECTED [MESSAGE]
  ASSERTIONS=$((ASSERTIONS + 1))
  [ "$1" = "$2" ] || _fail "${3:-assert_eq}: expected [$2], got [$1]"
}

assert_contains() { # HAYSTACK NEEDLE [MESSAGE]
  ASSERTIONS=$((ASSERTIONS + 1))
  case "$1" in *"$2"*) ;; *) _fail "${3:-assert_contains}: [$2] not in [$1]" ;; esac
}

assert_not_contains() { # HAYSTACK NEEDLE [MESSAGE]
  ASSERTIONS=$((ASSERTIONS + 1))
  case "$1" in *"$2"*) _fail "${3:-assert_not_contains}: [$2] found in [$1]" ;; esac
}

assert_ok() { # COMMAND... (run in a subshell so `die` cannot end the test)
  ASSERTIONS=$((ASSERTIONS + 1))
  ( "$@" ) >/dev/null 2>&1 || _fail "expected success: $*"
}

assert_fails() { # COMMAND...
  ASSERTIONS=$((ASSERTIONS + 1))
  if ( "$@" ) >/dev/null 2>&1; then _fail "expected failure: $*"; fi
}

assert_file() { # PATH
  ASSERTIONS=$((ASSERTIONS + 1))
  [ -e "$1" ] || [ -L "$1" ] || _fail "missing: $1"
}

finish() {
  printf '  %d assertions, %d failed\n' "$ASSERTIONS" "$FAILURES"
  [ "$FAILURES" -eq 0 ]
}
