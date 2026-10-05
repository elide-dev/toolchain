#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"

T="$(mktemp -d)"
B="$T/with space/elide-toolchain"
mkdir -p "$B/bin" "$B/share/elide-toolchain/cmake"
cp "$ROOT_DIR/src/elide-toolchain" "$B/bin/elide-toolchain"
chmod +x "$B/bin/elide-toolchain"
touch "$B/bin/x86_64-unknown-linux-gnu.cfg" "$B/bin/x86_64-unknown-linux-musl.cfg"
echo 2026.10.0 > "$B/share/elide-toolchain/VERSION"
H="$B/bin/elide-toolchain"
root="$(cd "$B" && pwd -P)"

assert_eq "$("$H" home)" "$root"
assert_eq "$("$H" version)" "2026.10.0"
assert_eq "$("$H" targets | xargs)" "x86_64-unknown-linux-gnu x86_64-unknown-linux-musl"

mkdir -p "$T/elsewhere"; ln -s "$H" "$T/elsewhere/et"
assert_eq "$("$T/elsewhere/et" home)" "$root" "resolves through symlinks"

sh_out="$("$H" env)"
assert_contains "$sh_out" "export ELIDE_TOOLCHAIN_HOME='$root'"
assert_contains "$sh_out" "export PATH='$root/bin':\"\$PATH\""
assert_not_contains "$sh_out" "CC="

gnu="$("$H" env --target x86_64-unknown-linux-gnu)"
assert_contains "$gnu" "export CC='$root/bin/x86_64-unknown-linux-gnu-clang'"
assert_contains "$gnu" "export CXX='$root/bin/x86_64-unknown-linux-gnu-clang++'"
assert_contains "$gnu" "export PKG_CONFIG_SYSROOT_DIR='$root/sysroot/x86_64-unknown-linux-gnu'"
assert_contains "$gnu" "export CMAKE_TOOLCHAIN_FILE='$root/share/elide-toolchain/cmake/x86_64-unknown-linux-gnu.cmake'"
assert_contains "$gnu" "export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="
# the sh output must be eval-able even with spaces in the path
assert_eq "$(eval "$gnu"; printf '%s' "$CC")" "$root/bin/x86_64-unknown-linux-gnu-clang"

assert_contains "$("$H" env --target x86_64-unknown-linux-musl --static)" "export LDFLAGS='-static'"
assert_fails "$H" env --target x86_64-unknown-linux-gnu --static
assert_contains "$("$H" env --target x86_64-unknown-linux-gnu --static 2>&1 || true)" "only supported for musl"
assert_fails "$H" env --static
assert_fails "$H" env --target aarch64-unknown-linux-gnu
assert_fails "$H" env --format yaml
assert_fails "$H" frobnicate

json="$("$H" env --target x86_64-unknown-linux-musl --format json)"
assert_eq "$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["CC"].endswith("x86_64-unknown-linux-musl-clang"), "PATH" in d)')" "True False"
gh="$("$H" env --target x86_64-unknown-linux-musl --format github)"
assert_contains "$gh" "CC=$root/bin/x86_64-unknown-linux-musl-clang"
assert_not_contains "$gh" "export "

