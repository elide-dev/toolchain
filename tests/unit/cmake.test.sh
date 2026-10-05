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


# Compiler launchers: ccache (USE_CCACHE auto|yes|no) wins over sccache (USE_SCCACHE=yes).
mkdir -p "$T/bin"
for c in ccache sccache; do printf '#!/bin/sh\n' > "$T/bin/$c"; chmod +x "$T/bin/$c"; done
la() { local a=(); mapfile -t a < <(cmake_launcher_args); printf '%s' "${a[*]}"; }
P="$T/bin"   # only the fake launchers: the host's own ccache/sccache must not count
assert_eq "$(PATH="$P" USE_CCACHE="" USE_SCCACHE="" la)" "-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache" "auto: ccache on PATH"
assert_eq "$(PATH="$P" USE_CCACHE=auto USE_SCCACHE=yes la)" "-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache" "ccache wins"
assert_eq "$(PATH="$P" USE_CCACHE=no USE_SCCACHE=yes la)" "-DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache" "ccache off: sccache"
assert_eq "$(PATH="$P" USE_CCACHE=no USE_SCCACHE=no la)" "" "both off"
rm "$T/bin/ccache"
assert_eq "$(PATH="$P" USE_CCACHE=auto USE_SCCACHE=no la)" "" "auto: no ccache on PATH"
assert_eq "$(PATH="$P" USE_CCACHE=yes USE_SCCACHE=yes la)" "-DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache" "ccache missing: sccache"
printf '#!/bin/sh\n' > "$T/bin/ccache"; chmod +x "$T/bin/ccache"
: > "$T/calls"
PATH="$P:$PATH" USE_CCACHE=yes cmake_target x86_64-unknown-linux-gnu /src /build /prefix
assert_contains "$(head -n 1 "$T/calls")" "-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache" "cmake_target uses the launcher"
# ccache settings: defaults only where the caller set nothing
d="$(env -u CCACHE_BASEDIR -u CCACHE_COMPILERCHECK -u CCACHE_NOHASHDIR -u CCACHE_EXTRAFILES CCACHE_MAXSIZE=5G \
  bash -c "source '$ROOT_DIR/scripts/lib/common.sh'; source '$ROOT_DIR/scripts/lib/cmake.sh'; ROOT_DIR=/r; ccache_defaults; env" | grep '^CCACHE_' | sort | xargs)"
assert_contains "$d" "CCACHE_BASEDIR=/r"
assert_contains "$d" "CCACHE_COMPILERCHECK=content"
assert_contains "$d" "CCACHE_NOHASHDIR=1"
assert_contains "$d" "CCACHE_MAXSIZE=5G" "caller's size kept"
assert_contains "$d" "CCACHE_EXTRAFILES=/r/scripts/lib/frontends.sh:/r/scripts/lib/sanitizers.sh"
assert_eq "$(env -u CCACHE_MAXSIZE bash -c "source '$ROOT_DIR/scripts/lib/common.sh'; source '$ROOT_DIR/scripts/lib/cmake.sh'; ccache_defaults; echo \$CCACHE_MAXSIZE")" 50G

# Link caps
assert_eq "$(LINK_JOBS=3 llvm_link_jobs_args)" "-DLLVM_PARALLEL_LINK_JOBS=3"
assert_eq "$(LINK_JOBS=3 cmake_link_pool_args | xargs)" "-DCMAKE_JOB_POOLS=link=3 -DCMAKE_JOB_POOL_LINK=link"
for f in 10-llvm-stage1 30-runtimes 40-llvm-stage2; do
  assert_contains "$(cat "$ROOT_DIR/scripts/stages/$f.sh")" "llvm_link_jobs_args" "$f caps LLVM links"
done
assert_contains "$(sed -n '/^san_runtimes_base_args()/,/^}/p' "$ROOT_DIR/scripts/lib/sanitizers.sh")" "llvm_link_jobs_args" "stages 31/60 cap links"
assert_contains "$(cat "$ROOT_DIR/scripts/stages/45-propeller.sh")" "cmake_link_pool_args" "propeller uses a link pool"

rm -rf "$T"

finish
