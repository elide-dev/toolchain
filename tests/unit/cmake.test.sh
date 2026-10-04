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

cat > "$T/cmake" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls"
EOF
chmod +x "$T/cmake"
CMAKE_BIN="$T/cmake"
TOOLCHAIN_ROOT=/tc

cmake_target x86_64-unknown-linux-musl /src /build /prefix -DFOO=1
mapfile -t calls < "$T/calls"
assert_eq "${#calls[@]}" 3 "configure, build, install"
assert_contains "${calls[0]}" "-S /src -B /build -G Ninja"
assert_contains "${calls[0]}" "-DCMAKE_TOOLCHAIN_FILE=/tc/share/elide-toolchain/cmake/x86_64-unknown-linux-musl.cmake"
assert_contains "${calls[0]}" "-DCMAKE_INSTALL_PREFIX=/prefix"
assert_contains "${calls[0]}" "-DCMAKE_INSTALL_LIBDIR=lib"
assert_contains "${calls[0]}" "-DFOO=1"
assert_contains "${calls[0]}" "-static" "musl executables static"
assert_not_contains "${calls[0]}" "CMAKE_PREFIX_PATH" "linux relies on the sysroot"
assert_eq "${calls[1]}" "--build /build -j $JOBS"
assert_eq "${calls[2]}" "--install /build"

: > "$T/calls"
cmake_target x86_64-unknown-linux-gnu /src /build /prefix
assert_not_contains "$(head -1 "$T/calls")" "-static"

rm -rf "$T"
finish