# flags: Propeller, DeduBB and MemProf consumer flags.
touch "$B/bin/arm64-apple-darwin.cfg"
f="$("$H" flags --target x86_64-unknown-linux-gnu memprof-use=/p/app.memprofdata)"
assert_contains "$f" "-fmemory-profile-use=/p/app.memprofdata"
assert_contains "$f" "-Wl,-mllvm,-supports-hot-cold-new"
assert_contains "$f" "-lelidealloc-shim -lmimalloc"
assert_contains "$f" "export ELIDE_RUSTFLAGS='-Clinker-plugin-lto"
assert_contains "$f" "-Clink-arg=-Wl,-mllvm,-supports-hot-cold-new"
assert_not_contains "$f" "export PATH="
assert_eq "$(eval "$f"; printf '%s' "$ELIDE_CFLAGS")" "-flto=thin -gmlt -fdebug-info-for-profiling -fmemory-profile-use=/p/app.memprofdata"
assert_contains "$("$H" flags --target x86_64-unknown-linux-musl memprof-use=/p/a)" "-lelidealloc-shim -static"
assert_contains "$("$H" flags --target x86_64-unknown-linux-gnu memprof-instrument)" "-fmemory-profile -gmlt"
assert_fails "$H" flags --target x86_64-unknown-linux-musl memprof-instrument
assert_contains "$("$H" flags --target x86_64-unknown-linux-musl memprof-instrument 2>&1 || true)" "x86_64-unknown-linux-gnu only"
b="$("$H" flags --target x86_64-unknown-linux-gnu propeller-baseline)"
assert_contains "$b" "-fbasic-block-address-map"
assert_contains "$b" "-Wl,--lto-basic-block-address-map"
u="$("$H" flags --target x86_64-unknown-linux-gnu propeller-use=/c/cc.txt,/c/ld.txt dedubb-apply=/d/x.txt)"
assert_contains "$u" "-Wl,--lto-basic-block-sections=/c/cc.txt"
assert_contains "$u" "-Wl,--symbol-ordering-file=/c/ld.txt"
assert_contains "$u" "-Wl,-mllvm,-dedubb-directives=/d/x.txt"
assert_not_contains "$u" "-fbasic-block-address-map"
d="$("$H" flags --target x86_64-unknown-linux-musl dedubb-apply=/d/x.txt)"
assert_contains "$d" "-Wl,--lto-basic-block-address-map"
assert_contains "$d" "-Wl,-mllvm,-dedubb-directives=/d/x.txt"
assert_fails "$H" flags --target arm64-apple-darwin propeller-baseline
assert_fails "$H" flags --target arm64-apple-darwin dedubb-apply=/d/x.txt
assert_contains "$("$H" flags --target arm64-apple-darwin memprof-use=/p/a)" "-lelidealloc-shim"
assert_fails "$H" flags --target x86_64-unknown-linux-gnu propeller-use=/only-one
assert_fails "$H" flags --target x86_64-unknown-linux-gnu frobnicate
assert_fails "$H" flags memprof-use=/p/a
fj="$("$H" flags --target x86_64-unknown-linux-gnu propeller-baseline --format json)"
assert_eq "$(printf '%s' "$fj" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(d))')" "['ELIDE_CFLAGS', 'ELIDE_CXXFLAGS', 'ELIDE_LDFLAGS', 'ELIDE_RUSTFLAGS']"

