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

cfg="$(render_cfg x86_64-unknown-linux-gnu)"
assert_contains "$cfg" "--target=x86_64-unknown-linux-gnu"
assert_contains "$cfg" "--sysroot=<CFGDIR>/../sysroot/x86_64-unknown-linux-gnu"
assert_contains "$cfg" "-rtlib=compiler-rt"
assert_contains "$cfg" "-unwindlib=libunwind"
assert_contains "$cfg" "-stdlib=libc++"
assert_contains "$cfg" "-fuse-ld=lld"
assert_not_contains "$cfg" "-static" "cfg never forces static"
dcfg="$(render_cfg arm64-apple-darwin)"
assert_contains "$dcfg" "--target=arm64-apple-macos$MACOS_MIN"
assert_contains "$dcfg" "-mmacosx-version-min=$MACOS_MIN"
assert_contains "$dcfg" "-isystem <CFGDIR>/../sysroot/arm64-apple-darwin/usr/include"
assert_contains "$(render_toolchain_cmake x86_64-unknown-linux-musl)" "set(CMAKE_SYSROOT \"\${_ET_ROOT}/sysroot/x86_64-unknown-linux-musl\")"
assert_contains "$(render_toolchain_cmake arm64-apple-darwin)" "set(CMAKE_OSX_DEPLOYMENT_TARGET \"12.0\""

# install into a prefix whose path contains a space, with fake tools that echo their argv
P="$T/pre fix"; mkdir -p "$P/bin"
for tool in clang clang++ llvm-ar; do
  printf '#!/bin/sh\necho "%s $*"\n' "$tool" > "$P/bin/$tool"; chmod +x "$P/bin/$tool"
done
install_frontends "$P"
assert_file "$P/bin/x86_64-unknown-linux-gnu.cfg"
assert_eq "$(readlink "$P/bin/x86_64-unknown-linux-musl-clang++")" "clang++"
assert_file "$P/share/elide-toolchain/cmake/x86_64-unknown-linux-gnu.cmake"
assert_file "$P/bin/x86_64-linux-musl-gcc"
assert_eq "$(readlink "$P/bin/x86_64-linux-musl-ar")" "x86_64-linux-musl-gcc"
assert_fails test -e "$P/bin/x86_64-linux-gnu-gcc"

# shims delegate with arguments intact (including empty and spaced args), and never add -static
out="$("$P/bin/x86_64-linux-musl-gcc" -c "a b.c" "" -O2)"
assert_eq "$out" "clang -c a b.c  -O2"
assert_contains "$("$P/bin/x86_64-linux-musl-g++" -v)" "clang++ -v"
assert_contains "$("$P/bin/x86_64-linux-musl-ar" rcs x.a)" "llvm-ar rcs x.a"
assert_not_contains "$out" "-static"

rm -rf "$T"
finish
