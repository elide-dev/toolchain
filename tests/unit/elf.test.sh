#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
T="$(mktemp -d)"
ELIDE_HOST_OS=linux ELIDE_HOST_ARCH=amd64 ELIDE_OUT_DIR="$T/out"
export ELIDE_HOST_OS ELIDE_HOST_ARCH ELIDE_OUT_DIR
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"

cat > "$T/readelf" <<'EOF'
#!/bin/sh
case "$1" in
  -V) cat <<'OUT'
Version symbols section '.gnu.version' contains 3 entries:
Version needs section '.gnu.version_r' contains 2 entries:
 Addr: 0x0000000000000400  Offset: 0x000400  Link: 7 (.dynstr)
  0x0000: Version: 1  File: libc.so.6  Cnt: 4
  0x0010:   Name: GLIBC_2.2.5  Flags: none  Version: 2
  0x0020:   Name: GLIBC_2.34  Flags: none  Version: 3
  0x0030:   Name: GLIBC_ABI_DT_RELR  Flags: none  Version: 4
  0x0038:   Name: GLIBC_ABI_DT_X86_64_PLT  Flags: none  Version: 6
  0x0040: Version: 1  File: libm.so.6  Cnt: 1
  0x0050:   Name: GLIBC_2.38  Flags: none  Version: 5
OUT
  ;;
  -d) printf ' 0x0000000000000001 (NEEDED)  Shared library: [libc.so.6]\n 0x0000000000000001 (NEEDED)  Shared library: [libstdc++.so.6]\n' ;;
  -l) printf '      [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]\n' ;;
esac
EOF
chmod +x "$T/readelf"
READELF="$T/readelf"

assert_eq "$(glibc_needs x | xargs)" "GLIBC_2.2.5 GLIBC_2.34 GLIBC_2.38 GLIBC_ABI_DT_RELR GLIBC_ABI_DT_X86_64_PLT"
v="$(glibc_floor_violations x)"
assert_contains "$v" "GLIBC_2.38"
assert_contains "$v" "GLIBC_ABI_DT_RELR"
assert_contains "$v" "GLIBC_ABI_DT_X86_64_PLT"
assert_not_contains "$v" "GLIBC_2.34"
assert_eq "$(needed_libs x | xargs)" "libc.so.6 libstdc++.so.6"
assert_eq "$(interp_of x)" "/lib64/ld-linux-x86-64.so.2"

rm -rf "$T"
finish