# --- sanitizers (spec 2026-10-05 §5.2) ---------------------------------------------------------
G=x86_64-unknown-linux-gnu M=x86_64-unknown-linux-musl
SD="$B/share/elide-toolchain/sanitizers"
mkdir -p "$SD" "$B/lib/clang/23/lib/$G"
for c in $G-asan $G-tsan $G-msan $G-ubsan $M-ubsan; do : > "$SD/$c.cfg"; done
: > "$B/lib/clang/23/lib/$G/libclang_rt.asan.so"
out="$("$H" env --target $G --sanitizer asan --format json 2>"$T/warn")"
q() { printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$1',''))"; }
assert_eq "$(q CC)" "$root/bin/$G-asan-clang"
assert_eq "$(q CXX)" "$root/bin/$G-asan-clang++"
assert_eq "$(q CMAKE_TOOLCHAIN_FILE)" "$root/share/elide-toolchain/cmake/$G-asan.cmake"
assert_eq "$(q CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER)" "$root/bin/$G-asan-clang"
assert_eq "$(q CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS)" "-Zsanitizer=address -Zexternal-clangrt"
assert_eq "$(q ELIDE_SANITIZER)" "asan"
assert_eq "$(q ELIDE_SANITIZER_RUNTIME)" "$root/lib/clang/23/lib/$G/libclang_rt.asan.so"
assert_eq "$(q PKG_CONFIG_SYSROOT_DIR)" "$root/sysroot/$G"
assert_contains "$(cat "$T/warn")" "not instrumented"
assert_eq "$(printf '%s' "$out" | grep -o '"CC"' | wc -l | xargs)" "1" "CC emitted once"
assert_fails "$H" env --target $G --sanitizer msan
assert_contains "$("$H" env --target $G --sanitizer msan 2>&1 || true)" "sanitizer-msan"
assert_fails "$H" env --target $M --sanitizer asan
assert_contains "$("$H" env --target $M --sanitizer asan 2>&1 || true)" "static-only"
assert_fails "$H" env --target $G --sanitizer asan --static
assert_fails "$H" env --target $G --sanitizer bogus
assert_fails "$H" env --sanitizer asan
assert_ok "$H" env --target $M --sanitizer ubsan --static
out="$("$H" env --target $G --sanitizer ubsan --format json)"
assert_not_contains "$out" "RUSTFLAGS"
# add-on installed: farm sysroot for pkg-config; version must match the bundle
mkdir -p "$B/sysroot/$G+msan/usr/lib"
: > "$SD/$G-msan.addon.cfg"
printf '{"sanitizer": "msan", "version": "2026.10.0"}\n' > "$SD/msan.addon.json"
out="$("$H" env --target $G --sanitizer msan --format json)"
assert_eq "$(q PKG_CONFIG_SYSROOT_DIR)" "$root/sysroot/$G+msan"
assert_eq "$(q CC)" "$root/bin/$G-msan-clang"
printf '{"sanitizer": "msan", "version": "1999.1.0"}\n' > "$SD/msan.addon.json"
assert_fails "$H" env --target $G --sanitizer msan
assert_contains "$("$H" env --target $G --sanitizer msan 2>&1 || true)" "1999.1.0"
printf '{"sanitizer": "msan", "version": "2026.10.0"}\n' > "$SD/msan.addon.json"
lst="$("$H" sanitizers --target $G)"
assert_contains "$lst" "msan"
assert_contains "$lst" "installed (required)"
assert_contains "$lst" "absent (recommended)"
assert_not_contains "$("$H" sanitizers --target $M)" "asan"

# addon install from a local archive (+ .sha256), into the bundle root
A="$T/addon"; mkdir -p "$A/elide-toolchain/share/elide-toolchain/sanitizers" "$A/elide-toolchain/sysroot/$G+tsan/usr/lib"
printf '{"sanitizer": "tsan", "version": "2026.10.0"}\n' > "$A/elide-toolchain/share/elide-toolchain/sanitizers/tsan.addon.json"
: > "$A/elide-toolchain/share/elide-toolchain/sanitizers/$G-tsan.addon.cfg"
tar -C "$A" -cJf "$T/tsan.tar.xz" elide-toolchain
assert_fails "$H" addon install sanitizer-tsan --from "$T/tsan.tar.xz"     # no .sha256
(cd "$T" && sha256sum tsan.tar.xz > tsan.tar.xz.sha256)
assert_ok "$H" addon install sanitizer-tsan --from "$T/tsan.tar.xz"
assert_file "$SD/$G-tsan.addon.cfg"
assert_eq "$(q2() { "$H" env --target $G --sanitizer tsan --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["PKG_CONFIG_SYSROOT_DIR"])'; }; q2)" "$root/sysroot/$G+tsan"
printf '{"sanitizer": "tsan", "version": "1999.1.0"}\n' > "$A/elide-toolchain/share/elide-toolchain/sanitizers/tsan.addon.json"
tar -C "$A" -cJf "$T/old.tar.xz" elide-toolchain
assert_fails "$H" addon install sanitizer-tsan --from "$T/old.tar.xz" --no-verify
assert_fails "$H" addon install sanitizer-bogus --from "$T/old.tar.xz"

# a mismatched add-on is refused before anything is extracted
mkdir -p "$T/a2/elide-toolchain/share/elide-toolchain/sanitizers"
printf '{"sanitizer": "asan", "version": "1999.1.0"}\n' > "$T/a2/elide-toolchain/share/elide-toolchain/sanitizers/asan.addon.json"
: > "$T/a2/elide-toolchain/share/elide-toolchain/sanitizers/$G-asan.addon.cfg"
tar -C "$T/a2" -cJf "$T/asan-old.tar.xz" elide-toolchain
assert_fails "$H" addon install sanitizer-asan --from "$T/asan-old.tar.xz" --no-verify
assert_fails test -e "$SD/$G-asan.addon.cfg"
# an archive that is not the named add-on is refused
assert_fails "$H" addon install sanitizer-asan --from "$T/tsan.tar.xz" --no-verify
assert_fails test -e "$SD/asan.addon.json"
# download path (curl/wget on a file:// URL): checksum verified, then extracted
if command -v curl >/dev/null 2>&1; then
  printf '{"sanitizer": "asan", "version": "2026.10.0"}\n' > "$T/a2/elide-toolchain/share/elide-toolchain/sanitizers/asan.addon.json"
  tar -C "$T/a2" -cJf "$T/asan.tar.xz" elide-toolchain
  echo "0000000000000000000000000000000000000000000000000000000000000000  asan.tar.xz" > "$T/asan.tar.xz.sha256"
  assert_fails "$H" addon install sanitizer-asan --from "file://$T/asan.tar.xz"
  assert_contains "$("$H" addon install sanitizer-asan --from "file://$T/asan.tar.xz" 2>&1 || true)" "checksum mismatch"
  assert_fails test -e "$SD/$G-asan.addon.cfg"
  (cd "$T" && sha256sum asan.tar.xz > asan.tar.xz.sha256)
  assert_ok "$H" addon install sanitizer-asan --from "file://$T/asan.tar.xz"
  assert_file "$SD/$G-asan.addon.cfg"
  assert_contains "$("$H" sanitizers --target $G)" "installed (recommended)"
  assert_contains "$("$H" addon install sanitizer-asan --from "file://$T/missing.tar.xz" 2>&1 || true)" "could not download"
fi
# option spellings and unsupported pairs
assert_eq "$("$H" env --target=$G --sanitizer=ubsan --format=json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ELIDE_SANITIZER"])')" "ubsan"
assert_fails "$H" env --target $G --sanitizer hwasan
assert_contains "$("$H" env --target $G --sanitizer hwasan 2>&1 || true)" "not supported for $G"
assert_fails "$H" env --target $G --sanitizer
assert_fails "$H" addon
assert_fails "$H" addon list
assert_fails "$H" sanitizers --target aarch64-unknown-linux-gnu

# doctor --sanitizers on a fake bundle: one generic fake compiler writes programs that print the
# right report for trip-<target>-<san>.c and run clean otherwise.
D="$T/doc/elide-toolchain"; DS="$D/share/elide-toolchain/sanitizers"
mkdir -p "$D/bin" "$DS"
cp "$ROOT_DIR/src/elide-toolchain" "$D/bin/elide-toolchain"; chmod +x "$D/bin/elide-toolchain"
echo 2026.10.0 > "$D/share/elide-toolchain/VERSION"
cat > "$D/bin/fakecc" <<'FAKE'
#!/bin/sh
out="" src=""
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; *.c|*.cpp) src=$1 ;; esac; shift; done
case ${src##*/} in
  trip-*-asan.c) r=heap-buffer-overflow ;; trip-*-tsan.c) r="${FAKE_TSAN:-data race}" ;;
  trip-*-ubsan.c) r="runtime error" ;; *) r="" ;;
esac
if [ -n "$r" ]; then printf '#!/bin/sh\necho "ERROR: %s"\nexit 1\n' "$r" > "$out"; else printf '#!/bin/sh\necho ok\n' > "$out"; fi
chmod +x "$out"
FAKE
chmod +x "$D/bin/fakecc"
for t in $G $M; do
  : > "$D/bin/$t.cfg"
  for d in clang clang++; do ln -s fakecc "$D/bin/$t-$d"; done
done
for c in $G-asan $G-tsan $G-msan $G-hwasan $M-ubsan; do
  : > "$DS/$c.cfg"; for d in clang clang++; do ln -s fakecc "$D/bin/$c-$d"; done
done
doc="$("$D/bin/elide-toolchain" doctor --sanitizers)"; rc=$?
assert_eq "$rc" "0" "doctor --sanitizers passes"
assert_contains "$doc" "ok    $G asan"
assert_contains "$doc" "ok    $G tsan"
assert_contains "$doc" "ok    $M ubsan"
assert_contains "$doc" "skip  $G msan: needs its add-on"
assert_contains "$doc" "skip  $G hwasan"
assert_not_contains "$("$D/bin/elide-toolchain" doctor)" "asan"
doc="$(FAKE_TSAN=nothing "$D/bin/elide-toolchain" doctor --sanitizers)"; rc=$?
assert_eq "$rc" "1" "a sanitizer that does not report fails doctor"
assert_contains "$doc" "FAIL  $G tsan: no 'data race' report"
assert_fails "$D/bin/elide-toolchain" doctor --bogus

rm -rf "$T"
finish
