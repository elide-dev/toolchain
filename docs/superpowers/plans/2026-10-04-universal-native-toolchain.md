# Universal Native Toolchain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the musl-only `build.sh` with a staged build that produces relocatable `elide-toolchain` bundles (linux/darwin × amd64/arm64; Linux with musl + glibc 2.34 sysroots), plus a GitHub Action, mise support, CI and release publishing.

**Architecture:** A thin `build.sh` orchestrator runs numbered stage scripts (`scripts/stages/NN-name.sh`) that share small libraries (`scripts/lib/*.sh`) and per-component recipes (`scripts/components/*.sh`). Versions are recorded in one `versions.env`. Target selection uses clang config files (`bin/<triple>.cfg`), so the same bundle serves musl, glibc and macOS consumers. On Linux, LLVM is built twice: stage 1 with the host compiler, then stage 2 against our own glibc 2.34 sysroot.

**Tech Stack:** bash (build), POSIX sh (shipped helper/shims), CMake + Ninja, LLVM 23.x, glibc 2.34 (built with host GCC), musl 1.2.5 (elide fork), Python 3 (manifest/SBOM generation), TypeScript + bun (GitHub Action), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-04-universal-native-toolchain-design.md` — read it before starting any task; section references (§N) below point into it.

## Global Constraints

- Bundle name/root: `elide-toolchain`; archive `elide-toolchain-<version>-<os>-<arch>.tar.xz` + `.sha256`; `<os>` ∈ `linux|darwin`, `<arch>` ∈ `amd64|arm64`.
- Triples: linux-amd64 → `x86_64-unknown-linux-musl`, `x86_64-unknown-linux-gnu`; linux-arm64 → `aarch64-unknown-linux-musl`, `aarch64-unknown-linux-gnu`; darwin-amd64 → `x86_64-apple-darwin`; darwin-arm64 → `arm64-apple-darwin`.
- `GLIBC_FLOOR=2.34`: no glibc-targeted ELF (including shipped tools) may need a `GLIBC_x.y` > 2.34 or `GLIBC_ABI_DT_RELR`.
- `MACOS_MIN=12.0`: every Mach-O in the bundle and every smoke output has `minos` ≤ 12.0.
- LLVM stays on the `llvmorg-23.x` line; musl stays on the `elide-v1.2.5` fork branch; glibc comes from `release/2.34/master`.
- March/mtune: amd64 `x86-64-v3`/`znver3`; linux arm64 `armv8.2-a+crypto+crc+dotprod`/`generic`; darwin uses the `cflags/` profile's own `-march`/`-mcpu`.
- The bundle must be relocatable: no absolute build paths in text files, symlinks, or cfgs; it must still work after being moved to a path containing a space.
- Build scripts are bash ≥ 4 (`build.sh` enforces it; macOS CI installs Homebrew bash). No `sudo` anywhere in the build. Nothing outside `out/` and `dist/` gets written (both git-ignored).
- The shipped helper (`bin/elide-toolchain`) and shims are POSIX `sh` (no bashisms) and must work on Linux and macOS.
- Clean break: no `1.2.5/` directory, no `MUSL_HOME`, no versioned `mimalloc-X.Y` dirs, no musl-cross-make.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A bundle extracted under a path containing spaces**: `<CFGDIR>` cfgs, the helper, shims and CMake toolchain files must all still work. Pinned by the relocatability check in Task 19, which copies the bundle to `…/reloc test/` and reruns the smoke tests.
2. **The darwin bundle on a clean Mac with no Homebrew**: LLVM must not link Homebrew `libzstd`/`libxml2` dylibs. Pinned by the `otool -L` checks in Task 10 (stage check) and Task 19 (`check_darwin_dylibs`), plus `LLVM_ENABLE_ZSTD=OFF`/`LIBXML2=OFF` in Task 10.
3. **Build-path leaks**: `.pc` files, libtool `.la` files, musl's absolute `ld-musl` symlink, and OpenSSL's `OPENSSLDIR` must not carry the builder's path. Pinned by `relocate_prefix` (Task 18) and `check_no_build_paths` (Task 19); musl's loader link is fixed in Task 14.
4. **Resuming after a failed stage** (`--from X`) when a previous run left stale build dirs: later stamps must be invalidated, and each stage must wipe its own build dir first. Pinned by orchestrator unit tests (Task 4); every stage does `rm -rf` on its build dir.
5. **A consumer asking for `--static` on a glibc target, or compiling with `-Werror`**: the helper must refuse glibc static with a clear error, and cfg flags must not trigger unused-argument warnings. Pinned by the helper unit tests (Task 17) and `check_werror` (Task 19).

---

## File Structure

```
build.sh                         # REWRITE: orchestrator (Task 4)
versions.env                     # NEW: all versions/pins/floors (Task 3, values filled in Tasks 5, 7)
vars.sh                          # REWRITE: component toggles + local knobs (Task 4)
.gitignore                       # MODIFY: out/, dist/ (Task 3)
.gitmodules                      # MODIFY: +glibc, -musl-cross-make (Tasks 1, 5)
config.mak, latest, musl.sbom.json   # DELETE (Task 5 / Task 22)
scripts/lib/env.sh               # NEW: loads libs + config, computes dirs (Task 4)
scripts/lib/common.sh            # NEW: log/die/stamps/patches/version_lt (Task 3)
scripts/lib/platform.sh          # NEW: host detection, triple mapping (Task 3)
scripts/lib/flags.sh             # NEW: cflags profile per triple + glibc filter (Task 6)
scripts/lib/cmake.sh             # NEW: cmake_target helper (Task 6)
scripts/lib/frontends.sh         # NEW: cfgs, triple symlinks, shims, cmake toolchain files (Task 9)
scripts/lib/components.sh        # NEW: component registry, stage_source, target_env (Task 13)
scripts/stages/00-sources.sh … 95-verify.sh   # NEW (Tasks 7–19)
scripts/components/<name>.sh     # NEW: one recipe per component (Tasks 13, 16)
scripts/verify/elf.sh            # NEW: ELF floor/interp helpers (Task 15)
scripts/verify/checks.sh         # NEW: verification checks (Task 19)
scripts/bump-submodules.sh       # NEW: move submodules to latest stable tags (Task 5)
scripts/check-versions.sh        # NEW: *_REV vs submodule status (Task 5)
scripts/gen-manifest.py          # NEW: manifest.json + sbom.cdx.json (Task 18)
src/elide-toolchain              # NEW: helper CLI, POSIX sh (Task 17)
src/shims/musl-gcc               # NEW: GCC-named shim, POSIX sh (Task 9)
src/patches/glibc/*.patch        # NEW: as found by spike (Task 1)
src/mimalloc-musl-glue.c         # KEEP
tests/lib/assert.sh              # NEW (Task 3)
tests/run.sh                     # NEW (Task 3)
tests/unit/*.test.sh             # NEW (per task)
tests/stages/*.check.sh          # NEW: post-condition checks per stage
tests/fixtures/{hello.c,hello.cpp,components.c}   # NEW (Tasks 12, 16)
action/{action.yml,lib.ts,main.ts,lib.test.ts,package.json,dist/main.js}   # REWRITE (Task 20)
.github/workflows/{job.build.yml,on.pr.yml,on.push.yml,on.release.yml,job.action-e2e.yml}  # REWRITE/NEW (Task 21)
docs/notes/mise-assets.md        # NEW: result of mise check (Task 2)
README.md                        # REWRITE (Task 22)
```

The old `build.sh` moves to `scripts/legacy/build.sh` in Task 4 (as a porting reference) and is deleted in Task 22.

**Directory variables** (defined in `scripts/lib/env.sh`, used everywhere):

| Var | Value |
|---|---|
| `ROOT_DIR` | repo root |
| `HOST_OS` / `HOST_ARCH` | `linux|darwin` / `amd64|arm64` (overridable via `ELIDE_HOST_OS`/`ELIDE_HOST_ARCH` for tests) |
| `OUT_DIR` | `$ROOT_DIR/out/$HOST_OS-$HOST_ARCH` (override `ELIDE_OUT_DIR`) |
| `BUNDLE_DIR` | `$OUT_DIR/elide-toolchain` |
| `STAGE1_DIR` | `$OUT_DIR/stage1` |
| `BUILD_DIR` | `$OUT_DIR/build` |
| `STAMPS_DIR` | `$OUT_DIR/stamps` |
| `CACHE_DIR` | `$ROOT_DIR/out/cache` |
| `DIST_DIR` | `$ROOT_DIR/dist` |
| `TOOLCHAIN_ROOT` | toolchain whose `bin/<triple>-clang` builds target code; default `$BUNDLE_DIR`, set to `$STAGE1_DIR` by stages 35/36 |
| `TARGETS` | space-separated triples (default `bundle_triples $HOST_OS $HOST_ARCH`, narrowed by `--targets`) |
| `JOBS` | CPU count |
| `LLVM_MAJOR` | `${LLVM_VERSION%%.*}` |

---

## Phase A — Risk spikes

### Task 1: Spike — build glibc 2.34 with host GCC 15

This is the highest-risk unknown (§4.2). Prove it first, before building anything around it. The configure line and patches found here become stage 20 in Task 8.

**Files:**
- Modify: `.gitmodules` (add `glibc`)
- Create: `glibc` (submodule)
- Create: `src/patches/glibc/NNNN-*.patch` (only if needed)
- Create: `docs/notes/glibc-2.34-gcc15.md`

**Interfaces:**
- Produces: `src/patches/glibc/*.patch` (applied in numeric order by `apply_patches glibc …` in Task 8); the exact working configure flags recorded in `docs/notes/glibc-2.34-gcc15.md`.

- [ ] **Step 1: Add the glibc submodule on the 2.34 release branch**

```bash
cd /home/sam/workspace/toolchains/native
git submodule add -b release/2.34/master --depth 1 https://sourceware.org/git/glibc.git glibc
git config -f .gitmodules submodule.glibc.shallow true
git config -f .gitmodules submodule.glibc.ignore dirty
git -C glibc log --oneline -1
```
Expected: one commit line from the `release/2.34/master` branch.

- [ ] **Step 2: Fetch kernel headers into a scratch sysroot**

```bash
SPIKE=out/spike; mkdir -p "$SPIKE"
V=$(curl -fsSL https://www.kernel.org/releases.json | python3 -c 'import json,sys; r=[x["version"] for x in json.load(sys.stdin)["releases"] if x["moniker"]=="longterm"]; print(sorted(r, key=lambda v: [int(p) for p in v.split(".")])[-1])')
echo "longterm kernel: $V"
curl -fsSL -o "$SPIKE/linux-$V.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/v${V%%.*}.x/linux-$V.tar.xz"
tar -C "$SPIKE" -xJf "$SPIKE/linux-$V.tar.xz"
make -C "$SPIKE/linux-$V" ARCH=x86 INSTALL_HDR_PATH="$PWD/$SPIKE/sysroot/usr" headers_install
ls "$SPIKE/sysroot/usr/include/linux/version.h"
```
Expected: `version.h` exists. Record `$V` and `sha256sum "$SPIKE/linux-$V.tar.xz"` in the notes file (Task 7 uses them).

- [ ] **Step 3: Configure and build glibc with the spec's flags**

```bash
rm -rf "$SPIKE/glibc-build"; mkdir -p "$SPIKE/glibc-build"; cd "$SPIKE/glibc-build"
env -u CFLAGS -u CXXFLAGS -u LDFLAGS ../../../glibc/configure \
  CC=gcc CXX=g++ CFLAGS="-O2 -std=gnu11" \
  --prefix=/usr --libdir=/usr/lib --libexecdir=/usr/lib libc_cv_slibdir=/usr/lib \
  --with-headers="$OLDPWD/$SPIKE/sysroot/usr/include" \
  --enable-kernel=4.18 --enable-stack-protector=strong --enable-bind-now \
  --disable-werror --disable-profile 2>&1 | tee configure.log
make -j"$(nproc)" 2>&1 | tee make.log | tail -20
cd -
```
Expected: either success, or a compile error to fix in Step 4.

- [ ] **Step 4: Fix each failure with an upstream backport (repeat until `make` succeeds)**

For each error in `make.log`:

```bash
# 1. Identify the failing file/symbol, e.g. "misc/foo.c: error: ...".
grep -n -m5 'error:' out/spike/glibc-build/make.log
# 2. Find the upstream fix on a newer release branch (fixes for new GCC are usually backported there):
git -C glibc fetch --depth=2000 origin release/2.35/master release/2.36/master release/2.37/master
git -C glibc log --oneline FETCH_HEAD -S'<distinctive identifier from the error>' -- <failing path>
# 3. Export it as a numbered patch and verify it applies to 2.34:
n=$(printf '%04d' $(( $(ls src/patches/glibc 2>/dev/null | wc -l) + 1 )))
mkdir -p src/patches/glibc
git -C glibc format-patch -1 <sha> --stdout > "src/patches/glibc/$n-$(git -C glibc log -1 --format=%f <sha>).patch"
git -C glibc apply --check "../src/patches/glibc/$n-"*.patch && git -C glibc apply "../src/patches/glibc/$n-"*.patch
```
If you can't find a backport, write a minimal patch by hand: `git -C glibc diff > src/patches/glibc/NNNN-describe-fix.patch`. Then rerun Step 3's `make`. Once it succeeds, restore the submodule with `git -C glibc checkout .` (the patches live in `src/patches/glibc/`).

- [ ] **Step 5: Install and check the symbol-version floor**

```bash
make -C out/spike/glibc-build install DESTDIR="$PWD/out/spike/sysroot" >/dev/null
readelf -V out/spike/sysroot/usr/lib/libc.so.6 | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -1
ls -l out/spike/sysroot/lib64/ld-linux-x86-64.so.2 out/spike/sysroot/usr/lib/ld-linux-x86-64.so.2
echo 'int main(void){return 0;}' | gcc -x c - --sysroot="$PWD/out/spike/sysroot" -o out/spike/t && out/spike/t && echo LINK-OK
```
Expected: `GLIBC_2.34`; the loader exists in `usr/lib` (and `lib64` if glibc created its rtld link); `LINK-OK`. Note in the notes file whether `lib64/ld-linux-x86-64.so.2` was created by glibc or is missing. Task 8 creates it if missing.

- [ ] **Step 6: Write the findings note**

Create `docs/notes/glibc-2.34-gcc15.md` containing: the host GCC/binutils versions (`gcc --version | head -1`, `ld --version | head -1`), the final configure line, each patch with a one-line reason and upstream commit, the kernel `$V` and sha256 from Step 2, and the build time (`time make` from Step 3).

- [ ] **Step 7: Commit**

```bash
git add .gitmodules glibc src/patches/glibc docs/notes/glibc-2.34-gcc15.md
git commit -m "chore: add glibc 2.34 submodule; record GCC 15 build spike

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Spike — mise `github:` backend asset matching

**Files:**
- Create: `docs/notes/mise-assets.md`

**Interfaces:**
- Produces: the exact mise snippet README.md uses (Task 22) and the asset naming confirmation that Task 18 relies on.

- [ ] **Step 1: Read mise's asset matcher source for the installed version**

```bash
S=$(mktemp -d); git clone --depth 1 --branch "v$(mise --version | awk '{print $1}')" https://github.com/jdx/mise "$S/mise" 2>/dev/null \
  || git clone --depth 1 https://github.com/jdx/mise "$S/mise"
grep -rnE '"(darwin|macos|amd64|x86_64|x64|aarch64|arm64)"' "$S/mise/src/backend" | head -40
grep -rnE 'tar\.xz|\.txz' "$S/mise/src" | head -10
grep -rn 'asset_pattern\|strip_components\|bin_path' "$S/mise/docs/dev-tools/backends/github.md" | head -20
```

- [ ] **Step 2: Decide**

Apply this rule:
- If the matcher treats `darwin` as macOS, `amd64` as x64, and recognises `.tar.xz`, the default works. Record the plain snippet as the README snippet:
  ```toml
  [tools]
  "github:elide-dev/toolchain" = { version = "2026.10.0", bin_path = "elide-toolchain/bin" }
  ```
- Otherwise, record the explicit per-platform form, using the option names exactly as `docs/dev-tools/backends/github.md` spells them, e.g.:
  ```toml
  [tools."github:elide-dev/toolchain"]
  version = "2026.10.0"
  bin_path = "elide-toolchain/bin"
  [tools."github:elide-dev/toolchain".platforms]
  linux-x64   = { asset_pattern = "elide-toolchain-*-linux-amd64.tar.xz" }
  linux-arm64 = { asset_pattern = "elide-toolchain-*-linux-arm64.tar.xz" }
  macos-x64   = { asset_pattern = "elide-toolchain-*-darwin-amd64.tar.xz" }
  macos-arm64 = { asset_pattern = "elide-toolchain-*-darwin-arm64.tar.xz" }
  ```
- If the docs say mise auto-strips a single top-level directory, drop `bin_path` and record that instead.

- [ ] **Step 3: Write `docs/notes/mise-assets.md`**

Include the mise version inspected, the file/line references from Step 1, the decision, and the final snippet.

- [ ] **Step 4: Commit**

```bash
git add docs/notes/mise-assets.md
git commit -m "docs: record mise github backend asset matching

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Phase B — Build framework

### Task 3: Test harness, common helpers, platform mapping, versions.env

**Files:**
- Create: `tests/lib/assert.sh`, `tests/run.sh`, `tests/unit/common.test.sh`, `tests/unit/platform.test.sh`
- Create: `scripts/lib/common.sh`, `scripts/lib/platform.sh`, `versions.env`
- Modify: `.gitignore`

**Interfaces:**
- Produces (common.sh): `log MSG`, `warn MSG`, `die MSG` (exit 1), `is_yes VAL`, `require_cmd CMD…`, `version_lt A B`, `cpu_count`, `sha256_of FILE` (prints the hex digest), `is_elf FILE`, `stamp_path STAGE`, `stamp_exists STAGE`, `stamp_done STAGE`, `stamp_clear STAGE`, `fresh_dir DIR`, `apply_patches COMPONENT DIR` (reads `${PATCHES_DIR:-$ROOT_DIR/src/patches}/COMPONENT/*.patch`).
- Produces (platform.sh): `detect_host_os`, `detect_host_arch`, `bundle_triples OS ARCH`, `triple_cpu T`, `triple_libc T` (`musl|gnu|darwin`), `triple_os T` (`linux|darwin`), `cpu_to_arch CPU`, `kernel_arch CPU`, `glibc_loader CPU`, `musl_loader CPU`, `musl_gcc_prefix T`, `rust_triple T`, `bundle_triple_for_libc LIBC` (searches `$ALL_TARGETS`), `sysroot_of T`, `march_for T`, `mtune_for T`, `arch_flags T`.
- Produces (versions.env): `TOOLCHAIN_NAME`, `TOOLCHAIN_VERSION`, `GLIBC_FLOOR`, `GLIBC_BRANCH`, `GLIBC_ENABLE_KERNEL`, `MACOS_MIN`, `MARCH_AMD64`, `MTUNE_AMD64`, `MARCH_ARM64`, `MTUNE_ARM64`, `LLVM_PROJECTS_LINUX`, `LLVM_PROJECTS_DARWIN`, `MUSL_VERSION`.

- [ ] **Step 1: Write the assertion helpers and runner**

`tests/lib/assert.sh`:
```bash
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
```

`tests/run.sh`:
```bash
#!/usr/bin/env bash
# Run shell unit tests (tests/unit/*.test.sh) and shellcheck.
# Usage: tests/run.sh [name-filter]
set -uo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export ROOT_DIR
filter="${1:-}"
failed=0

for t in "$ROOT_DIR"/tests/unit/*.test.sh; do
  [ -e "$t" ] || continue
  case "$(basename "$t")" in *"$filter"*) ;; *) continue ;; esac
  echo "$(basename "$t")"
  bash "$t" || failed=1
done

if [ -z "$filter" ] && command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck"
  cd "$ROOT_DIR" || exit 1
  bash_files=$(ls build.sh scripts/*.sh scripts/lib/*.sh scripts/stages/*.sh scripts/components/*.sh \
    scripts/verify/*.sh tests/run.sh tests/lib/*.sh tests/unit/*.sh tests/stages/*.sh 2>/dev/null)
  # shellcheck disable=SC2086
  shellcheck -x $bash_files || failed=1
  sh_files=$(ls src/elide-toolchain src/shims/musl-gcc 2>/dev/null || true)
  # shellcheck disable=SC2086
  [ -z "$sh_files" ] || shellcheck -s sh $sh_files || failed=1
fi
exit "$failed"
```
Run: `chmod +x tests/run.sh`

- [ ] **Step 2: Write failing tests for common.sh**

`tests/unit/common.test.sh`:
```bash
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
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `tests/run.sh common`
Expected: errors such as `scripts/lib/common.sh: No such file or directory` and failed assertions.

- [ ] **Step 4: Implement `scripts/lib/common.sh`**

```bash
# shellcheck shell=bash
# Shared build helpers: logging, stamps, patches, version comparison.

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

is_yes() { case "${1:-}" in yes|YES|on|ON|true|1) return 0 ;; *) return 1 ;; esac; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# version_lt A B — true when version A sorts strictly before version B.
version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

cpu_count() {
  if command -v nproc >/dev/null 2>&1; then nproc; else sysctl -n hw.ncpu; fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

is_elf() {
  [ -f "$1" ] && [ "$(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' \n')" = '177ELF' ]
}

stamp_path()   { printf '%s/%s.done\n' "$STAMPS_DIR" "$1"; }
stamp_exists() { [ -f "$(stamp_path "$1")" ]; }
stamp_done()   { mkdir -p "$STAMPS_DIR"; date -u +%Y-%m-%dT%H:%M:%SZ > "$(stamp_path "$1")"; }
stamp_clear()  { rm -f "$(stamp_path "$1")"; }

# fresh_dir DIR — remove and recreate a directory; every stage starts from a clean build dir.
fresh_dir() { rm -rf "$1"; mkdir -p "$1"; }

# apply_patches COMPONENT DIR — apply PATCHES_DIR/COMPONENT/*.patch to DIR, idempotently.
# GIT_CEILING_DIRECTORIES stops git from discovering the enclosing repo, so patch paths are
# always relative to DIR (a submodule root, or a source copy under out/).
apply_patches() {
  local component="$1" dir="$2" patch_dir patch
  patch_dir="${PATCHES_DIR:-$ROOT_DIR/src/patches}/$component"
  [ -d "$patch_dir" ] || return 0
  for patch in "$patch_dir"/*.patch; do
    [ -e "$patch" ] || continue
    if (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$dir")" git apply --check "$patch" 2>/dev/null); then
      log "applying $(basename "$patch") to $component"
      (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$dir")" git apply "$patch")
    elif (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$dir")" git apply --reverse --check "$patch" 2>/dev/null); then
      log "already applied: $(basename "$patch")"
    else
      die "cannot apply $patch to $dir"
    fi
  done
  return 0
}
```

- [ ] **Step 5: Run the common tests and confirm they pass**

Run: `tests/run.sh common`
Expected: `0 failed`.

- [ ] **Step 6: Write `versions.env`**

```bash
# shellcheck shell=bash disable=SC2034
# Single source of truth for toolchain versions, pins and floors. Sourced by build.sh,
# read by scripts/gen-manifest.py. Component pins are generated by scripts/bump-submodules.sh.

TOOLCHAIN_NAME=elide-toolchain
TOOLCHAIN_VERSION=2026.10.0

# Floors
GLIBC_FLOOR=2.34
GLIBC_BRANCH=release/2.34/master
GLIBC_ENABLE_KERNEL=4.18
MACOS_MIN=12.0

# Code generation (Linux; darwin uses the cflags profile's own -march/-mcpu)
MARCH_AMD64=x86-64-v3
MTUNE_AMD64=znver3
MARCH_ARM64=armv8.2-a+crypto+crc+dotprod
MTUNE_ARM64=generic

# LLVM projects (lldb intentionally excluded; bolt is ELF-only)
LLVM_PROJECTS_LINUX="clang;lld;bolt;polly"
LLVM_PROJECTS_DARWIN="clang;lld;polly"

# libc
MUSL_VERSION=1.2.5
LLVM_VERSION=23.1.0
```

- [ ] **Step 7: Write failing tests for platform.sh**

`tests/unit/platform.test.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/platform.sh
source "$ROOT_DIR/scripts/lib/platform.sh"
# shellcheck source=versions.env
source "$ROOT_DIR/versions.env"

assert_eq "$(bundle_triples linux amd64)" "x86_64-unknown-linux-musl x86_64-unknown-linux-gnu"
assert_eq "$(bundle_triples linux arm64)" "aarch64-unknown-linux-musl aarch64-unknown-linux-gnu"
assert_eq "$(bundle_triples darwin amd64)" "x86_64-apple-darwin"
assert_eq "$(bundle_triples darwin arm64)" "arm64-apple-darwin"
assert_fails bundle_triples windows amd64

assert_eq "$(triple_cpu aarch64-unknown-linux-gnu)" aarch64
assert_eq "$(triple_libc x86_64-unknown-linux-musl)" musl
assert_eq "$(triple_libc x86_64-unknown-linux-gnu)" gnu
assert_eq "$(triple_libc arm64-apple-darwin)" darwin
assert_eq "$(triple_os arm64-apple-darwin)" darwin
assert_eq "$(triple_os aarch64-unknown-linux-musl)" linux
assert_fails triple_libc x86_64-pc-windows-msvc

assert_eq "$(cpu_to_arch x86_64)" amd64
assert_eq "$(cpu_to_arch arm64)" arm64
assert_eq "$(kernel_arch x86_64)" x86
assert_eq "$(kernel_arch aarch64)" arm64
assert_eq "$(glibc_loader x86_64)" lib64/ld-linux-x86-64.so.2
assert_eq "$(glibc_loader aarch64)" lib/ld-linux-aarch64.so.1
assert_eq "$(musl_loader x86_64)" lib/ld-musl-x86_64.so.1
assert_eq "$(musl_gcc_prefix x86_64-unknown-linux-musl)" x86_64-linux-musl
assert_eq "$(rust_triple arm64-apple-darwin)" aarch64-apple-darwin
assert_eq "$(rust_triple x86_64-unknown-linux-gnu)" x86_64-unknown-linux-gnu

ALL_TARGETS="x86_64-unknown-linux-musl x86_64-unknown-linux-gnu"
assert_eq "$(bundle_triple_for_libc gnu)" x86_64-unknown-linux-gnu
assert_eq "$(bundle_triple_for_libc musl)" x86_64-unknown-linux-musl
assert_fails bundle_triple_for_libc darwin

BUNDLE_DIR=/b
assert_eq "$(sysroot_of x86_64-unknown-linux-gnu)" /b/sysroot/x86_64-unknown-linux-gnu

assert_eq "$(arch_flags x86_64-unknown-linux-gnu)" "-march=x86-64-v3 -mtune=znver3"
assert_eq "$(arch_flags aarch64-unknown-linux-musl)" "-march=armv8.2-a+crypto+crc+dotprod -mtune=generic"
assert_eq "$(arch_flags arm64-apple-darwin)" ""

case "$(uname -s)" in Linux) assert_eq "$(detect_host_os)" linux ;; Darwin) assert_eq "$(detect_host_os)" darwin ;; esac

finish
```

- [ ] **Step 8: Run and confirm failure**

Run: `tests/run.sh platform` → Expected: fails (platform.sh missing).

- [ ] **Step 9: Implement `scripts/lib/platform.sh`**

```bash
# shellcheck shell=bash
# Host detection and target-triple mapping.

detect_host_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo darwin ;;
    *) die "unsupported host OS: $(uname -s)" ;;
  esac
}

detect_host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unsupported host arch: $(uname -m)" ;;
  esac
}

# bundle_triples OS ARCH — target triples contained in the bundle for OS/ARCH.
bundle_triples() {
  case "$1-$2" in
    linux-amd64)  echo "x86_64-unknown-linux-musl x86_64-unknown-linux-gnu" ;;
    linux-arm64)  echo "aarch64-unknown-linux-musl aarch64-unknown-linux-gnu" ;;
    darwin-amd64) echo "x86_64-apple-darwin" ;;
    darwin-arm64) echo "arm64-apple-darwin" ;;
    *) die "unsupported bundle: $1-$2" ;;
  esac
}

triple_cpu() { printf '%s\n' "${1%%-*}"; }

triple_libc() {
  case "$1" in
    *-linux-musl) echo musl ;;
    *-linux-gnu) echo gnu ;;
    *-apple-darwin) echo darwin ;;
    *) die "unknown triple: $1" ;;
  esac
}

triple_os() {
  local libc
  libc="$(triple_libc "$1")" || return 1
  if [ "$libc" = darwin ]; then echo darwin; else echo linux; fi
}

cpu_to_arch() {
  case "$1" in
    x86_64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unknown cpu: $1" ;;
  esac
}

kernel_arch() {
  case "$1" in
    x86_64) echo x86 ;;
    aarch64) echo arm64 ;;
    *) die "no kernel arch for cpu $1" ;;
  esac
}

# glibc_loader CPU — sysroot-relative path of the glibc dynamic loader (PT_INTERP minus leading /).
glibc_loader() {
  case "$1" in
    x86_64) echo lib64/ld-linux-x86-64.so.2 ;;
    aarch64) echo lib/ld-linux-aarch64.so.1 ;;
    *) die "no glibc loader for cpu $1" ;;
  esac
}

musl_loader() { printf 'lib/ld-musl-%s.so.1\n' "$1"; }

# musl_gcc_prefix TRIPLE — GCC-style prefix GraalVM looks for, e.g. x86_64-linux-musl.
musl_gcc_prefix() { printf '%s-linux-musl\n' "$(triple_cpu "$1")"; }

rust_triple() {
  case "$1" in
    arm64-apple-darwin) echo aarch64-apple-darwin ;;
    *) echo "$1" ;;
  esac
}

# bundle_triple_for_libc LIBC — the bundle triple (from $ALL_TARGETS) using LIBC (musl|gnu).
bundle_triple_for_libc() {
  local t
  for t in $ALL_TARGETS; do
    if [ "$(triple_libc "$t")" = "$1" ]; then echo "$t"; return 0; fi
  done
  return 1
}

sysroot_of() { printf '%s/sysroot/%s\n' "$BUNDLE_DIR" "$1"; }

march_for() {
  case "$1" in
    x86_64-unknown-linux-*) echo "$MARCH_AMD64" ;;
    aarch64-unknown-linux-*) echo "$MARCH_ARM64" ;;
    *) echo "" ;;
  esac
}

mtune_for() {
  case "$1" in
    x86_64-unknown-linux-*) echo "$MTUNE_AMD64" ;;
    aarch64-unknown-linux-*) echo "$MTUNE_ARM64" ;;
    *) echo "" ;;
  esac
}

# arch_flags TRIPLE — -march/-mtune for Linux triples; empty for darwin (cflags profile decides).
arch_flags() {
  local m
  m="$(march_for "$1")"
  if [ -n "$m" ]; then printf -- '-march=%s -mtune=%s\n' "$m" "$(mtune_for "$1")"; else echo ""; fi
}
```

- [ ] **Step 10: Run all unit tests**

Run: `tests/run.sh`
Expected: both test files report `0 failed`; shellcheck prints nothing for the files that exist.

- [ ] **Step 11: Ignore build outputs**

Append to `.gitignore`:
```
out/
dist/
```

- [ ] **Step 12: Commit**

```bash
git add tests scripts/lib/common.sh scripts/lib/platform.sh versions.env .gitignore
git commit -m "feat: build test harness, common helpers, platform mapping, versions.env

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Orchestrator (`build.sh`), environment loader, `vars.sh`

**Files:**
- Move: `build.sh` → `scripts/legacy/build.sh` (reference while porting; deleted in Task 22)
- Create: `build.sh`, `scripts/lib/env.sh`, `tests/unit/orchestrator.test.sh`
- Rewrite: `vars.sh`

**Interfaces:**
- Consumes: Task 3 helpers.
- Produces: the stage contract every later task implements. A stage file `scripts/stages/<NN-name>.sh` defines `stage_main` (required) and optionally `stage_applies` (return non-zero to skip on this host). Stages run in a subshell with `scripts/lib/env.sh` already sourced, so they may `export` freely. Also produces the directory variables in the File Structure table, plus `ALL_TARGETS` and `TARGETS`.
- `vars.sh` toggles: `BUILD_<COMPONENT>` (yes/no), `MUSL_USE_MIMALLOC`, `MUSL_USE_LTO`, `MIMALLOC_SECURE`, `MIMALLOC_GUARDED`, `USE_SCCACHE`, `REQUIRE_CONTAINER_CHECKS`.

- [ ] **Step 1: Move the legacy script**

```bash
mkdir -p scripts/legacy && git mv build.sh scripts/legacy/build.sh
```

- [ ] **Step 2: Write the failing orchestrator test**

`tests/unit/orchestrator.test.sh`:
```bash
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
```

- [ ] **Step 3: Run and confirm failure**

Run: `tests/run.sh orchestrator` → Expected: FAIL (no `build.sh`).

- [ ] **Step 4: Implement `scripts/lib/env.sh`**

```bash
# shellcheck shell=bash
# Load libraries and configuration; compute build directories. Sourced by build.sh
# (and by tests/stages/*.check.sh). Requires ROOT_DIR.
: "${ROOT_DIR:?ROOT_DIR must be set}"

# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/platform.sh
source "$ROOT_DIR/scripts/lib/platform.sh"

_caller_toolchain_version="${TOOLCHAIN_VERSION:-}"
# shellcheck source=versions.env
source "$ROOT_DIR/versions.env"
if [ -n "$_caller_toolchain_version" ]; then TOOLCHAIN_VERSION="$_caller_toolchain_version"; fi
unset _caller_toolchain_version
if [ -f "$ROOT_DIR/vars.sh" ]; then
  # shellcheck source=vars.sh
  source "$ROOT_DIR/vars.sh"
fi

HOST_OS="${ELIDE_HOST_OS:-$(detect_host_os)}"
HOST_ARCH="${ELIDE_HOST_ARCH:-$(detect_host_arch)}"
OUT_DIR="${ELIDE_OUT_DIR:-$ROOT_DIR/out/$HOST_OS-$HOST_ARCH}"
BUNDLE_DIR="$OUT_DIR/$TOOLCHAIN_NAME"
STAGE1_DIR="$OUT_DIR/stage1"
BUILD_DIR="$OUT_DIR/build"
STAMPS_DIR="$OUT_DIR/stamps"
CACHE_DIR="${ELIDE_CACHE_DIR:-$ROOT_DIR/out/cache}"
DIST_DIR="${ELIDE_DIST_DIR:-$ROOT_DIR/dist}"
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-$BUNDLE_DIR}"
ALL_TARGETS="$(bundle_triples "$HOST_OS" "$HOST_ARCH")"
TARGETS="${TARGETS:-$ALL_TARGETS}"
JOBS="${JOBS:-$(cpu_count)}"
LLVM_MAJOR="${LLVM_VERSION%%.*}"
export ROOT_DIR HOST_OS HOST_ARCH OUT_DIR BUNDLE_DIR STAGE1_DIR BUILD_DIR STAMPS_DIR CACHE_DIR \
  DIST_DIR TOOLCHAIN_ROOT ALL_TARGETS TARGETS JOBS LLVM_MAJOR TOOLCHAIN_VERSION

if [ "$HOST_OS" = darwin ] && [ -z "${SDKROOT:-}" ] && command -v xcrun >/dev/null 2>&1; then
  SDKROOT="$(xcrun --show-sdk-path)"
  export SDKROOT
fi
```

- [ ] **Step 5: Implement `build.sh`**

```bash
#!/usr/bin/env bash
# Build an elide-toolchain bundle for the host OS/arch.
# Spec: docs/superpowers/specs/2026-10-04-universal-native-toolchain-design.md
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "ERROR: bash >= 4 is required (macOS: brew install bash)" >&2
  exit 1
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export ROOT_DIR

STAGES=(
  00-sources
  10-llvm-stage1
  20-libc-gnu
  21-libc-musl
  30-runtimes
  35-mimalloc
  36-llvm-deps
  40-llvm-stage2
  50-components
  90-package
  95-verify
)
STAGES_DIR="${ELIDE_STAGES_DIR:-$ROOT_DIR/scripts/stages}"

usage() {
  cat <<'EOF'
Usage: ./build.sh [options]

  --from STAGE      run STAGE and every later stage, ignoring (and clearing) their stamps
  --only STAGE      run only STAGE, ignoring its stamp
  --targets LIST    comma-separated triples for per-target stages (default: all in bundle)
  --clean           delete out/<os>-<arch> first
  --dry-run         print the stages that would run, then exit
  -h, --help        show this help

Stages: 00-sources 10-llvm-stage1 20-libc-gnu 21-libc-musl 30-runtimes 35-mimalloc
        36-llvm-deps 40-llvm-stage2 50-components 90-package 95-verify
EOF
}

from="" only="" clean=no dry_run=no targets_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) from="${2:?--from needs a stage}"; shift 2 ;;
    --only) only="${2:?--only needs a stage}"; shift 2 ;;
    --targets) targets_arg="${2:?--targets needs a list}"; shift 2 ;;
    --clean) clean=yes; shift ;;
    --dry-run) dry_run=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"

if [ -n "$targets_arg" ]; then
  TARGETS=""
  for t in ${targets_arg//,/ }; do
    case " $ALL_TARGETS " in
      *" $t "*) TARGETS="$TARGETS $t" ;;
      *) die "target $t is not in the $HOST_OS-$HOST_ARCH bundle ($ALL_TARGETS)" ;;
    esac
  done
  TARGETS="${TARGETS# }"
  export TARGETS
fi

stage_index() {
  local i
  for i in "${!STAGES[@]}"; do
    if [ "${STAGES[$i]}" = "$1" ]; then echo "$i"; return 0; fi
  done
  die "unknown stage: $1"
}

run_stage() {
  local stage="$1"
  log "stage $stage ($HOST_OS-$HOST_ARCH; targets: $TARGETS)"
  (
    # shellcheck source=/dev/null
    source "$STAGES_DIR/$stage.sh"
    if declare -F stage_applies >/dev/null && ! stage_applies; then
      log "stage $stage does not apply to $HOST_OS-$HOST_ARCH; skipping"
      exit 0
    fi
    stage_main
  )
  stamp_done "$stage"
}

if [ "$clean" = yes ] && [ "$dry_run" = no ]; then
  log "cleaning $OUT_DIR"
  rm -rf "$OUT_DIR"
fi

plan=()
if [ -n "$only" ]; then
  stage_index "$only" >/dev/null
  plan=("$only")
else
  start=0
  if [ -n "$from" ]; then start="$(stage_index "$from")"; fi
  for i in "${!STAGES[@]}"; do
    s="${STAGES[$i]}"
    [ "$i" -ge "$start" ] || continue
    if [ -z "$from" ] && [ "$clean" = no ] && stamp_exists "$s"; then continue; fi
    plan+=("$s")
  done
fi

if [ "$dry_run" = yes ]; then
  [ "${#plan[@]}" -eq 0 ] || printf '%s\n' "${plan[@]}"
  exit 0
fi

if [ -n "$from" ]; then
  for s in "${plan[@]}"; do stamp_clear "$s"; done
fi

if [ "${#plan[@]}" -eq 0 ]; then
  log "nothing to do (all stages stamped; use --from or --clean)"
  exit 0
fi

for s in "${plan[@]}"; do run_stage "$s"; done
log "bundle: $BUNDLE_DIR"
```
Run: `chmod +x build.sh`

- [ ] **Step 6: Rewrite `vars.sh`**

```bash
# shellcheck shell=bash disable=SC2034
# Local build knobs. Each may also be set in the environment.

# Components (registry and build order: scripts/lib/components.sh)
BUILD_ZLIB_NG=${BUILD_ZLIB_NG:-yes}
BUILD_ZSTD=${BUILD_ZSTD:-yes}
BUILD_BROTLI=${BUILD_BROTLI:-yes}
BUILD_SNAPPY=${BUILD_SNAPPY:-yes}
BUILD_LZ4=${BUILD_LZ4:-yes}
BUILD_CRC32C=${BUILD_CRC32C:-yes}
BUILD_AWS_LC=${BUILD_AWS_LC:-yes}
BUILD_OPENSSL=${BUILD_OPENSSL:-no}
BUILD_ZLIB=${BUILD_ZLIB:-no}
BUILD_SQLITE=${BUILD_SQLITE:-no}
BUILD_SQLCIPHER=${BUILD_SQLCIPHER:-no}
BUILD_CAPNP=${BUILD_CAPNP:-no}
BUILD_HIREDIS=${BUILD_HIREDIS:-no}
BUILD_LEVELDB=${BUILD_LEVELDB:-no}

# musl
MUSL_USE_MIMALLOC=${MUSL_USE_MIMALLOC:-yes}
MUSL_USE_LTO=${MUSL_USE_LTO:-yes}

# mimalloc
MIMALLOC_SECURE=${MIMALLOC_SECURE:-OFF}
MIMALLOC_GUARDED=${MIMALLOC_GUARDED:-OFF}

# Build behaviour
USE_SCCACHE=${USE_SCCACHE:-no}
REQUIRE_CONTAINER_CHECKS=${REQUIRE_CONTAINER_CHECKS:-no}
```

- [ ] **Step 7: Run the tests and confirm they pass**

Run: `tests/run.sh`
Expected: every test file reports `0 failed`; shellcheck is clean.

- [ ] **Step 8: Commit**

```bash
git add build.sh vars.sh scripts/lib/env.sh scripts/legacy/build.sh tests/unit/orchestrator.test.sh
git commit -m "feat: staged build orchestrator with stamps, --from/--only/--targets

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Submodule updates, version pins, `check-versions.sh`

**Files:**
- Create: `scripts/bump-submodules.sh`, `scripts/check-versions.sh`
- Modify: `.gitmodules` (drop `musl-cross-make`, drop the bogus `branch =` on `llvm`), `versions.env` (generated component block)
- Delete: `musl-cross-make` submodule, `config.mak`

**Interfaces:**
- Produces in `versions.env`, for each submodule path P (upper-cased, `-`→`_`): `P_REV=<40-hex sha>`, and either `P_VERSION=<tag without v/llvmorg-/openssl- prefix>` (tag-tracked modules) or `P_REF=<branch>` (branch-tracked modules). Examples: `LLVM_VERSION`, `LLVM_REV`, `AWS_LC_VERSION`, `GLIBC_REF`, `GLIBC_REV`, `MUSL_REF`, `MUSL_REV`. The `LLVM_VERSION` line written by hand in Task 3 is removed, since the generated block supplies it.
- `scripts/check-versions.sh` exits 0 only if every submodule's gitlink equals its `*_REV` and no checkout differs from its gitlink.

- [ ] **Step 1: Remove musl-cross-make and config.mak**

```bash
git submodule deinit -f musl-cross-make
git rm -f musl-cross-make config.mak
rm -rf .git/modules/musl-cross-make
git config -f .gitmodules --unset submodule.llvm.branch || true
```

- [ ] **Step 2: Write `scripts/bump-submodules.sh`**

```bash
#!/usr/bin/env bash
# Move every submodule to its latest stable release tag (or branch tip), stage the new
# gitlinks, and regenerate the component pin block in versions.env.
# Usage: scripts/bump-submodules.sh   (submodules must be initialized)
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

# path|mode|selector
#   tag:     newest tag matching the ERE selector (prereleases excluded)
#   branch:  tip of the named branch
#   default: tip of the remote's default branch
SPEC='
aws-lc|tag|v[0-9]+\.[0-9]+\.[0-9]+
brotli|tag|v[0-9]+\.[0-9]+\.[0-9]+
capnp|tag|v1\.[0-9]+\.[0-9]+
cflags|branch|main
crc32c|tag|[0-9]+\.[0-9]+\.[0-9]+
glibc|branch|release/2.34/master
hiredis|tag|v[0-9]+\.[0-9]+\.[0-9]+
leveldb|tag|[0-9]+\.[0-9]+
llvm|tag|llvmorg-23\.[0-9]+\.[0-9]+
llvm-propeller|default|
lz4|tag|v[0-9]+\.[0-9]+\.[0-9]+
mimalloc|tag|v3\.[0-9]+\.[0-9]+
musl|branch|elide-v1.2.5
openssl|tag|openssl-[0-9]+\.[0-9]+\.[0-9]+
snappy|tag|[0-9]+\.[0-9]+\.[0-9]+
sqlcipher|tag|v[0-9]+\.[0-9]+\.[0-9]+
sqlite|default|
zlib|default|
zlib-ng|tag|[0-9]+\.[0-9]+\.[0-9]+
zstd|tag|v[0-9]+\.[0-9]+\.[0-9]+
'

var_of() { echo "$1" | tr 'a-z-' 'A-Z_'; }
strip_tag() { echo "$1" | sed -E 's/^(v|llvmorg-|openssl-)//'; }
url_of() { git -C "$1" remote get-url origin; }

block=""
while IFS='|' read -r path mode sel; do
  [ -n "$path" ] || continue
  [ -e "$path/.git" ] || { echo "submodule $path is not initialized" >&2; exit 1; }
  v="$(var_of "$path")"
  case "$mode" in
    tag)
      tag="$(git ls-remote --tags --refs "$(url_of "$path")" | awk '{sub("refs/tags/","",$2); print $2}' \
        | grep -E "^${sel}\$" | grep -viE 'rc|alpha|beta|pre|dev' | sort -V | tail -1)"
      [ -n "$tag" ] || { echo "no tag matching $sel for $path" >&2; exit 1; }
      git -C "$path" fetch -q --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
      git -C "$path" checkout -q "refs/tags/$tag"
      line="${v}_VERSION=$(strip_tag "$tag")" ;;
    branch)
      git -C "$path" fetch -q --depth 1 origin "$sel"
      git -C "$path" checkout -q FETCH_HEAD
      line="${v}_REF=${sel}" ;;
    default)
      git -C "$path" fetch -q --depth 1 origin HEAD
      git -C "$path" checkout -q FETCH_HEAD
      line="${v}_REF=HEAD" ;;
    *) echo "bad mode $mode for $path" >&2; exit 1 ;;
  esac
  git add "$path"
  block+="${v}_REV=$(git -C "$path" rev-parse HEAD)"$'\n'"${line}"$'\n'
  echo "$path -> ${line#*=} ($(git -C "$path" rev-parse --short HEAD))"
done <<< "$SPEC"

python3 - "$ROOT_DIR/versions.env" "$block" <<'PYEOF'
import re, sys
path, block = sys.argv[1], sys.argv[2]
begin = "# >>> component pins (generated by scripts/bump-submodules.sh)"
end = "# <<< component pins"
text = open(path).read()
new = f"{begin}\n{block}{end}\n"
if begin in text:
    text = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n", lambda _: new, text, flags=re.S)
else:
    text = text.rstrip("\n") + "\n\n" + new
open(path, "w").write(text)
PYEOF
echo "versions.env updated"
```

- [ ] **Step 3: Write `scripts/check-versions.sh`**

```bash
#!/usr/bin/env bash
# Verify every submodule's (staged) gitlink matches its *_REV pin in versions.env, and that no
# initialized checkout differs from its gitlink. Works on shallow clones.
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=versions.env
source "$ROOT_DIR/versions.env"

status=0
while read -r line; do
  flag="${line:0:1}"
  sha="$(echo "$line" | awk '{print $1}' | tr -d '+-U')"
  path="$(echo "$line" | awk '{print $2}')"
  gitlink="$(git -C "$ROOT_DIR" ls-files -s -- "$path" | awk '{print $2}')"   # staged gitlink
  var="$(echo "$path" | tr 'a-z-' 'A-Z_')_REV"
  want="${!var:-}"
  if [ -z "$want" ]; then
    echo "MISSING  $path: no $var in versions.env"; status=1
  elif [ "$gitlink" != "$want" ]; then
    echo "MISMATCH $path: gitlink $gitlink, versions.env $want"; status=1
  elif [ "$flag" = "+" ]; then
    echo "DIRTY    $path: checkout $sha differs from gitlink $gitlink"; status=1
  fi
done < <(git -C "$ROOT_DIR" submodule status | sed 's/^ //')
[ "$status" -eq 0 ] && echo "submodule pins OK"
exit "$status"
```
(`git submodule status` puts `+` in the first column when the checkout differs; the `sed` removes only the leading space used for clean entries.)

- [ ] **Step 4: Confirm `check-versions.sh` fails before the pins exist**

Run: `chmod +x scripts/*.sh && scripts/check-versions.sh`
Expected: exit 1, with `MISSING … _REV` lines for every submodule.

- [ ] **Step 5: Run the bump**

```bash
git submodule update --init --depth=1
sed -i '/^LLVM_VERSION=/d' versions.env
scripts/bump-submodules.sh
git diff --cached --stat
sed -n '/>>> component pins/,/<<< component pins/p' versions.env
```
Expected: the submodules move to their newest stable tags, with `LLVM_VERSION=23.x.y`, `MIMALLOC_VERSION=3.x.y`, `GLIBC_REF=release/2.34/master` and so on in the block. Check by eye that `LLVM_VERSION` starts with `23.` and `CAPNP_VERSION` starts with `1.`.

- [ ] **Step 6: Confirm `check-versions.sh` passes**

Run: `scripts/check-versions.sh`
Expected: `submodule pins OK`, exit 0.

- [ ] **Step 7: Run the unit tests (the platform test reads versions.env)**

Run: `tests/run.sh` → Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add -A .gitmodules versions.env scripts/bump-submodules.sh scripts/check-versions.sh
git add $(git submodule status | awk '{print $2}')
git commit -m "chore: update all components to latest stable; drop musl-cross-make

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Target flags (`flags.sh`) and CMake helper (`cmake.sh`)

**Files:**
- Create: `scripts/lib/flags.sh`, `scripts/lib/cmake.sh`, `tests/unit/flags.test.sh`, `tests/unit/cmake.test.sh`
- Modify: `scripts/lib/env.sh` (source the two new libs)

**Interfaces:**
- Consumes: `triple_os`, `triple_cpu`, `triple_libc`, `cpu_to_arch`, `arch_flags`, `version_lt`, `GLIBC_FLOOR`.
- Produces (flags.sh): `read_flag_file FILE`, `profile_flags OS ARCH`, `filter_flags_for_triple TRIPLE FLAG…`, `target_cflags T`, `target_cxxflags T`, `target_ldflags T` (shared-object/archive-safe link flags), `target_exe_ldflags T` (adds `-static` for musl).
- Produces (cmake.sh): `CMAKE_BIN` (default `cmake`, overridable), `toolchain_file T` → `$TOOLCHAIN_ROOT/share/elide-toolchain/cmake/T.cmake`, `cmake_launcher_args`, `cmake_target T SRC BUILD PREFIX [ARGS…]` (configure with Ninja + toolchain file + target flags, then build and install).

- [ ] **Step 1: Write the failing flags test**

`tests/unit/flags.test.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
ELIDE_HOST_OS=linux ELIDE_HOST_ARCH=amd64 ELIDE_OUT_DIR="$(mktemp -d)"
export ELIDE_HOST_OS ELIDE_HOST_ARCH ELIDE_OUT_DIR
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"

gnu="$(target_cflags x86_64-unknown-linux-gnu)"
musl="$(target_cflags x86_64-unknown-linux-musl)"
assert_not_contains "$gnu" "pack-relative-relocs" "gnu drops DT_RELR below glibc 2.36"
assert_contains "$musl" "-Wl,-z,pack-relative-relocs" "musl keeps DT_RELR"
assert_contains "$gnu" "-march=x86-64-v3 -mtune=znver3" "arch override applied last"
assert_contains "$gnu" "$(read_flag_file "$ROOT_DIR/cflags.local/base.txt" | awk '{print $1}')" "cflags.local overlay applied"
assert_contains "$(target_exe_ldflags x86_64-unknown-linux-musl)" "-static"
assert_not_contains "$(target_exe_ldflags x86_64-unknown-linux-gnu)" "-static"
assert_not_contains "$(target_ldflags x86_64-unknown-linux-musl)" " -static"

darwin="$(target_cflags arm64-apple-darwin)"
assert_contains "$darwin" "-mcpu=apple-m1" "darwin uses the profile's cpu flag"
assert_not_contains "$darwin" "-march=x86-64" "no linux arch override on darwin"

# The filter only knows the standalone spelling; guard against the profile changing it.
others="$(grep -h 'pack-relative-relocs' "$ROOT_DIR"/cflags/*.txt | sed 's/#.*//' | grep -v '^[[:space:]]*$' | grep -vx -- '-Wl,-z,pack-relative-relocs' || true)"
assert_eq "$others" "" "cflags profile spells DT_RELR only as a standalone token"

GLIBC_FLOOR=2.36
assert_contains "$(target_cflags x86_64-unknown-linux-gnu)" "pack-relative-relocs" "kept when floor >= 2.36"

finish
```

- [ ] **Step 2: Run and confirm failure**

Run: `tests/run.sh flags` → Expected: FAIL (`target_cflags: command not found`).

- [ ] **Step 3: Implement `scripts/lib/flags.sh`**

```bash
# shellcheck shell=bash
# Flags for target code: cflags profile + cflags.local overlay, filtered for the triple's
# floors, followed by -march/-mtune (last one wins). Toolchain-layer builds (libc, runtimes,
# LLVM, mimalloc) use their own flags and do not call these.

read_flag_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  sed -e 's/#.*$//' -e 's/[[:space:]]\{1,\}$//' "$f" | grep -v '^[[:space:]]*$' | xargs || true
}

# profile_flags OS ARCH — upstream compile rollup (base → os → os-arch), then local overlay.
profile_flags() {
  local os="$1" arch="$2" out f content
  out="$("$ROOT_DIR/cflags/cli/cflags.sh" "$os" "$arch")"
  for f in base "$os" "$os-$arch"; do
    content="$(read_flag_file "$ROOT_DIR/cflags.local/$f.txt")"
    if [ -n "$content" ]; then out="$out $content"; fi
  done
  printf '%s\n' "$out"
}

# filter_flags_for_triple TRIPLE FLAG... — drop flags that would raise the triple's floor.
filter_flags_for_triple() {
  local triple="$1" f out="" drop_relr=no
  shift
  if [ "$(triple_libc "$triple")" = gnu ] && version_lt "$GLIBC_FLOOR" 2.36; then drop_relr=yes; fi
  for f in "$@"; do
    # DT_RELR makes lld emit a GLIBC_ABI_DT_RELR version need (glibc >= 2.36).
    if [ "$drop_relr" = yes ] && [ "$f" = "-Wl,-z,pack-relative-relocs" ]; then continue; fi
    out="$out $f"
  done
  printf '%s\n' "${out# }"
}

target_cflags() {
  local t="$1" os arch
  os="$(triple_os "$t")"
  arch="$(cpu_to_arch "$(triple_cpu "$t")")"
  # shellcheck disable=SC2046
  printf '%s %s\n' "$(filter_flags_for_triple "$t" $(profile_flags "$os" "$arch"))" "$(arch_flags "$t")"
}

target_cxxflags() { target_cflags "$1"; }

# Link flags for shared objects and archives (no -static).
target_ldflags() { target_cflags "$1"; }

# Link flags for executables: musl executables are fully static (the build host has no musl loader).
target_exe_ldflags() {
  if [ "$(triple_libc "$1")" = musl ]; then
    printf '%s -static\n' "$(target_ldflags "$1")"
  else
    target_ldflags "$1"
  fi
}
```

- [ ] **Step 4: Source it from env.sh**

In `scripts/lib/env.sh`, after the `platform.sh` source line, add:
```bash
# shellcheck source=scripts/lib/flags.sh
source "$ROOT_DIR/scripts/lib/flags.sh"
# shellcheck source=scripts/lib/cmake.sh
source "$ROOT_DIR/scripts/lib/cmake.sh"
```

- [ ] **Step 5: Write the failing cmake test**

`tests/unit/cmake.test.sh`:
```bash
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
```

- [ ] **Step 6: Run and confirm failure**

Run: `tests/run.sh cmake` → Expected: FAIL (`cmake_target: command not found`, or env.sh fails to source a missing cmake.sh).

- [ ] **Step 7: Implement `scripts/lib/cmake.sh`**

```bash
# shellcheck shell=bash
# CMake helper for target code built with a toolchain's <triple>-clang and toolchain file.

CMAKE_BIN="${CMAKE_BIN:-cmake}"

toolchain_file() { printf '%s/share/elide-toolchain/cmake/%s.cmake\n' "$TOOLCHAIN_ROOT" "$1"; }

cmake_launcher_args() {
  if is_yes "${USE_SCCACHE:-no}" && command -v sccache >/dev/null 2>&1; then
    printf '%s\n' -DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache
  fi
  return 0
}

# cmake_target TRIPLE SRC BUILD PREFIX [ARGS...] — configure, build and install.
cmake_target() {
  local t="$1" src="$2" build="$3" prefix="$4"
  shift 4
  local cflags ldflags exe_ldflags line
  cflags="$(target_cflags "$t")"
  ldflags="$(target_ldflags "$t")"
  exe_ldflags="$(target_exe_ldflags "$t")"
  local args=(
    -S "$src" -B "$build" -G Ninja
    -DCMAKE_TOOLCHAIN_FILE="$(toolchain_file "$t")"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_C_FLAGS="$cflags"
    -DCMAKE_CXX_FLAGS="$cflags"
    -DCMAKE_EXE_LINKER_FLAGS="$exe_ldflags"
    -DCMAKE_SHARED_LINKER_FLAGS="$ldflags"
    -DCMAKE_MODULE_LINKER_FLAGS="$ldflags"
  )
  if [ "$(triple_os "$t")" = darwin ]; then args+=(-DCMAKE_PREFIX_PATH="$prefix"); fi
  while IFS= read -r line; do
    if [ -n "$line" ]; then args+=("$line"); fi
  done < <(cmake_launcher_args)
  "$CMAKE_BIN" "${args[@]}" "$@"
  "$CMAKE_BIN" --build "$build" -j "$JOBS"
  "$CMAKE_BIN" --install "$build"
}
```

- [ ] **Step 8: Run all tests**

Run: `tests/run.sh` → Expected: all `0 failed`, shellcheck clean.

- [ ] **Step 9: Commit**

```bash
git add scripts/lib/flags.sh scripts/lib/cmake.sh scripts/lib/env.sh tests/unit/flags.test.sh tests/unit/cmake.test.sh
git commit -m "feat: per-triple target flags with glibc-floor filter; cmake_target helper

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
## Phase C — libc and toolchain bootstrap stages

Heavy stages are TDD'd against **post-condition scripts** (`tests/stages/<stage>.check.sh`). Each one sources `env.sh` and asserts on the stage's outputs under `$OUT_DIR`. Write the check first, run it to see it fail, implement the stage, run `./build.sh --only <stage>`, then run the check again until it passes. Common header for every check script:

```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
```

### Task 7: Stage 00 — sources and kernel headers

**Files:**
- Create: `scripts/stages/00-sources.sh`, `tests/stages/00-sources.check.sh`
- Modify: `versions.env` (add `LINUX_HEADERS_VERSION`, `LINUX_HEADERS_SHA256`)

**Interfaces:**
- Consumes: `kernel_arch`, `sysroot_of`, `sha256_of`, `scripts/check-versions.sh`.
- Produces: `$BUNDLE_DIR/sysroot/<triple>/usr/include/{linux,asm,asm-generic,…}` for every Linux triple. Later stages rely on `…/usr/include/linux/version.h` existing.

- [ ] **Step 1: Pin the kernel headers**

Use the version and sha256 recorded in `docs/notes/glibc-2.34-gcc15.md` (Task 1, Step 2). Add them above the generated pin block in `versions.env`:
```bash
# Linux UAPI headers installed into Linux sysroots (latest longterm at pin time)
LINUX_HEADERS_VERSION=<version from notes, e.g. 6.12.50>
LINUX_HEADERS_SHA256=<sha256 from notes>
```

- [ ] **Step 2: Write the failing check**

`tests/stages/00-sources.check.sh` (common header, then):
```bash
if [ "$HOST_OS" = linux ]; then
  for t in $ALL_TARGETS; do
    s="$(sysroot_of "$t")"
    assert_file "$s/usr/include/linux/version.h"
    assert_file "$s/usr/include/asm/unistd.h"
    assert_file "$s/usr/include/asm-generic/errno.h"
  done
fi
assert_ok "$ROOT_DIR/scripts/check-versions.sh"
finish
```
Run: `bash tests/stages/00-sources.check.sh` → Expected: FAIL (headers missing).

- [ ] **Step 3: Implement `scripts/stages/00-sources.sh`**

```bash
# shellcheck shell=bash
# Stage 00: verify host tools and submodule pins; install Linux UAPI headers into each
# Linux sysroot from a pinned kernel tarball (never from the host's /usr/include).

stage_main() {
  if [ "$HOST_OS" = linux ]; then
    require_cmd cmake ninja python3 git curl xz make gcc g++ bison gawk rsync
  else
    require_cmd cmake ninja python3 git curl xcrun rsync
  fi
  check_submodules
  mkdir -p "$BUNDLE_DIR/sysroot"
  if [ "$HOST_OS" = linux ]; then install_kernel_headers; fi
}

check_submodules() {
  local missing
  missing="$(git -C "$ROOT_DIR" submodule status | awk '/^-/{print $2}' | xargs)"
  [ -z "$missing" ] || die "uninitialized submodules: $missing (run: git submodule update --init --depth=1 --recursive)"
  "$ROOT_DIR/scripts/check-versions.sh"
}

fetch_kernel() {
  local v="$LINUX_HEADERS_VERSION" tarball
  tarball="$CACHE_DIR/linux-$v.tar.xz"
  mkdir -p "$CACHE_DIR"
  if [ ! -f "$tarball" ]; then
    log "downloading linux-$v"
    curl -fsSL --retry 3 -o "$tarball.part" "https://cdn.kernel.org/pub/linux/kernel/v${v%%.*}.x/linux-$v.tar.xz"
    mv "$tarball.part" "$tarball"
  fi
  [ "$(sha256_of "$tarball")" = "$LINUX_HEADERS_SHA256" ] || die "sha256 mismatch for $tarball"
  printf '%s\n' "$tarball"
}

install_kernel_headers() {
  local tarball src t sysroot
  tarball="$(fetch_kernel)"
  fresh_dir "$BUILD_DIR/linux"
  tar -C "$BUILD_DIR/linux" -xJf "$tarball"
  src="$BUILD_DIR/linux/linux-$LINUX_HEADERS_VERSION"
  for t in $ALL_TARGETS; do
    sysroot="$(sysroot_of "$t")"
    mkdir -p "$sysroot/usr"
    make -C "$src" ARCH="$(kernel_arch "$(triple_cpu "$t")")" INSTALL_HDR_PATH="$sysroot/usr" headers_install
  done
}
```

- [ ] **Step 4: Run the stage and the check**

Run: `./build.sh --only 00-sources && bash tests/stages/00-sources.check.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/stages/00-sources.sh tests/stages/00-sources.check.sh versions.env
git commit -m "feat: stage 00 — submodule checks and pinned kernel headers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Stage 20 — glibc

**Files:**
- Create: `scripts/stages/20-libc-gnu.sh`, `tests/stages/20-libc-gnu.check.sh`

**Interfaces:**
- Consumes: Task 1's patches and configure line, `bundle_triple_for_libc gnu`, `glibc_loader`, `apply_patches`.
- Produces: the glibc 2.34 install in `sysroot/<arch>-unknown-linux-gnu/usr/{include,lib}`; the loader at `sysroot/<gnu>/<glibc_loader cpu>`; and `$OUT_DIR/glibc-files.txt` (sysroot-relative paths of glibc's own files, used by Task 19 to exclude glibc itself from the floor check).

- [ ] **Step 1: Write the failing check**

`tests/stages/20-libc-gnu.check.sh` (common header, then):
```bash
[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }
t="$(bundle_triple_for_libc gnu)"; s="$(sysroot_of "$t")"; cpu="$(triple_cpu "$t")"
for f in usr/lib/libc.so.6 usr/lib/libc.so usr/lib/libc.a usr/lib/crt1.o usr/lib/libc_nonshared.a usr/include/stdio.h "$(glibc_loader "$cpu")"; do
  assert_file "$s/$f"
done
maxdef="$(readelf -V "$s/usr/lib/libc.so.6" | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -1)"
assert_eq "$maxdef" "GLIBC_$GLIBC_FLOOR" "libc.so.6 defines up to the floor"
loader_target="$(readlink "$s/$(glibc_loader "$cpu")" || true)"
assert_not_contains "x$loader_target" "x/" "loader link is relative"
assert_file "$OUT_DIR/glibc-files.txt"
tmp="$(mktemp -d)"
echo 'int main(void){return 0;}' > "$tmp/t.c"
assert_ok gcc --sysroot="$s" "$tmp/t.c" -o "$tmp/t"
assert_ok "$tmp/t"
rm -rf "$tmp"
finish
```
Run: `bash tests/stages/20-libc-gnu.check.sh` → Expected: FAIL.

- [ ] **Step 2: Implement `scripts/stages/20-libc-gnu.sh`**

Use the configure line from `docs/notes/glibc-2.34-gcc15.md`. If it differs from the one below, the note wins.
```bash
# shellcheck shell=bash
# Stage 20: glibc at GLIBC_FLOOR, from the glibc submodule (release/2.34/master), built with
# the host GCC (glibc 2.34 cannot be built with clang). Installed with slibdir=/usr/lib.

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t sysroot build cpu
  t="$(bundle_triple_for_libc gnu)"
  sysroot="$(sysroot_of "$t")"
  cpu="$(triple_cpu "$t")"
  build="$BUILD_DIR/glibc"
  [ -f "$sysroot/usr/include/linux/version.h" ] || die "kernel headers missing in $sysroot; run 00-sources"

  apply_patches glibc "$ROOT_DIR/glibc"
  fresh_dir "$build"
  (
    cd "$build"
    unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS CC CXX
    # GCC 15 defaults to C23, which glibc < 2.39 does not build under; pin gnu11.
    "$ROOT_DIR/glibc/configure" \
      CC=gcc CXX=g++ CFLAGS="-O2 -std=gnu11" \
      --prefix=/usr --libdir=/usr/lib --libexecdir=/usr/lib \
      libc_cv_slibdir=/usr/lib \
      --with-headers="$sysroot/usr/include" \
      --enable-kernel="$GLIBC_ENABLE_KERNEL" \
      --enable-stack-protector=strong --enable-bind-now \
      --disable-werror --disable-profile
    make -j"$JOBS"
    make install DESTDIR="$sysroot"
  )
  (cd "$ROOT_DIR/glibc" && git checkout -q .)   # leave the submodule pristine; patches live in src/patches
  ensure_loader_link "$sysroot" "$cpu"
  (cd "$sysroot" && find . -type f -o -type l | sed 's#^\./##' | sort) > "$OUT_DIR/glibc-files.txt"
}

# ensure_loader_link SYSROOT CPU — the canonical PT_INTERP path must exist inside the sysroot
# so libc.so's AS_NEEDED(ld-linux…) resolves at link time. Relative, so the sysroot relocates.
ensure_loader_link() {
  local sysroot="$1" cpu="$2" loader name
  loader="$(glibc_loader "$cpu")"
  name="$(basename "$loader")"
  if [ -e "$sysroot/$loader" ] && [ "$(readlink "$sysroot/$loader" | cut -c1)" != "/" ]; then return 0; fi
  [ -e "$sysroot/usr/lib/$name" ] || die "glibc loader $name not installed in $sysroot/usr/lib"
  mkdir -p "$sysroot/$(dirname "$loader")"
  ln -sfn "../usr/lib/$name" "$sysroot/$loader"
}
```

- [ ] **Step 3: Run the stage and the check**

Run: `./build.sh --only 20-libc-gnu && bash tests/stages/20-libc-gnu.check.sh` (about 10–20 min)
Expected: `0 failed`.

- [ ] **Step 4: Commit**

```bash
git add scripts/stages/20-libc-gnu.sh tests/stages/20-libc-gnu.check.sh
git commit -m "feat: stage 20 — glibc 2.34 sysroot from source

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Front-ends — clang cfgs, triple symlinks, musl GCC shims, CMake toolchain files

**Files:**
- Create: `scripts/lib/frontends.sh`, `src/shims/musl-gcc`, `tests/unit/frontends.test.sh`
- Modify: `scripts/lib/env.sh` (source frontends.sh)

**Interfaces:**
- Consumes: `triple_os`, `triple_cpu`, `triple_libc`, `musl_gcc_prefix`, `MACOS_MIN`, `ALL_TARGETS`.
- Produces: `render_cfg T`, `render_toolchain_cmake T`, `install_musl_shims PREFIX T`, and `install_frontends PREFIX`. `install_frontends` writes `PREFIX/bin/T.cfg`, the symlinks `PREFIX/bin/T-clang → clang` and `T-clang++ → clang++`, `PREFIX/share/elide-toolchain/cmake/T.cmake` for every T in `$ALL_TARGETS`, and for musl triples `PREFIX/bin/<cpu>-linux-musl-{gcc,g++,cc,c++,ar,ranlib,nm,strip}`.

- [ ] **Step 1: Write the failing test**

`tests/unit/frontends.test.sh`:
```bash
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
assert_contains "$dcfg" "-isystem <CFGDIR>/../sysroot/arm64-apple-darwin/usr/include"
assert_contains "$(render_toolchain_cmake x86_64-unknown-linux-musl)" 'set(CMAKE_SYSROOT "${_ET_ROOT}/sysroot/x86_64-unknown-linux-musl")'
assert_contains "$(render_toolchain_cmake arm64-apple-darwin)" 'set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0"'

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
```
Note: the fake `clang` is invoked through the `x86_64-unknown-linux-musl-clang` symlink, so it prints `clang …`. That's expected.

- [ ] **Step 2: Run and confirm failure**

Run: `tests/run.sh frontends` → Expected: FAIL.

- [ ] **Step 3: Implement `src/shims/musl-gcc` (POSIX sh)**

```sh
#!/bin/sh
# GCC-named front-end for the musl target, for tools that look up
# <cpu>-linux-musl-{gcc,g++,cc,c++,ar,ranlib,nm,strip} by name (e.g. GraalVM
# `native-image --libc=musl`). Delegates to the bundle's clang and llvm tools.
# Never adds -static: callers (native-image included) pass it themselves.
set -eu

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
name=$(basename -- "$0")
cpu=${name%%-linux-musl-*}
tool=${name##*-linux-musl-}

# GCC-only flags clang rejects, space-separated. Extended as consumer migrations find them.
DROP_FLAGS=""

case $tool in
  gcc|cc) driver="$dir/$cpu-unknown-linux-musl-clang" ;;
  g++|c++) driver="$dir/$cpu-unknown-linux-musl-clang++" ;;
  ar|ranlib|nm|strip) exec "$dir/llvm-$tool" "$@" ;;
  *) echo "$name: unsupported shim tool '$tool'" >&2; exit 2 ;;
esac

if [ -n "$DROP_FLAGS" ]; then
  n=$#
  while [ "$n" -gt 0 ]; do
    arg=$1
    shift
    n=$((n - 1))
    case " $DROP_FLAGS " in
      *" $arg "*) [ -n "$arg" ] && continue ;;
    esac
    set -- "$@" "$arg"
  done
fi
exec "$driver" "$@"
```
Run: `chmod +x src/shims/musl-gcc`

- [ ] **Step 4: Implement `scripts/lib/frontends.sh`**

```bash
# shellcheck shell=bash
# Target front-ends for a toolchain prefix (stage 1 or the bundle): clang config files,
# <triple>-clang symlinks, GCC-named musl shims, and CMake toolchain files. All paths are
# relative (<CFGDIR>, CMAKE_CURRENT_LIST_DIR) so the prefix can be relocated.

render_cfg() {
  local t="$1"
  case "$(triple_os "$t")" in
    linux)
      printf '%s\n' \
        "--target=$t" \
        "--sysroot=<CFGDIR>/../sysroot/$t" \
        "-rtlib=compiler-rt" \
        "-unwindlib=libunwind" \
        "-stdlib=libc++" \
        "-fuse-ld=lld"
      ;;
    darwin)
      printf '%s\n' \
        "--target=$(triple_cpu "$t")-apple-macos$MACOS_MIN" \
        "-isystem <CFGDIR>/../sysroot/$t/usr/include" \
        "-L<CFGDIR>/../sysroot/$t/usr/lib" \
        "-fuse-ld=lld"
      ;;
  esac
}

render_toolchain_cmake() {
  local t="$1"
  cat <<EOF
# Generated by elide-toolchain for $t.
# Usage: cmake -DCMAKE_TOOLCHAIN_FILE=<this file> ...
get_filename_component(_ET_ROOT "\${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(CMAKE_C_COMPILER "\${_ET_ROOT}/bin/$t-clang")
set(CMAKE_CXX_COMPILER "\${_ET_ROOT}/bin/$t-clang++")
set(CMAKE_ASM_COMPILER "\${_ET_ROOT}/bin/$t-clang")
set(CMAKE_AR "\${_ET_ROOT}/bin/llvm-ar" CACHE FILEPATH "")
set(CMAKE_RANLIB "\${_ET_ROOT}/bin/llvm-ranlib" CACHE FILEPATH "")
set(CMAKE_NM "\${_ET_ROOT}/bin/llvm-nm" CACHE FILEPATH "")
set(CMAKE_STRIP "\${_ET_ROOT}/bin/llvm-strip" CACHE FILEPATH "")
EOF
  case "$(triple_os "$t")" in
    linux)
      cat <<EOF
set(CMAKE_SYSROOT "\${_ET_ROOT}/sysroot/$t")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
      ;;
    darwin)
      cat <<EOF
set(CMAKE_OSX_DEPLOYMENT_TARGET "$MACOS_MIN" CACHE STRING "")
set(CMAKE_OSX_ARCHITECTURES "$(triple_cpu "$t")" CACHE STRING "")
list(APPEND CMAKE_PREFIX_PATH "\${_ET_ROOT}/sysroot/$t/usr")
EOF
      ;;
  esac
}

install_musl_shims() {
  local prefix="$1" t="$2" p tool
  p="$(musl_gcc_prefix "$t")"
  install -m 0755 "$ROOT_DIR/src/shims/musl-gcc" "$prefix/bin/$p-gcc"
  for tool in g++ cc c++ ar ranlib nm strip; do
    ln -sfn "$p-gcc" "$prefix/bin/$p-$tool"
  done
}

install_frontends() {
  local prefix="$1" t
  mkdir -p "$prefix/bin" "$prefix/share/elide-toolchain/cmake"
  for t in $ALL_TARGETS; do
    render_cfg "$t" > "$prefix/bin/$t.cfg"
    ln -sfn clang "$prefix/bin/$t-clang"
    ln -sfn clang++ "$prefix/bin/$t-clang++"
    render_toolchain_cmake "$t" > "$prefix/share/elide-toolchain/cmake/$t.cmake"
    if [ "$(triple_libc "$t")" = musl ]; then install_musl_shims "$prefix" "$t"; fi
  done
}
```
In `scripts/lib/env.sh`, after the `cmake.sh` source line, add:
```bash
# shellcheck source=scripts/lib/frontends.sh
source "$ROOT_DIR/scripts/lib/frontends.sh"
```

- [ ] **Step 5: Run the tests**

Run: `tests/run.sh` → Expected: all pass, and shellcheck (including `-s sh` on the shim) is clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/frontends.sh scripts/lib/env.sh src/shims/musl-gcc tests/unit/frontends.test.sh
git commit -m "feat: clang cfg front-ends, musl GCC shims, cmake toolchain files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Stage 10 — LLVM stage 1 (Linux) / full LLVM (macOS)

**Files:**
- Create: `scripts/stages/10-llvm-stage1.sh`, `tests/stages/10-llvm-stage1.check.sh`

**Interfaces:**
- Consumes: `install_frontends`, `LLVM_PROJECTS_DARWIN`, `MACOS_MIN`.
- Produces on Linux: `$STAGE1_DIR/bin/{clang,clang++,ld.lld,llvm-ar,llvm-ranlib,llvm-nm,llvm-readelf,llvm-objcopy,llvm-strip}`, plus the symlink `$STAGE1_DIR/sysroot → $BUNDLE_DIR/sysroot` so stage-1 cfgs resolve. Produces on macOS: the full bundle `bin/`, `lib/clang/$LLVM_MAJOR/lib/darwin/libclang_rt.{osx,profile_osx}.a`, and front-ends installed in `$BUNDLE_DIR`.

- [ ] **Step 1: Write the failing check**

`tests/stages/10-llvm-stage1.check.sh` (common header, then):
```bash
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
```
Run: `bash tests/stages/10-llvm-stage1.check.sh` → Expected: FAIL.

- [ ] **Step 2: Implement `scripts/stages/10-llvm-stage1.sh`**

```bash
# shellcheck shell=bash
# Stage 10. Linux: stage-1 clang/lld built with the host compiler (not shipped).
# macOS: the shipped LLVM (single stage), deployment target MACOS_MIN, with compiler-rt
# builtins + profile (mainline clang always links its own libclang_rt.osx.a).

host_cc()  { command -v clang   || command -v gcc; }
host_cxx() { command -v clang++ || command -v g++; }

llvm_common_args() {
  printf '%s\n' \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF -DCLANG_INCLUDE_TESTS=OFF -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_CURL=OFF -DLLVM_ENABLE_HTTPLIB=OFF -DLLVM_ENABLE_FFI=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_FORCE_VC_REPOSITORY=https://github.com/llvm/llvm-project.git
  cmake_launcher_args
}

stage_main() {
  if [ "$HOST_OS" = linux ]; then llvm_stage1_linux; else llvm_darwin; fi
}

llvm_stage1_linux() {
  local b="$BUILD_DIR/llvm-stage1" args=() lld=()
  mapfile -t args < <(llvm_common_args)
  if command -v ld.lld >/dev/null 2>&1; then lld=(-DLLVM_ENABLE_LLD=ON); fi
  fresh_dir "$b"
  rm -rf "$STAGE1_DIR"
  cmake -S "$ROOT_DIR/llvm/llvm" -B "$b" "${args[@]}" "${lld[@]}" \
    -DCMAKE_INSTALL_PREFIX="$STAGE1_DIR" \
    -DCMAKE_C_COMPILER="$(host_cc)" -DCMAKE_CXX_COMPILER="$(host_cxx)" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_ENABLE_ZLIB=OFF
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
  mkdir -p "$BUNDLE_DIR/sysroot"
  ln -sfn "$BUNDLE_DIR/sysroot" "$STAGE1_DIR/sysroot"
}

llvm_darwin() {
  local t cpu b="$BUILD_DIR/llvm" args=()
  t="$ALL_TARGETS"
  cpu="$(triple_cpu "$t")"
  mapfile -t args < <(llvm_common_args)
  fresh_dir "$b"
  cmake -S "$ROOT_DIR/llvm/llvm" -B "$b" "${args[@]}" \
    -DCMAKE_INSTALL_PREFIX="$BUNDLE_DIR" \
    -DCMAKE_C_COMPILER="$(xcrun -f clang)" -DCMAKE_CXX_COMPILER="$(xcrun -f clang++)" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_OSX_SYSROOT="$SDKROOT" \
    -DCMAKE_OSX_ARCHITECTURES="$cpu" \
    -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS_DARWIN" \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$t" \
    -DLLVM_ENABLE_ZLIB=ON \
    -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_PROFILE=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
    -DCOMPILER_RT_ENABLE_IOS=OFF -DCOMPILER_RT_ENABLE_WATCHOS=OFF -DCOMPILER_RT_ENABLE_TVOS=OFF \
    -DCOMPILER_RT_ENABLE_XROS=OFF \
    -DDARWIN_osx_ARCHS="$cpu" -DDARWIN_osx_BUILTIN_ARCHS="$cpu"
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
  install_frontends "$BUNDLE_DIR"
}
```
`LLVM_ENABLE_ZLIB=ON` on macOS uses the SDK's `libz.tbd`, which is a system library. zstd and libxml2 stay off so no Homebrew dylibs get linked (Review Focus #2).

- [ ] **Step 3: Run the stage and the check**

Run: `./build.sh --only 10-llvm-stage1 && bash tests/stages/10-llvm-stage1.check.sh` (Linux 30–60 min, 32 cores)
Expected: `0 failed`.

- [ ] **Step 4: Commit**

```bash
git add scripts/stages/10-llvm-stage1.sh tests/stages/10-llvm-stage1.check.sh
git commit -m "feat: stage 10 — LLVM stage 1 (linux) / shipped LLVM with builtins (darwin)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Stage 21 — musl phase 1 (static, mallocng)

**Files:**
- Create: `scripts/stages/21-libc-musl.sh`, `tests/stages/21-libc-musl.check.sh`

**Interfaces:**
- Consumes: stage-1 clang/llvm-ar (Task 10), kernel headers (Task 7).
- Produces: musl headers, `libc.a`, and `crt*.o` in `sysroot/<arch>-unknown-linux-musl/usr`. There is deliberately **no** `libc.so` yet: compiler-rt builtins don't exist until stage 30, and phase 2 (Task 14) rebuilds musl fully.

- [ ] **Step 1: Write the failing check**

`tests/stages/21-libc-musl.check.sh` (common header, then):
```bash
[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }
t="$(bundle_triple_for_libc musl)"; s="$(sysroot_of "$t")"
for f in usr/lib/libc.a usr/lib/crt1.o usr/lib/crti.o usr/lib/crtn.o usr/lib/rcrt1.o usr/include/stdio.h usr/include/linux/version.h; do
  assert_file "$s/$f"
done
finish
```
Run: `bash tests/stages/21-libc-musl.check.sh` → Expected: FAIL.

- [ ] **Step 2: Implement `scripts/stages/21-libc-musl.sh`**

```bash
# shellcheck shell=bash
# Stage 21: musl phase 1 — static-only, native mallocng, built with stage-1 clang. Provides
# headers and crt objects for the runtimes build (stage 30); stage 35 rebuilds musl fully.

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t sysroot build s="$STAGE1_DIR/bin"
  t="$(bundle_triple_for_libc musl)"
  sysroot="$(sysroot_of "$t")"
  build="$BUILD_DIR/musl-phase1"
  [ -x "$s/clang" ] || die "stage-1 clang missing; run 10-llvm-stage1"
  fresh_dir "$build"
  (
    cd "$build"
    unset CFLAGS CXXFLAGS LDFLAGS CC
    "$ROOT_DIR/musl/configure" \
      CC="$s/clang" CFLAGS="--target=$t -O2 -fno-fast-math" \
      AR="$s/llvm-ar" RANLIB="$s/llvm-ranlib" \
      --prefix=/usr --syslibdir=/lib --disable-shared --with-malloc=mallocng
    make -j"$JOBS" AR="$s/llvm-ar" RANLIB="$s/llvm-ranlib" LIBCC=
    make install DESTDIR="$sysroot" AR="$s/llvm-ar" RANLIB="$s/llvm-ranlib"
  )
}
```

- [ ] **Step 3: Run the stage and the check**

Run: `./build.sh --only 21-libc-musl && bash tests/stages/21-libc-musl.check.sh` → Expected: `0 failed`.

- [ ] **Step 4: Commit**

```bash
git add scripts/stages/21-libc-musl.sh tests/stages/21-libc-musl.check.sh
git commit -m "feat: stage 21 — musl phase 1 with stage-1 clang

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Stage 30 — compiler-rt, libunwind, libc++abi, libc++ per Linux triple

**Files:**
- Create: `scripts/stages/30-runtimes.sh`, `tests/stages/30-runtimes.check.sh`, `tests/fixtures/hello.c`, `tests/fixtures/hello.cpp`

**Interfaces:**
- Consumes: stage-1 clang, both sysroots, `install_frontends`.
- Produces, in **both** `$STAGE1_DIR` and `$BUNDLE_DIR`:
  - `lib/clang/$LLVM_MAJOR/lib/<T>/libclang_rt.{builtins.a,crtbegin.o,crtend.o,profile.a}`
  - `lib/<T>/{libc++.a,libc++abi.a,libunwind.a}`, where `libc++.a` has libc++abi and libunwind merged in
  - `include/c++/v1/` and `include/<T>/c++/v1/__config_site`
- Also runs `install_frontends "$STAGE1_DIR"`, so `$STAGE1_DIR/bin/<T>-clang` works from here on.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/hello.c`:
```c
#include <stdio.h>

int main(void) {
  puts("hello from elide-toolchain");
  return 0;
}
```
`tests/fixtures/hello.cpp`:
```cpp
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>

int main() {
  std::string msg;
  std::thread worker([&] {
    try {
      throw std::runtime_error("hello from elide-toolchain");
    } catch (const std::exception& e) {
      msg = e.what();
    }
  });
  worker.join();
  std::cout << msg << std::endl;
  return msg.empty() ? 1 : 0;
}
```

- [ ] **Step 2: Write the failing check**

`tests/stages/30-runtimes.check.sh` (common header, then):
```bash
[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }
tmp="$(mktemp -d)"
for t in $ALL_TARGETS; do
  for prefix in "$STAGE1_DIR" "$BUNDLE_DIR"; do
    rd="$prefix/lib/clang/$LLVM_MAJOR/lib/$t"
    for f in libclang_rt.builtins.a clang_rt.crtbegin.o clang_rt.crtend.o libclang_rt.profile.a; do assert_file "$rd/$f"; done
    for f in libc++.a libc++abi.a libunwind.a; do assert_file "$prefix/lib/$t/$f"; done
    assert_file "$prefix/include/$t/c++/v1/__config_site"
    assert_file "$prefix/include/c++/v1/vector"
  done
  site="$(cat "$STAGE1_DIR/include/$t/c++/v1/__config_site")"
  if [ "$(triple_libc "$t")" = musl ]; then
    assert_contains "$site" "_LIBCPP_HAS_MUSL_LIBC 1"; static=-static
  else
    assert_contains "$site" "_LIBCPP_HAS_MUSL_LIBC 0"; static=""
  fi
  # shellcheck disable=SC2086
  assert_ok "$STAGE1_DIR/bin/$t-clang" $static "$ROOT_DIR/tests/fixtures/hello.c" -o "$tmp/c-$t"
  assert_eq "$("$tmp/c-$t")" "hello from elide-toolchain" "C runs ($t)"
  # shellcheck disable=SC2086
  assert_ok "$STAGE1_DIR/bin/$t-clang++" $static "$ROOT_DIR/tests/fixtures/hello.cpp" -o "$tmp/cxx-$t"
  assert_eq "$("$tmp/cxx-$t")" "hello from elide-toolchain" "C++ exceptions+threads run ($t)"
done
rm -rf "$tmp"
finish
```
Run: `bash tests/stages/30-runtimes.check.sh` → Expected: FAIL.

- [ ] **Step 3: Implement `scripts/stages/30-runtimes.sh`**

```bash
# shellcheck shell=bash
# Stage 30: LLVM runtimes for each Linux triple, cross-built by stage-1 clang with bare
# --target/--sysroot (NOT the cfg: its -rtlib=compiler-rt would break cmake probes before the
# builtins exist). Installed into both the stage-1 prefix (so stage-1 clang finds them in its
# own resource dir in later stages) and the bundle.

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t
  [ -x "$STAGE1_DIR/bin/clang" ] || die "stage-1 clang missing; run 10-llvm-stage1"
  for t in $ALL_TARGETS; do
    build_builtins "$t"
    build_cxx_runtimes "$t"
  done
  install_frontends "$STAGE1_DIR"
}

runtimes_common_args() {
  local t="$1" s="$STAGE1_DIR/bin" af
  af="$(arch_flags "$t")"
  printf '%s\n' \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$s/clang" -DCMAKE_CXX_COMPILER="$s/clang++" -DCMAKE_ASM_COMPILER="$s/clang" \
    -DCMAKE_C_COMPILER_TARGET="$t" -DCMAKE_CXX_COMPILER_TARGET="$t" -DCMAKE_ASM_COMPILER_TARGET="$t" \
    -DCMAKE_SYSROOT="$(sysroot_of "$t")" \
    -DCMAKE_AR="$s/llvm-ar" -DCMAKE_RANLIB="$s/llvm-ranlib" -DCMAKE_NM="$s/llvm-nm" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$af" -DCMAKE_CXX_FLAGS="$af" -DCMAKE_ASM_FLAGS="$af" \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
    -DCOMPILER_RT_INSTALL_PATH="lib/clang/$LLVM_MAJOR" \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_GWP_ASAN=OFF
}

install_both() {
  cmake --install "$1" --prefix "$STAGE1_DIR"
  cmake --install "$1" --prefix "$BUNDLE_DIR"
}

build_builtins() {
  local t="$1" b="$BUILD_DIR/runtimes/$1/builtins" args=()
  mapfile -t args < <(runtimes_common_args "$t")
  fresh_dir "$b"
  cmake -S "$ROOT_DIR/llvm/runtimes" -B "$b" "${args[@]}" \
    -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_CRT=ON -DCOMPILER_RT_BUILD_PROFILE=OFF
  cmake --build "$b" -j "$JOBS"
  install_both "$b"
}

build_cxx_runtimes() {
  local t="$1" b="$BUILD_DIR/runtimes/$1/cxx" args=() musl=OFF
  if [ "$(triple_libc "$t")" = musl ]; then musl=ON; fi
  mapfile -t args < <(runtimes_common_args "$t")
  fresh_dir "$b"
  cmake -S "$ROOT_DIR/llvm/runtimes" -B "$b" "${args[@]}" \
    -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx;compiler-rt" \
    -DCOMPILER_RT_BUILD_BUILTINS=OFF -DCOMPILER_RT_BUILD_CRT=OFF -DCOMPILER_RT_BUILD_PROFILE=ON \
    -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
    -DLIBUNWIND_USE_COMPILER_RT=ON -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_STATIC=ON \
    -DLIBCXXABI_USE_COMPILER_RT=ON -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
    -DLIBCXXABI_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_STATIC=ON \
    -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=ON \
    -DLIBCXX_USE_COMPILER_RT=ON -DLIBCXX_HAS_MUSL_LIBC="$musl" \
    -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_ENABLE_STATIC=ON \
    -DLIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY=ON \
    -DLIBCXX_HARDENING_MODE=fast \
    -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
    -DLIBCXXABI_INCLUDE_TESTS=OFF -DLIBUNWIND_INCLUDE_TESTS=OFF \
    -DLIBCXX_INSTALL_INCLUDE_DIR=include/c++/v1 \
    -DLIBCXX_INSTALL_INCLUDE_TARGET_DIR="include/$t/c++/v1" \
    -DLIBCXX_INSTALL_LIBRARY_DIR="lib/$t" \
    -DLIBCXXABI_INSTALL_LIBRARY_DIR="lib/$t" \
    -DLIBUNWIND_INSTALL_LIBRARY_DIR="lib/$t"
  cmake --build "$b" -j "$JOBS"
  install_both "$b"
}
```

- [ ] **Step 4: Run the stage and the check**

Run: `./build.sh --only 30-runtimes && bash tests/stages/30-runtimes.check.sh` (about 10 min)
Expected: `0 failed`. If the musl C++ link fails with missing `__cxa_*` or `_Unwind_*` symbols, confirm the two `STATICALLY_LINK_*_IN_STATIC_LIBRARY` options took effect: `llvm-nm $STAGE1_DIR/lib/<t>/libc++.a | grep -c __cxa_throw` should be non-zero.

- [ ] **Step 5: Commit**

```bash
git add scripts/stages/30-runtimes.sh tests/stages/30-runtimes.check.sh tests/fixtures
git commit -m "feat: stage 30 — compiler-rt and libc++ runtimes per linux triple

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
## Phase D — Allocator, stage-2 LLVM, components

### Task 13: Component framework, zlib-ng + zstd recipes, stage 36 (LLVM deps)

**Files:**
- Create: `scripts/lib/components.sh`, `scripts/components/zlib-ng.sh`, `scripts/components/zstd.sh`, `scripts/stages/36-llvm-deps.sh`, `tests/unit/components.test.sh`, `tests/stages/36-llvm-deps.check.sh`
- Modify: `scripts/lib/env.sh` (source components.sh)

**Interfaces:**
- Consumes: `cmake_target`, `target_cflags`, `target_exe_ldflags`, `fresh_dir`, `apply_patches`, `TOOLCHAIN_ROOT`.
- Produces (components.sh):
  - `COMPONENTS` (ordered array)
  - `component_var NAME` (e.g. `zlib-ng` → `BUILD_ZLIB_NG`)
  - `component_enabled NAME`, `component_fn NAME` (→ `build_zlib_ng`), `enabled_components` (prints the enabled names)
  - `check_component_conflicts`
  - `component_artifact NAME`: `|`-separated alternatives, relative to the prefix
  - `component_link NAME`: `DEFINE|libs`, or empty when not covered by the link test
  - `target_prefix T` (→ `<sysroot>/usr`)
  - `stage_source NAME T`: prints a fresh source copy dir, with patches applied, reading `${COMPONENT_SRC_ROOT:-$ROOT_DIR}/NAME`
  - `component_build_dir NAME T`: prints a fresh build dir
  - `target_env T PREFIX`: exports CC CXX AR RANLIB NM STRIP CFLAGS CXXFLAGS LDFLAGS PKG_CONFIG_LIBDIR
- Each recipe file `scripts/components/<name>.sh` defines `build_<name_with_underscores> TRIPLE PREFIX`.
- Produces (stage 36): `$OUT_DIR/llvm-deps/{lib/libz.a,lib/libzstd.a,include/zlib.h,include/zstd.h}` for the gnu triple.

- [ ] **Step 1: Write the failing unit test**

`tests/unit/components.test.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=tests/lib/assert.sh
source "$ROOT_DIR/tests/lib/assert.sh"
T="$(mktemp -d)"
ELIDE_HOST_OS=linux ELIDE_HOST_ARCH=amd64 ELIDE_OUT_DIR="$ROOT_DIR/out/test-tmp/out"
export ELIDE_HOST_OS ELIDE_HOST_ARCH ELIDE_OUT_DIR
# shellcheck source=scripts/lib/env.sh
source "$ROOT_DIR/scripts/lib/env.sh"

assert_eq "$(component_var zlib-ng)" BUILD_ZLIB_NG
assert_eq "$(component_fn aws-lc)" build_aws_lc
BUILD_ZSTD=yes; assert_ok component_enabled zstd
BUILD_ZSTD=no;  assert_fails component_enabled zstd
BUILD_ZLIB=yes BUILD_ZLIB_NG=yes assert_fails check_component_conflicts
BUILD_ZLIB=no BUILD_ZLIB_NG=yes BUILD_OPENSSL=yes BUILD_AWS_LC=yes assert_fails check_component_conflicts
BUILD_ZLIB=no BUILD_ZLIB_NG=yes BUILD_OPENSSL=no BUILD_AWS_LC=yes BUILD_SQLCIPHER=no assert_ok check_component_conflicts
for c in "${COMPONENTS[@]}"; do
  assert_ok test -n "$(component_artifact "$c")"
done
assert_eq "$(component_link zstd)" "HAVE_ZSTD|-lzstd"
assert_eq "$(target_prefix x86_64-unknown-linux-gnu)" "$BUNDLE_DIR/sysroot/x86_64-unknown-linux-gnu/usr"

# stage_source: copy without .git, apply patches, never touch the original
mkdir -p "$T/src/demo/.git" "$T/patches/demo"
printf 'v1\n' > "$T/src/demo/file.txt"
cat > "$T/patches/demo/0001.patch" <<'EOF'
--- a/file.txt
+++ b/file.txt
@@ -1 +1 @@
-v1
+v2
EOF
d="$(COMPONENT_SRC_ROOT="$T/src" PATCHES_DIR="$T/patches" stage_source demo x86_64-unknown-linux-gnu)"
assert_eq "$(cat "$d/file.txt")" "v2"
assert_fails test -e "$d/.git"
assert_eq "$(cat "$T/src/demo/file.txt")" "v1" "original untouched"

# target_env
(
  TOOLCHAIN_ROOT=/tc
  target_env x86_64-unknown-linux-musl /p
  assert_eq "$CC" /tc/bin/x86_64-unknown-linux-musl-clang
  assert_eq "$AR" /tc/bin/llvm-ar
  assert_contains "$LDFLAGS" "-static"
  assert_eq "$PKG_CONFIG_LIBDIR" "/p/lib/pkgconfig:/p/share/pkgconfig"
  finish
) || FAILURES=$((FAILURES + 1))

assert_ok declare -F build_zlib_ng
assert_ok declare -F build_zstd

rm -rf "$T" "$ROOT_DIR/out/test-tmp"
finish
```

- [ ] **Step 2: Run and confirm failure**

Run: `tests/run.sh components` → Expected: FAIL.

- [ ] **Step 3: Implement `scripts/lib/components.sh`**

```bash
# shellcheck shell=bash
# Component registry and helpers shared by scripts/components/*.sh recipes.

# Build order: zlib before capnp; crypto before sqlcipher/capnp/hiredis.
COMPONENTS=(zlib zlib-ng zstd brotli snappy lz4 crc32c openssl aws-lc sqlite sqlcipher capnp hiredis leveldb)

component_var() { local v="${1//-/_}"; printf 'BUILD_%s\n' "${v^^}"; }
component_fn()  { printf 'build_%s\n' "${1//-/_}"; }
component_enabled() { local v; v="$(component_var "$1")"; is_yes "${!v:-no}"; }

enabled_components() {
  local c
  for c in "${COMPONENTS[@]}"; do
    if component_enabled "$c"; then echo "$c"; fi
  done
}

check_component_conflicts() {
  if component_enabled zlib && component_enabled zlib-ng; then
    die "BUILD_ZLIB and BUILD_ZLIB_NG both install libz; enable only one"
  fi
  if component_enabled openssl && component_enabled aws-lc; then
    die "BUILD_OPENSSL and BUILD_AWS_LC both install libcrypto/libssl; enable only one"
  fi
  if component_enabled sqlcipher && ! component_enabled openssl && ! component_enabled aws-lc; then
    die "BUILD_SQLCIPHER needs BUILD_OPENSSL or BUILD_AWS_LC"
  fi
  return 0
}

# component_artifact NAME — library proving NAME is installed, relative to the target prefix
# ('|'-separated alternatives).
component_artifact() {
  case "$1" in
    zlib|zlib-ng) echo lib/libz.a ;;
    zstd) echo lib/libzstd.a ;;
    brotli) echo lib/libbrotlidec.a ;;
    snappy) echo lib/libsnappy.a ;;
    lz4) echo lib/liblz4.a ;;
    crc32c) echo lib/libcrc32c.a ;;
    openssl|aws-lc) echo lib/libcrypto.a ;;
    sqlite) echo lib/libsqlite3.a ;;
    sqlcipher) echo "sqlcipher/lib/libsqlcipher.a|sqlcipher/lib/libsqlite3.a" ;;
    capnp) echo lib/libcapnp.a ;;
    hiredis) echo lib/libhiredis.a ;;
    leveldb) echo lib/libleveldb.a ;;
    *) die "unknown component: $1" ;;
  esac
}

# component_link NAME — "DEFINE|libs" for tests/fixtures/components.c, empty if not covered.
component_link() {
  case "$1" in
    zlib|zlib-ng) echo "HAVE_ZLIB|-lz" ;;
    zstd) echo "HAVE_ZSTD|-lzstd" ;;
    brotli) echo "HAVE_BROTLI|-lbrotlidec -lbrotlicommon" ;;
    snappy) echo "HAVE_SNAPPY|-lsnappy" ;;
    lz4) echo "HAVE_LZ4|-llz4" ;;
    crc32c) echo "HAVE_CRC32C|-lcrc32c" ;;
    openssl|aws-lc) echo "HAVE_CRYPTO|-lssl -lcrypto" ;;
    *) echo "" ;;
  esac
}

target_prefix() { printf '%s/usr\n' "$(sysroot_of "$1")"; }

# stage_source NAME TRIPLE — fresh per-triple copy of a submodule (patches applied), so
# in-tree builds never dirty the submodule and both libcs can build from the same sources.
stage_source() {
  local name="$1" t="$2" dir
  dir="$BUILD_DIR/components/$t/$name/src"
  fresh_dir "$dir"
  rsync -a --delete --exclude .git "${COMPONENT_SRC_ROOT:-$ROOT_DIR}/$name/" "$dir/"
  apply_patches "$name" "$dir" >&2
  printf '%s\n' "$dir"
}

component_build_dir() {
  local dir="$BUILD_DIR/components/$2/$1/build"
  fresh_dir "$dir"
  printf '%s\n' "$dir"
}

# target_env TRIPLE PREFIX — export compiler and flag variables for autotools/make recipes.
target_env() {
  local t="$1" prefix="$2" bin="$TOOLCHAIN_ROOT/bin"
  export CC="$bin/$t-clang" CXX="$bin/$t-clang++"
  export AR="$bin/llvm-ar" RANLIB="$bin/llvm-ranlib" NM="$bin/llvm-nm" STRIP="$bin/llvm-strip"
  CFLAGS="$(target_cflags "$t")"
  CXXFLAGS="$CFLAGS"
  LDFLAGS="$(target_exe_ldflags "$t")"
  export CFLAGS CXXFLAGS LDFLAGS
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
  unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR
  if [ "$(triple_os "$t")" = darwin ]; then export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"; fi
}

for _recipe in "$ROOT_DIR"/scripts/components/*.sh; do
  # shellcheck source=/dev/null
  [ -e "$_recipe" ] && source "$_recipe"
done
unset _recipe
```
In `scripts/lib/env.sh`, after the `frontends.sh` source line, add:
```bash
# shellcheck source=scripts/lib/components.sh
source "$ROOT_DIR/scripts/lib/components.sh"
```

- [ ] **Step 4: Implement the two recipes**

`scripts/components/zlib-ng.sh`:
```bash
# shellcheck shell=bash
# zlib-ng in zlib-compat mode (installs libz.a and zlib.h).
build_zlib_ng() {
  local t="$1" prefix="$2" src
  src="$(stage_source zlib-ng "$t")"
  (
    cd "$src"
    target_env "$t" "$prefix"
    ./configure --prefix="$prefix" --static --zlib-compat
    make -j"$JOBS"
    make install
  )
}
```
`scripts/components/zstd.sh`:
```bash
# shellcheck shell=bash
# Zstandard (static library only).
build_zstd() {
  local t="$1" prefix="$2" src
  src="$(stage_source zstd "$t")"
  cmake_target "$t" "$src/build/cmake" "$(component_build_dir zstd "$t")" "$prefix" \
    -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF -DZSTD_MULTITHREAD_SUPPORT=ON
}
```

- [ ] **Step 5: Run the unit tests**

Run: `tests/run.sh` → Expected: all pass.

- [ ] **Step 6: Write the failing stage-36 check**

`tests/stages/36-llvm-deps.check.sh` (common header, then):
```bash
[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }
d="$OUT_DIR/llvm-deps"
for f in lib/libz.a lib/libzstd.a include/zlib.h include/zstd.h; do assert_file "$d/$f"; done
finish
```
Run: `bash tests/stages/36-llvm-deps.check.sh` → Expected: FAIL.

- [ ] **Step 7: Implement `scripts/stages/36-llvm-deps.sh`**

```bash
# shellcheck shell=bash
# Stage 36: static zlib-ng + zstd for the gnu triple, built with stage-1 clang. Stage 2 links
# them so the shipped lld supports --compress-debug-sections=zstd (used by cflags/linux-bin.txt).
# Not shipped.

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t prefix="$OUT_DIR/llvm-deps"
  t="$(bundle_triple_for_libc gnu)"
  export TOOLCHAIN_ROOT="$STAGE1_DIR"
  fresh_dir "$prefix"
  build_zlib_ng "$t" "$prefix"
  build_zstd "$t" "$prefix"
}
```

- [ ] **Step 8: Run the stage and the check**

Run: `./build.sh --only 36-llvm-deps && bash tests/stages/36-llvm-deps.check.sh` → Expected: `0 failed`.

- [ ] **Step 9: Commit**

```bash
git add scripts/lib/components.sh scripts/lib/env.sh scripts/components scripts/stages/36-llvm-deps.sh tests/unit/components.test.sh tests/stages/36-llvm-deps.check.sh
git commit -m "feat: component framework, zlib-ng/zstd recipes, stage 36 llvm deps

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Stage 35 — mimalloc, and musl phase 2 with mimalloc + fat LTO

**Files:**
- Create: `scripts/stages/35-mimalloc.sh`, `tests/stages/35-mimalloc.check.sh`

**Interfaces:**
- Consumes: `cmake_target`, `toolchain_file`, `stage_source`, `component_build_dir`, `target_prefix`, `musl_loader`, `arch_flags`, stage-1 runtimes (Task 12), `src/mimalloc-musl-glue.c`, and the musl fork's `USE_MIMALLOC=yes` Makefile hook. The hook takes objects from `./mimalloc/objs` relative to the build dir, so phase 2 builds inside a source copy.
- Produces:
  - musl sysroot: full musl (`libc.a` with mimalloc + glue, `libc.so`), relative `lib/ld-musl-<cpu>.so.1 → ../usr/lib/libc.so`, and `usr/include/mimalloc*.h`
  - gnu sysroot: `usr/lib/libmimalloc.a` and `usr/include/mimalloc*.h` (MI_OVERRIDE=ON)
  - darwin overlay: `usr/lib/libmimalloc.a` and headers (MI_OVERRIDE=OFF)
  - with `MUSL_USE_LTO=yes`, each `libc.a` member carries both native code and a `.llvm.lto` bitcode section (`-ffat-lto-objects`)

- [ ] **Step 1: Write the failing check**

`tests/stages/35-mimalloc.check.sh` (common header, then):
```bash
nm="$STAGE1_DIR/bin/llvm-nm"; [ -x "$nm" ] || nm="$BUNDLE_DIR/bin/llvm-nm"
for t in $ALL_TARGETS; do
  p="$(target_prefix "$t")"
  assert_file "$p/include/mimalloc.h"
  case "$(triple_libc "$t")" in
    musl)
      assert_file "$p/lib/libc.so"
      ld="$(sysroot_of "$t")/$(musl_loader "$(triple_cpu "$t")")"
      assert_eq "$(readlink "$ld")" "../usr/lib/libc.so" "relative musl loader link"
      if is_yes "$MUSL_USE_MIMALLOC"; then
        assert_contains "$("$nm" "$p/lib/libc.a" 2>/dev/null | grep ' T mi_malloc$' || true)" "mi_malloc" "mimalloc inside libc.a"
      fi
      if is_yes "$MUSL_USE_LTO"; then
        tmp="$(mktemp -d)"
        member="$("$STAGE1_DIR/bin/llvm-ar" t "$p/lib/libc.a" | grep -m1 '^printf\.')"
        (cd "$tmp" && "$STAGE1_DIR/bin/llvm-ar" x "$p/lib/libc.a" "$member")
        sections="$("$STAGE1_DIR/bin/llvm-readelf" -S "$tmp/$member")"
        assert_contains "$sections" ".llvm.lto" "bitcode present (LTO)"
        assert_contains "$sections" ".text" "native code present (fat object)"
        rm -rf "$tmp"
      fi
      tmp="$(mktemp -d)"
      assert_ok "$STAGE1_DIR/bin/$t-clang" -static "$ROOT_DIR/tests/fixtures/hello.c" -o "$tmp/h"
      if is_yes "$MUSL_USE_MIMALLOC"; then
        assert_contains "$(MIMALLOC_SHOW_STATS=1 "$tmp/h" 2>&1)" "heap stats" "binary uses mimalloc"
      fi
      rm -rf "$tmp"
      ;;
    gnu|darwin)
      assert_file "$p/lib/libmimalloc.a"
      ;;
  esac
done
finish
```
Run: `bash tests/stages/35-mimalloc.check.sh` → Expected: FAIL.

- [ ] **Step 2: Implement `scripts/stages/35-mimalloc.sh`**

Port the logic from `scripts/legacy/build.sh` (sections "Build mimalloc", "mimalloc-musl glue code", "Build musl (phase 2 + mimalloc)"). The result is:
```bash
# shellcheck shell=bash
# Stage 35: mimalloc for every target. On Linux, musl is rebuilt (phase 2) with mimalloc as
# its allocator and, with MUSL_USE_LTO, as fat ThinLTO objects (bitcode + native code) so lld
# can do cross-language LTO while GNU ld, older rust-lld and GraalVM links still work.

stage_main() {
  local t
  if [ "$HOST_OS" = linux ]; then export TOOLCHAIN_ROOT="$STAGE1_DIR"; else export TOOLCHAIN_ROOT="$BUNDLE_DIR"; fi
  for t in $ALL_TARGETS; do
    case "$(triple_libc "$t")" in
      musl) build_musl_phase2 "$t" ;;
      *) build_mimalloc_standalone "$t" ;;
    esac
  done
}

mimalloc_args() { # OVERRIDE
  printf '%s\n' \
    -DMI_SECURE="$MIMALLOC_SECURE" -DMI_GUARDED="$MIMALLOC_GUARDED" \
    -DMI_OPT_ARCH=ON -DMI_BUILD_SHARED=OFF -DMI_BUILD_STATIC=ON -DMI_BUILD_TESTS=OFF \
    -DMI_INSTALL_TOPLEVEL=ON -DMI_OVERRIDE="$1" -DMI_SKIP_COLLECT_ON_EXIT=ON \
    "-DMI_EXTRA_CPPDEFS=MI_DEFAULT_ARENA_RESERVE=33554432;MI_DEFAULT_ALLOW_LARGE_OS_PAGES=0"
}

build_mimalloc_standalone() {
  local t="$1" override=ON args=()
  # macOS malloc override needs dylib interposing; the static archive exposes the mi_* API only.
  if [ "$(triple_os "$t")" = darwin ]; then override=OFF; fi
  mapfile -t args < <(mimalloc_args "$override")
  cmake_target "$t" "$(stage_source mimalloc "$t")" "$(component_build_dir mimalloc "$t")" \
    "$(target_prefix "$t")" "${args[@]}" -DMI_BUILD_OBJECT=OFF
}

build_musl_phase2() {
  local t="$1" s="$STAGE1_DIR/bin" sysroot prefix tflags lto="" ldflags libcc obj="" glue="" malloc_arg=""
  sysroot="$(sysroot_of "$t")"
  prefix="$(target_prefix "$t")"
  tflags="--target=$t --sysroot=$sysroot"
  ldflags="$tflags -fuse-ld=lld"
  if is_yes "$MUSL_USE_LTO"; then
    lto="-flto=thin -ffat-lto-objects"
    # ldso bootstrap calls __dls2/__dls3 from asm, invisible to LTO: keep them, link libc.so without LTO.
    ldflags="$ldflags -fno-lto -Wl,--undefined=__dls2 -Wl,--undefined=__dls3"
  fi
  libcc="$("$s/clang" --target="$t" -rtlib=compiler-rt -print-libgcc-file-name)"
  [ -f "$libcc" ] || die "compiler-rt builtins missing for $t ($libcc); run 30-runtimes"

  if is_yes "$MUSL_USE_MIMALLOC"; then
    local mi_src mi_build args=()
    mi_src="$(stage_source mimalloc "$t")"
    mi_build="$(component_build_dir mimalloc "$t")"
    mapfile -t args < <(mimalloc_args OFF)   # glue code provides the libc entry points
    cmake -S "$mi_src" -B "$mi_build" -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE="$(toolchain_file "$t")" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      -DCMAKE_C_FLAGS="$(arch_flags "$t") $lto" \
      "${args[@]}" -DMI_LIBC_MUSL=ON -DMI_BUILD_OBJECT=ON
    cmake --build "$mi_build" -j "$JOBS"
    obj="$mi_build/mimalloc.o"
    [ -f "$obj" ] || die "mimalloc.o not produced at $obj"
    glue="$mi_build/mimalloc-musl-glue.o"
    # shellcheck disable=SC2086
    "$s/clang" -c -O3 -fPIC $tflags $lto $(arch_flags "$t") \
      -fno-fast-math -U_FORTIFY_SOURCE -ffunction-sections -fdata-sections \
      -I"$mi_src/include" -I"$prefix/include" \
      "$ROOT_DIR/src/mimalloc-musl-glue.c" -o "$glue"
  else
    malloc_arg="--with-malloc=mallocng"
  fi

  local src cflags cflags_ldso
  src="$(stage_source musl "$t")"
  cflags="$(arch_flags "$t") -ffunction-sections -fdata-sections -fno-fast-math -U_FORTIFY_SOURCE -O3 $tflags $lto"
  cflags_ldso="$(arch_flags "$t") -ffunction-sections -fdata-sections -fno-fast-math -U_FORTIFY_SOURCE -O3 $tflags -fno-lto"
  (
    cd "$src"
    unset CFLAGS CXXFLAGS LDFLAGS CC
    mkdir -p mimalloc/objs
    if [ -n "$obj" ]; then cp "$obj" "$glue" mimalloc/objs/; fi
    # shellcheck disable=SC2086
    ./configure CC="$s/clang" AR="$s/llvm-ar" RANLIB="$s/llvm-ranlib" \
      CFLAGS="-fno-fast-math $tflags $lto" LDFLAGS="$ldflags" \
      --prefix=/usr --syslibdir=/lib --enable-optimize=internal,malloc,string $malloc_arg
    make -j"$JOBS" CC="$s/clang" AR="$s/llvm-ar" RANLIB="$s/llvm-ranlib" \
      CFLAGS_AUTO="$cflags" CFLAGS_MEMOPS="$cflags" CFLAGS_LDSO="$cflags_ldso" \
      LDFLAGS="$ldflags" LIBCC="$libcc" USE_MIMALLOC="$(is_yes "$MUSL_USE_MIMALLOC" && echo yes || echo no)"
    make install DESTDIR="$sysroot" AR="$s/llvm-ar" RANLIB="$s/llvm-ranlib"
  )
  # musl installs the loader as an absolute symlink to /usr/lib/libc.so; make it relocatable.
  ln -sfn ../usr/lib/libc.so "$sysroot/$(musl_loader "$(triple_cpu "$t")")"
  cp "$ROOT_DIR"/mimalloc/include/mimalloc*.h "$prefix/include/"
}
```

- [ ] **Step 3: Run the stage and the check**

Run: `./build.sh --only 35-mimalloc && bash tests/stages/35-mimalloc.check.sh` → Expected: `0 failed`.
If `heap stats` is missing, check that `mimalloc/objs/` held both objects before `make` (`ls $BUILD_DIR/components/<t>/musl/src/mimalloc/objs`) and that the fork's Makefile saw `USE_MIMALLOC=yes`.

- [ ] **Step 4: Commit**

```bash
git add scripts/stages/35-mimalloc.sh tests/stages/35-mimalloc.check.sh
git commit -m "feat: stage 35 — mimalloc; musl phase 2 with mimalloc and fat LTO

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Stage 40 — LLVM stage 2 against glibc 2.34; ELF helpers

**Files:**
- Create: `scripts/verify/elf.sh`, `tests/unit/elf.test.sh`, `scripts/stages/40-llvm-stage2.sh`, `tests/stages/40-llvm-stage2.check.sh`
- Modify: `scripts/lib/env.sh` (source `scripts/verify/elf.sh`)

**Interfaces:**
- Consumes: stage-1 cfg front-ends (Task 12), `$OUT_DIR/llvm-deps` (Task 13), `install_frontends`, `LLVM_PROJECTS_LINUX`.
- Produces (elf.sh): `readelf_bin` (honours `$READELF`), `glibc_needs FILE`, `glibc_floor_violations FILE` (prints one line per violation; empty means OK), `needed_libs FILE`, `interp_of FILE`.
- Produces (stage 40): the shipped `$BUNDLE_DIR/bin/*` and `lib/*` (clang, lld, bolt, polly, llvm tools), linked statically against libc++, needing glibc ≤ 2.34; front-ends installed into `$BUNDLE_DIR`.

- [ ] **Step 1: Write the failing ELF helper test**

`tests/unit/elf.test.sh`:
```bash
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
  0x0000: Version: 1  File: libc.so.6  Cnt: 3
  0x0010:   Name: GLIBC_2.2.5  Flags: none  Version: 2
  0x0020:   Name: GLIBC_2.34  Flags: none  Version: 3
  0x0030:   Name: GLIBC_ABI_DT_RELR  Flags: none  Version: 4
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

assert_eq "$(glibc_needs x | xargs)" "GLIBC_2.2.5 GLIBC_2.34 GLIBC_2.38 GLIBC_ABI_DT_RELR"
v="$(glibc_floor_violations x)"
assert_contains "$v" "GLIBC_2.38"
assert_contains "$v" "GLIBC_ABI_DT_RELR"
assert_not_contains "$v" "GLIBC_2.34"
assert_eq "$(needed_libs x | xargs)" "libc.so.6 libstdc++.so.6"
assert_eq "$(interp_of x)" "/lib64/ld-linux-x86-64.so.2"

rm -rf "$T"
finish
```

- [ ] **Step 2: Run and confirm failure**

Run: `tests/run.sh elf` → Expected: FAIL.

- [ ] **Step 3: Implement `scripts/verify/elf.sh`**

```bash
# shellcheck shell=bash
# ELF inspection helpers for floor and interpreter checks.

readelf_bin() {
  if [ -n "${READELF:-}" ]; then echo "$READELF"; return; fi
  local c
  for c in "$BUNDLE_DIR/bin/llvm-readelf" "$STAGE1_DIR/bin/llvm-readelf"; do
    if [ -x "$c" ]; then echo "$c"; return; fi
  done
  command -v llvm-readelf || command -v readelf
}

# glibc_needs FILE — GLIBC_* version names FILE requires (from .gnu.version_r), sorted.
glibc_needs() {
  "$(readelf_bin)" -V "$1" 2>/dev/null \
    | awk '/Version needs section/{n=1} n { for (i = 1; i <= NF; i++) if ($i ~ /^GLIBC_/) print $i }' \
    | sort -uV
}

# glibc_floor_violations FILE — one line per requirement above GLIBC_FLOOR (or DT_RELR/PRIVATE).
glibc_floor_violations() {
  local f="$1" v
  for v in $(glibc_needs "$f"); do
    case "$v" in
      GLIBC_ABI_DT_RELR|GLIBC_PRIVATE) echo "$f: needs $v" ;;
      GLIBC_[0-9]*) if version_lt "$GLIBC_FLOOR" "${v#GLIBC_}"; then echo "$f: needs $v (floor $GLIBC_FLOOR)"; fi ;;
    esac
  done
  return 0
}

needed_libs() {
  "$(readelf_bin)" -d "$1" 2>/dev/null | awk '/\(NEEDED\)/ { gsub(/[][]/, "", $NF); print $NF }'
}

interp_of() {
  "$(readelf_bin)" -l "$1" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p'
}
```
In `scripts/lib/env.sh`, after the `components.sh` source line, add:
```bash
# shellcheck source=scripts/verify/elf.sh
source "$ROOT_DIR/scripts/verify/elf.sh"
```

- [ ] **Step 4: Run the unit tests**

Run: `tests/run.sh` → Expected: all pass.

- [ ] **Step 5: Write the failing stage-40 check**

`tests/stages/40-llvm-stage2.check.sh` (common header, then):
```bash
[ "$HOST_OS" = linux ] || { echo "skip: linux only"; exit 0; }
b="$BUNDLE_DIR/bin"
for f in clang clang++ ld.lld llvm-ar llvm-nm llvm-ranlib llvm-objcopy llvm-strip llvm-readelf \
         llvm-bolt perf2bolt merge-fdata llvm-profgen llvm-profdata llvm-dwarfdump llvm-dwp; do
  assert_file "$b/$f"
done
assert_fails test -e "$b/lldb"
assert_contains "$("$b/clang" --version)" "clang version $LLVM_VERSION"
for f in "$b/clang" "$b/ld.lld" "$b/llvm-bolt"; do
  assert_eq "$(glibc_floor_violations "$(readlink -f "$f")")" "" "$f within glibc floor"
  libs="$(needed_libs "$(readlink -f "$f")")"
  assert_not_contains "$libs" "libstdc++" "$f has no libstdc++"
  assert_not_contains "$libs" "libgcc_s" "$f has no libgcc_s"
  assert_not_contains "$libs" "libLLVM" "$f does not need libLLVM.so"
done
tmp="$(mktemp -d)"
t="$(bundle_triple_for_libc gnu)"
assert_ok "$b/$t-clang" -g -Wl,--compress-debug-sections=zstd "$ROOT_DIR/tests/fixtures/hello.c" -o "$tmp/z"
for t in $ALL_TARGETS; do
  static=""; [ "$(triple_libc "$t")" = musl ] && static=-static
  # shellcheck disable=SC2086
  assert_ok "$b/$t-clang++" $static "$ROOT_DIR/tests/fixtures/hello.cpp" -o "$tmp/cxx-$t"
  assert_eq "$("$tmp/cxx-$t")" "hello from elide-toolchain"
done
rm -rf "$tmp"
finish
```
Run: `bash tests/stages/40-llvm-stage2.check.sh` → Expected: FAIL.

- [ ] **Step 6: Implement `scripts/stages/40-llvm-stage2.sh`**

```bash
# shellcheck shell=bash
# Stage 40: the shipped LLVM, built by stage-1 clang (via the gnu cfg) against our glibc 2.34
# sysroot, with static libc++/libunwind/compiler-rt and no shared libLLVM/libclang, so the
# tools run on any glibc >= GLIBC_FLOOR host. lld gets zlib + zstd from stage 36.

stage_applies() { [ "$HOST_OS" = linux ]; }

stage_main() {
  local t s="$STAGE1_DIR/bin" b="$BUILD_DIR/llvm-stage2" deps="$OUT_DIR/llvm-deps" af launcher=()
  t="$(bundle_triple_for_libc gnu)"
  af="$(arch_flags "$t")"
  [ -x "$s/$t-clang" ] || die "stage-1 front-ends missing; run 30-runtimes"
  [ -f "$deps/lib/libzstd.a" ] || die "llvm deps missing; run 36-llvm-deps"
  mapfile -t launcher < <(cmake_launcher_args)
  fresh_dir "$b"
  cmake -S "$ROOT_DIR/llvm/llvm" -B "$b" -G Ninja "${launcher[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$BUNDLE_DIR" \
    -DCMAKE_C_COMPILER="$s/$t-clang" -DCMAKE_CXX_COMPILER="$s/$t-clang++" -DCMAKE_ASM_COMPILER="$s/$t-clang" \
    -DCMAKE_AR="$s/llvm-ar" -DCMAKE_RANLIB="$s/llvm-ranlib" -DCMAKE_NM="$s/llvm-nm" \
    -DCMAKE_C_FLAGS="$af" -DCMAKE_CXX_FLAGS="$af" \
    -DCMAKE_PREFIX_PATH="$deps" \
    -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS_LINUX" \
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$t" \
    -DLLVM_ENABLE_LIBCXX=ON -DLLVM_STATIC_LINK_CXX_STDLIB=ON \
    -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF -DCLANG_LINK_CLANG_DYLIB=OFF \
    -DLLVM_ENABLE_LLD=ON \
    -DLLVM_ENABLE_ZLIB=FORCE_ON -DZLIB_ROOT="$deps" \
    -DLLVM_ENABLE_ZSTD=FORCE_ON -DLLVM_USE_STATIC_ZSTD=ON \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_CURL=OFF -DLLVM_ENABLE_HTTPLIB=OFF -DLLVM_ENABLE_FFI=OFF \
    -DLLVM_ENABLE_RTTI=ON -DLLVM_ENABLE_EH=ON \
    -DBOLT_ENABLE_RUNTIME=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF -DCLANG_INCLUDE_TESTS=OFF -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
    -DLLVM_FORCE_VC_REPOSITORY=https://github.com/llvm/llvm-project.git
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
  install_frontends "$BUNDLE_DIR"
}
```

- [ ] **Step 7: Run the stage and the check**

Run: `./build.sh --only 40-llvm-stage2 && bash tests/stages/40-llvm-stage2.check.sh` (60–90 min)
Expected: `0 failed`. If a floor violation shows up, run `glibc_needs` on the binary and find the symbol with `llvm-objdump -T <bin> | grep GLIBC_2.3[5-9]`. That symbol came from the host's headers, so the cause is a missing `--sysroot`: check that `CMAKE_C_COMPILER` is the stage-1 `<gnu>-clang` cfg front-end.

- [ ] **Step 8: Commit**

```bash
git add scripts/verify/elf.sh scripts/lib/env.sh tests/unit/elf.test.sh scripts/stages/40-llvm-stage2.sh tests/stages/40-llvm-stage2.check.sh
git commit -m "feat: stage 40 — LLVM stage 2 against glibc 2.34 with static libc++

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: Remaining component recipes and stage 50

**Files:**
- Create: `scripts/components/{brotli,snappy,lz4,crc32c,aws-lc,openssl,zlib,sqlite,sqlcipher,capnp,hiredis,leveldb}.sh`, `scripts/stages/50-components.sh`, `tests/stages/50-components.check.sh`, `tests/fixtures/components.c`
- Modify: `tests/unit/components.test.sh` (assert every registered component has a recipe)

**Interfaces:**
- Consumes: Task 13 framework; bundle front-ends (Task 15 on Linux, Task 10 on macOS).
- Produces: every enabled component installed into `target_prefix T` for each T in `$TARGETS`.

- [ ] **Step 1: Extend the unit test (failing)**

Append before `rm -rf` in `tests/unit/components.test.sh`:
```bash
for c in "${COMPONENTS[@]}"; do
  assert_ok declare -F "$(component_fn "$c")"
done
```
Run: `tests/run.sh components` → Expected: FAIL for the 12 missing recipes.

- [ ] **Step 2: Write the recipes**

`scripts/components/brotli.sh`:
```bash
# shellcheck shell=bash
# Brotli (static libraries; no CLI).
build_brotli() {
  local t="$1" prefix="$2" src
  src="$(stage_source brotli "$t")"
  cmake_target "$t" "$src" "$(component_build_dir brotli "$t")" "$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DBROTLI_DISABLE_TESTS=ON -DBROTLI_BUILD_TOOLS=OFF
}
```
`scripts/components/snappy.sh`:
```bash
# shellcheck shell=bash
# Snappy (static).
build_snappy() {
  local t="$1" prefix="$2" src
  src="$(stage_source snappy "$t")"
  cmake_target "$t" "$src" "$(component_build_dir snappy "$t")" "$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF -DSNAPPY_INSTALL=ON
}
```
`scripts/components/lz4.sh`:
```bash
# shellcheck shell=bash
# LZ4 (static library, headers, pkg-config).
build_lz4() {
  local t="$1" prefix="$2" src
  src="$(stage_source lz4 "$t")"
  (
    cd "$src"
    target_env "$t" "$prefix"
    make -C lib -j"$JOBS" BUILD_SHARED=no PREFIX="$prefix" \
      CC="$CC" AR="$AR" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" install
  )
}
```
`scripts/components/crc32c.sh`:
```bash
# shellcheck shell=bash
# Google CRC32C (static; no tests/benchmarks/glog, so no nested submodules are needed).
build_crc32c() {
  local t="$1" prefix="$2" src
  src="$(stage_source crc32c "$t")"
  cmake_target "$t" "$src" "$(component_build_dir crc32c "$t")" "$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DCRC32C_BUILD_TESTS=OFF -DCRC32C_BUILD_BENCHMARKS=OFF \
    -DCRC32C_USE_GLOG=OFF -DCRC32C_INSTALL=ON
}
```
`scripts/components/aws-lc.sh`:
```bash
# shellcheck shell=bash
# AWS-LC (libcrypto/libssl). Static (PIC) everywhere; shared libraries as well on Linux.
build_aws_lc() {
  local t="$1" prefix="$2" src shared
  local common=(-DBUILD_LIBSSL=ON -DBUILD_TOOL=OFF -DBUILD_TESTING=OFF -DDISABLE_GO=ON -DDISABLE_PERL=ON)
  src="$(stage_source aws-lc "$t")"
  cmake_target "$t" "$src" "$(component_build_dir aws-lc "$t")" "$prefix" "${common[@]}" \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  if [ "$(triple_os "$t")" = linux ]; then
    shared="$BUILD_DIR/components/$t/aws-lc/build-shared"
    fresh_dir "$shared"
    cmake_target "$t" "$src" "$shared" "$prefix" "${common[@]}" -DBUILD_SHARED_LIBS=ON
  fi
}
```
`scripts/components/openssl.sh`:
```bash
# shellcheck shell=bash
# OpenSSL (static). OPENSSLDIR points at the conventional system location, not the build tree.
openssl_target() {
  case "$1" in
    x86_64-unknown-linux-*) echo linux-x86_64 ;;
    aarch64-unknown-linux-*) echo linux-aarch64 ;;
    arm64-apple-darwin) echo darwin64-arm64-cc ;;
    x86_64-apple-darwin) echo darwin64-x86_64-cc ;;
    *) die "no OpenSSL target for $1" ;;
  esac
}

build_openssl() {
  local t="$1" prefix="$2" src
  src="$(stage_source openssl "$t")"
  (
    cd "$src"
    target_env "$t" "$prefix"
    ./Configure "$(openssl_target "$t")" \
      no-shared no-tests no-docs no-comp no-afalgeng enable-ec_nistp_64_gcc_128 enable-tls1_3 threads \
      --prefix="$prefix" --libdir=lib --openssldir=/etc/ssl \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="$CFLAGS -fPIC" LDFLAGS="$LDFLAGS"
    make -j"$JOBS"
    make install_sw
  )
}
```
`scripts/components/zlib.sh`:
```bash
# shellcheck shell=bash
# Cloudflare's accelerated zlib fork (alternative to zlib-ng; mutually exclusive).
build_zlib() {
  local t="$1" prefix="$2" src extra=()
  src="$(stage_source zlib "$t")"
  if [ "$(triple_cpu "$t")" = x86_64 ]; then extra=(--64); fi
  (
    cd "$src"
    target_env "$t" "$prefix"
    ./configure --prefix="$prefix" --const --static "${extra[@]}"
    make -j"$JOBS" CC="$CC" AR="$AR"
    make install
  )
}
```
`scripts/components/sqlite.sh`:
```bash
# shellcheck shell=bash
# SQLite (static, all features).
build_sqlite() {
  local t="$1" prefix="$2" src
  src="$(stage_source sqlite "$t")"
  (
    cd "$src"
    target_env "$t" "$prefix"
    ./configure --prefix="$prefix" --enable-all --enable-static --disable-shared \
      --enable-fts5 --enable-threadsafe --with-tempstore=yes --disable-tcl
    make -j"$JOBS"
    make install
  )
}
```
`scripts/components/sqlcipher.sh`:
```bash
# shellcheck shell=bash
# SQLCipher (static), installed under <prefix>/sqlcipher so it never shadows SQLite.
build_sqlcipher() {
  local t="$1" prefix="$2" src
  src="$(stage_source sqlcipher "$t")"
  (
    cd "$src"
    target_env "$t" "$prefix"
    CFLAGS="$CFLAGS -DSQLITE_HAS_CODEC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown"
    LDFLAGS="$LDFLAGS -lcrypto"
    export CFLAGS LDFLAGS
    ./configure --prefix="$prefix/sqlcipher" --enable-all --enable-static --disable-shared \
      --enable-fts5 --enable-threadsafe --with-tempstore=yes --disable-tcl
    make -j"$JOBS"
    make install
  )
}
```
`scripts/components/capnp.sh`:
```bash
# shellcheck shell=bash
# Cap'n Proto v1 (static).
build_capnp() {
  local t="$1" prefix="$2" src
  require_cmd autoreconf libtoolize
  src="$(stage_source capnp "$t")"
  (
    cd "$src/c++"
    target_env "$t" "$prefix"
    autoreconf -i
    ./configure --prefix="$prefix" --disable-shared --with-zlib --with-openssl
    make -j"$JOBS"
    make install
  )
}
```
`scripts/components/hiredis.sh`:
```bash
# shellcheck shell=bash
# hiredis with TLS. Its install target also links the shared library, so use the
# non-static link flags even for musl.
build_hiredis() {
  local t="$1" prefix="$2" src
  src="$(stage_source hiredis "$t")"
  (
    cd "$src"
    target_env "$t" "$prefix"
    LDFLAGS="$(target_ldflags "$t")"
    make -j"$JOBS" USE_SSL=1 CC="$CC" AR="$AR" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
      PREFIX="$prefix" OPTIMIZATION=-O3 static pkgconfig install
  )
}
```
`scripts/components/leveldb.sh`:
```bash
# shellcheck shell=bash
# LevelDB (static).
build_leveldb() {
  local t="$1" prefix="$2" src
  src="$(stage_source leveldb "$t")"
  cmake_target "$t" "$src" "$(component_build_dir leveldb "$t")" "$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DLEVELDB_BUILD_TESTS=OFF -DLEVELDB_BUILD_BENCHMARKS=OFF -DLEVELDB_INSTALL=ON
}
```

- [ ] **Step 3: Run the unit tests**

Run: `tests/run.sh` → Expected: all pass.

- [ ] **Step 4: Write the link fixture**

`tests/fixtures/components.c`:
```c
/* Links one symbol from each covered component. HAVE_* macros come from
   component_link in scripts/lib/components.sh. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef HAVE_ZLIB
#include <zlib.h>
#endif
#ifdef HAVE_ZSTD
#include <zstd.h>
#endif
#ifdef HAVE_BROTLI
#include <brotli/decode.h>
#endif
#ifdef HAVE_SNAPPY
#include <snappy-c.h>
#endif
#ifdef HAVE_LZ4
#include <lz4.h>
#endif
#ifdef HAVE_CRC32C
#include <crc32c/crc32c.h>
#endif
#ifdef HAVE_CRYPTO
#include <openssl/crypto.h>
#endif
#ifdef HAVE_MIMALLOC
#include <mimalloc.h>
#endif

int main(void) {
#ifdef HAVE_ZLIB
  printf("zlib %s\n", zlibVersion());
#endif
#ifdef HAVE_ZSTD
  printf("zstd %u\n", ZSTD_versionNumber());
#endif
#ifdef HAVE_BROTLI
  printf("brotli %u\n", BrotliDecoderVersion());
#endif
#ifdef HAVE_SNAPPY
  printf("snappy %zu\n", snappy_max_compressed_length(16));
#endif
#ifdef HAVE_LZ4
  printf("lz4 %d\n", LZ4_versionNumber());
#endif
#ifdef HAVE_CRC32C
  printf("crc32c %u\n", crc32c_value((const uint8_t *)"abc", 3));
#endif
#ifdef HAVE_CRYPTO
  printf("crypto %s\n", OpenSSL_version(OPENSSL_VERSION));
#endif
#ifdef HAVE_MIMALLOC
  void *p = mi_malloc(16);
  mi_free(p);
  printf("mimalloc ok\n");
#endif
  return 0;
}
```

- [ ] **Step 5: Write the failing stage-50 check**

`tests/stages/50-components.check.sh` (common header, then):
```bash
tmp="$(mktemp -d)"
for t in $TARGETS; do
  p="$(target_prefix "$t")"
  defs=() libs=()
  for c in $(enabled_components); do
    found=no
    IFS='|' read -r -a alts <<< "$(component_artifact "$c")"
    for a in "${alts[@]}"; do [ -e "$p/$a" ] && found=yes; done
    assert_eq "$found" yes "$c installed for $t"
    link="$(component_link "$c")"
    if [ -n "$link" ]; then defs+=("-D${link%%|*}"); read -r -a more <<< "${link#*|}"; libs+=("${more[@]}"); fi
  done
  if [ "$(triple_libc "$t")" != musl ]; then defs+=(-DHAVE_MIMALLOC); libs+=(-lmimalloc); fi
  static=(); [ "$(triple_libc "$t")" = musl ] && static=(-static)
  assert_ok "$BUNDLE_DIR/bin/$t-clang" "${defs[@]}" -c "$ROOT_DIR/tests/fixtures/components.c" -o "$tmp/c-$t.o"
  assert_ok "$BUNDLE_DIR/bin/$t-clang++" "${static[@]}" "$tmp/c-$t.o" "${libs[@]}" -lpthread -o "$tmp/c-$t"
  assert_ok "$tmp/c-$t"
done
rm -rf "$tmp"
finish
```
Run: `bash tests/stages/50-components.check.sh` → Expected: FAIL.

- [ ] **Step 6: Implement `scripts/stages/50-components.sh`**

```bash
# shellcheck shell=bash
# Stage 50: build every enabled component for each target into its sysroot (Linux) or
# overlay sysroot (macOS), using the bundle's own <triple>-clang.

stage_main() {
  local t c
  check_component_conflicts
  for t in $TARGETS; do
    mkdir -p "$(target_prefix "$t")"
    for c in "${COMPONENTS[@]}"; do
      component_enabled "$c" || continue
      log "component $c -> $t"
      "$(component_fn "$c")" "$t" "$(target_prefix "$t")"
    done
  done
}
```

- [ ] **Step 7: Run the stage and the check**

Run: `./build.sh --only 50-components && bash tests/stages/50-components.check.sh` (about 15 min)
Expected: `0 failed`. Then turn on the optional components once to prove their recipes work:
```bash
BUILD_SQLITE=yes BUILD_HIREDIS=yes BUILD_LEVELDB=yes ./build.sh --only 50-components --targets x86_64-unknown-linux-gnu
BUILD_SQLITE=yes BUILD_HIREDIS=yes BUILD_LEVELDB=yes bash tests/stages/50-components.check.sh
```
Expected: `0 failed`. (zlib/openssl/sqlcipher/capnp are alternates or need extra host tools. Exercise them the same way with `BUILD_ZLIB_NG=no BUILD_ZLIB=yes`, `BUILD_AWS_LC=no BUILD_OPENSSL=yes BUILD_SQLCIPHER=yes`, and `BUILD_CAPNP=yes` after installing autotools.) Finally, re-run the default `./build.sh --only 50-components` so the sysroots hold the default set.

- [ ] **Step 8: Commit**

```bash
git add scripts/components scripts/stages/50-components.sh tests/stages/50-components.check.sh tests/fixtures/components.c tests/unit/components.test.sh
git commit -m "feat: stage 50 — all component recipes per target

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
## Phase E — Helper, packaging, verification

### Task 17: Helper CLI `bin/elide-toolchain`

**Files:**
- Create: `src/elide-toolchain` (POSIX sh), `tests/unit/helper.test.sh`

**Interfaces:**
- Consumes (at runtime, inside a bundle): `bin/*.cfg` (to discover targets), `share/elide-toolchain/VERSION`, `share/elide-toolchain/cmake/<T>.cmake`.
- Produces (the CLI contract the action and consumers rely on):
  - `elide-toolchain home` prints the bundle root, resolving symlinks.
  - `elide-toolchain targets` prints one triple per line.
  - `elide-toolchain version` prints the bundle version.
  - `elide-toolchain env [--target T] [--static] [--format sh|github|json]`. With no target: `ELIDE_TOOLCHAIN_HOME` only (plus `PATH` in `sh` format). With a target, it adds `CC CXX AR NM RANLIB STRIP CMAKE_TOOLCHAIN_FILE PKG_CONFIG_LIBDIR` (and `PKG_CONFIG_SYSROOT_DIR` on Linux, `SDKROOT` on macOS when unset) plus `CARGO_TARGET_<RUST_TRIPLE>_LINKER`. `--static` adds `LDFLAGS=-static` for musl and exits 1 with a clear message for any other target. `json`/`github` formats never include `PATH`; consumers add `<home>/bin` themselves.
  - `elide-toolchain doctor` compiles and runs C and C++ hello-worlds per target, printing `ok    T` / `FAIL  T`; it exits 1 on any failure.

- [ ] **Step 1: Write the failing test**

`tests/unit/helper.test.sh`:
```bash
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

rm -rf "$T"
finish
```

- [ ] **Step 2: Run and confirm failure**

Run: `tests/run.sh helper` → Expected: FAIL.

- [ ] **Step 3: Implement `src/elide-toolchain`**

```sh
#!/bin/sh
# elide-toolchain — locate and configure an Elide toolchain bundle.
#
# Usage:
#   elide-toolchain home
#   elide-toolchain targets
#   elide-toolchain version
#   elide-toolchain env [--target TRIPLE] [--static] [--format sh|github|json]
#   elide-toolchain doctor
set -eu

die() { echo "elide-toolchain: $*" >&2; exit 1; }

usage() { sed -n '2,10s/^# \{0,1\}//p' "$0"; }

self=$0
while [ -L "$self" ]; do
  link=$(readlink "$self")
  case $link in
    /*) self=$link ;;
    *) self=$(dirname -- "$self")/$link ;;
  esac
done
ROOT=$(CDPATH='' cd -- "$(dirname -- "$self")/.." && pwd -P)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
ENV_FILE=$WORK/env
: > "$ENV_FILE"
TAB=$(printf '\t')

list_targets() {
  for cfg in "$ROOT"/bin/*.cfg; do
    [ -e "$cfg" ] || continue
    name=${cfg##*/}
    echo "${name%.cfg}"
  done
}

has_target() { list_targets | grep -qx -- "$1"; }

rust_triple() {
  case $1 in
    arm64-apple-darwin) echo aarch64-apple-darwin ;;
    *) echo "$1" ;;
  esac
}

add() { printf '%s\t%s\n' "$1" "$2" >> "$ENV_FILE"; }

sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

emit() {
  case $1 in
    sh)
      while IFS=$TAB read -r k v; do printf 'export %s=%s\n' "$k" "$(sh_quote "$v")"; done < "$ENV_FILE"
      printf 'export PATH=%s:"$PATH"\n' "$(sh_quote "$ROOT/bin")"
      ;;
    github)
      while IFS=$TAB read -r k v; do printf '%s=%s\n' "$k" "$v"; done < "$ENV_FILE"
      ;;
    json)
      sep=""
      printf '{'
      while IFS=$TAB read -r k v; do
        printf '%s"%s":"%s"' "$sep" "$k" "$(json_escape "$v")"
        sep=","
      done < "$ENV_FILE"
      printf '}\n'
      ;;
    *) die "unknown format: $1 (expected sh, github or json)" ;;
  esac
}

cmd_env() {
  target="" static=no fmt=sh
  while [ $# -gt 0 ]; do
    case $1 in
      --target) [ $# -ge 2 ] || die "--target needs a triple"; target=$2; shift 2 ;;
      --target=*) target=${1#--target=}; shift ;;
      --static) static=yes; shift ;;
      --format) [ $# -ge 2 ] || die "--format needs a value"; fmt=$2; shift 2 ;;
      --format=*) fmt=${1#--format=}; shift ;;
      *) die "env: unknown option: $1" ;;
    esac
  done
  case $fmt in sh|github|json) ;; *) die "unknown format: $fmt (expected sh, github or json)" ;; esac
  add ELIDE_TOOLCHAIN_HOME "$ROOT"
  if [ -z "$target" ]; then
    [ "$static" = no ] || die "--static requires --target"
    emit "$fmt"
    return
  fi
  has_target "$target" || die "target $target is not in this bundle (have: $(list_targets | tr '\n' ' '))"
  bin=$ROOT/bin
  add CC "$bin/$target-clang"
  add CXX "$bin/$target-clang++"
  add AR "$bin/llvm-ar"
  add NM "$bin/llvm-nm"
  add RANLIB "$bin/llvm-ranlib"
  add STRIP "$bin/llvm-strip"
  add CMAKE_TOOLCHAIN_FILE "$ROOT/share/elide-toolchain/cmake/$target.cmake"
  case $target in
    *-linux-*)
      add PKG_CONFIG_SYSROOT_DIR "$ROOT/sysroot/$target"
      add PKG_CONFIG_LIBDIR "$ROOT/sysroot/$target/usr/lib/pkgconfig:$ROOT/sysroot/$target/usr/share/pkgconfig"
      ;;
    *-apple-darwin)
      add PKG_CONFIG_LIBDIR "$ROOT/sysroot/$target/usr/lib/pkgconfig"
      if [ -z "${SDKROOT:-}" ] && command -v xcrun >/dev/null 2>&1; then add SDKROOT "$(xcrun --show-sdk-path)"; fi
      ;;
  esac
  rt=$(rust_triple "$target" | tr 'abcdefghijklmnopqrstuvwxyz-' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ_')
  add "CARGO_TARGET_${rt}_LINKER" "$bin/$target-clang"
  if [ "$static" = yes ]; then
    case $target in
      *-linux-musl) add LDFLAGS "-static" ;;
      *) die "--static is only supported for musl targets (static glibc is unsupported; use the musl target)" ;;
    esac
  fi
  emit "$fmt"
}

cmd_doctor() {
  printf '#include <stdio.h>\nint main(void){puts("ok");return 0;}\n' > "$WORK/hello.c"
  printf '#include <iostream>\nint main(){std::cout<<"ok"<<std::endl;return 0;}\n' > "$WORK/hello.cpp"
  rc=0
  for t in $(list_targets); do
    extra=""
    case $t in *-linux-musl) extra=-static ;; esac
    # shellcheck disable=SC2086
    if "$ROOT/bin/$t-clang" $extra "$WORK/hello.c" -o "$WORK/c-$t" && "$WORK/c-$t" >/dev/null \
      && "$ROOT/bin/$t-clang++" $extra "$WORK/hello.cpp" -o "$WORK/cxx-$t" && "$WORK/cxx-$t" >/dev/null; then
      echo "ok    $t"
    else
      echo "FAIL  $t"
      rc=1
    fi
  done
  return "$rc"
}

cmd=${1:-help}
[ $# -eq 0 ] || shift
case $cmd in
  home) echo "$ROOT" ;;
  targets) list_targets ;;
  version) cat "$ROOT/share/elide-toolchain/VERSION" ;;
  env) cmd_env "$@" ;;
  doctor) cmd_doctor ;;
  help|-h|--help) usage ;;
  *) die "unknown command: $cmd (try --help)" ;;
esac
```
Run: `chmod +x src/elide-toolchain`

- [ ] **Step 4: Run the tests**

Run: `tests/run.sh` → Expected: all pass; `shellcheck -s sh src/elide-toolchain` is clean. Also run `dash -n src/elide-toolchain` if `dash` is installed. It catches bashisms.

- [ ] **Step 5: Commit**

```bash
git add src/elide-toolchain tests/unit/helper.test.sh
git commit -m "feat: elide-toolchain helper CLI (home/targets/env/doctor)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 18: Stage 90 — packaging, manifest, SBOM, relocation

**Files:**
- Create: `scripts/gen-manifest.py`, `scripts/stages/90-package.sh`, `tests/unit/manifest.test.sh`, `tests/stages/90-package.check.sh`

**Interfaces:**
- Consumes: `versions.env`, `.gitmodules`, the env vars from `env.sh`, `ENABLED_COMPONENTS` (space-separated, set by the stage from `enabled_components`), `install_frontends`, `src/elide-toolchain`.
- Produces:
  - `$DIST_DIR/elide-toolchain-$TOOLCHAIN_VERSION-$HOST_OS-$HOST_ARCH.tar.xz`
  - `….tar.xz.sha256`, formatted `<hex>  <filename>`
  - `….sbom.cdx.json`
  - inside the bundle: `share/elide-toolchain/{VERSION,manifest.json,sbom.cdx.json}`
  - `relocate_prefix T`, which rewrites sysroot `.pc`/`.cmake` paths and deletes `.la` files

- [ ] **Step 1: Write the failing manifest test**

`tests/unit/manifest.test.sh`:
```bash
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
export ENABLED_COMPONENTS="zlib-ng zstd aws-lc"

m="$(python3 "$ROOT_DIR/scripts/gen-manifest.py" manifest)"
q() { printf '%s' "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
assert_eq "$(q 'd["name"]')" "elide-toolchain"
assert_eq "$(q 'd["version"]')" "$TOOLCHAIN_VERSION"
assert_eq "$(q 'd["host"]["glibcFloor"]')" "2.34"
assert_eq "$(q 'd["llvmMajor"]')" "$LLVM_MAJOR"
assert_eq "$(q '" ".join(t["triple"] for t in d["targets"])')" "x86_64-unknown-linux-musl x86_64-unknown-linux-gnu"
assert_eq "$(q '[t["libcVersion"] for t in d["targets"] if t["libc"]=="glibc"][0]')" "2.34"
assert_eq "$(q '" ".join(d["enabledComponents"])')" "zlib-ng zstd aws-lc"
assert_eq "$(q 'd["components"]["llvm"]["version"]')" "$LLVM_VERSION"

s="$(python3 "$ROOT_DIR/scripts/gen-manifest.py" sbom)"
names="$(printf '%s' "$s" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["bomFormat"]=="CycloneDX" and d["specVersion"]=="1.6"; print(" ".join(sorted(c["name"] for c in d["components"])))')"
assert_eq "$names" "aws-lc glibc llvm mimalloc musl zlib-ng zstd"

ELIDE_HOST_OS=darwin ELIDE_HOST_ARCH=arm64 ALL_TARGETS=arm64-apple-darwin HOST_OS=darwin HOST_ARCH=arm64 \
  python3 "$ROOT_DIR/scripts/gen-manifest.py" sbom | python3 -c 'import json,sys; n={c["name"] for c in json.load(sys.stdin)["components"]}; assert "glibc" not in n and "musl" not in n' \
  && ASSERTIONS=$((ASSERTIONS+1)) || _fail "darwin sbom excludes libcs"

rm -rf "$T"
finish
```

- [ ] **Step 2: Run and confirm failure**

Run: `tests/run.sh manifest` → Expected: FAIL.

- [ ] **Step 3: Implement `scripts/gen-manifest.py`**

```python
#!/usr/bin/env python3
"""Generate an elide-toolchain manifest.json or CycloneDX 1.6 SBOM on stdout.

Usage: gen-manifest.py manifest|sbom

Reads versions.env and .gitmodules from $ROOT_DIR, and bundle facts from the environment
exported by scripts/lib/env.sh (HOST_OS, HOST_ARCH, ALL_TARGETS, TOOLCHAIN_VERSION) plus
ENABLED_COMPONENTS (space-separated).
"""
import datetime
import json
import os
import re
import subprocess
import sys
import uuid

ROOT = os.environ["ROOT_DIR"]


def read_env_file(path):
    out = {}
    with open(path) as fh:
        for raw in fh:
            line = raw.strip()
            m = re.match(r"^([A-Z0-9_]+)=(.*)$", line)
            if not m:
                continue
            key, val = m.groups()
            val = re.split(r"\s+#", val, maxsplit=1)[0].strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            out[key] = val
    return out


def submodules():
    """{path: url} for every submodule."""
    def regexp(pattern):
        res = subprocess.run(
            ["git", "config", "-f", os.path.join(ROOT, ".gitmodules"), "--get-regexp", pattern],
            capture_output=True, text=True, check=True)
        return dict(line.split(None, 1) for line in res.stdout.splitlines())
    paths = regexp(r"^submodule\..*\.path$")
    urls = regexp(r"^submodule\..*\.url$")
    return {path: urls[key[: -len(".path")] + ".url"] for key, path in paths.items()}


def var_of(path):
    return path.upper().replace("-", "_")


def component_info(env, path):
    v = var_of(path)
    return {"version": env.get(v + "_VERSION") or env.get(v + "_REF", ""), "revision": env.get(v + "_REV", "")}


def libc_of(triple):
    if triple.endswith("-linux-musl"):
        return "musl"
    if triple.endswith("-linux-gnu"):
        return "glibc"
    return "darwin"


def target_entry(env, triple):
    libc = libc_of(triple)
    entry = {"triple": triple, "libc": libc}
    if libc == "musl":
        entry.update(libcVersion=env["MUSL_VERSION"], libcRevision=env.get("MUSL_REV", ""))
    elif libc == "glibc":
        entry.update(libcVersion=env["GLIBC_FLOOR"], libcRevision=env.get("GLIBC_REV", ""))
    else:
        entry["macosMin"] = env["MACOS_MIN"]
    if libc != "darwin":
        key = "AMD64" if triple.startswith("x86_64") else "ARM64"
        entry.update(march=env["MARCH_" + key], mtune=env["MTUNE_" + key])
    return entry


def core_components(host_os):
    return ["llvm", "mimalloc"] + (["musl", "glibc"] if host_os == "linux" else [])


def git_revision():
    res = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True)
    return res.stdout.strip()


def manifest(env):
    host_os, host_arch = os.environ["HOST_OS"], os.environ["HOST_ARCH"]
    triples = os.environ["ALL_TARGETS"].split()
    host = {"os": host_os, "arch": host_arch}
    if host_os == "linux":
        key = "AMD64" if host_arch == "amd64" else "ARM64"
        host.update(glibcFloor=env["GLIBC_FLOOR"], march=env["MARCH_" + key])
    else:
        host["macosMin"] = env["MACOS_MIN"]
    return {
        "name": env["TOOLCHAIN_NAME"],
        "version": os.environ.get("TOOLCHAIN_VERSION") or env["TOOLCHAIN_VERSION"],
        "revision": git_revision(),
        "host": host,
        "llvmMajor": env["LLVM_VERSION"].split(".")[0],
        "targets": [target_entry(env, t) for t in triples],
        "enabledComponents": os.environ.get("ENABLED_COMPONENTS", "").split(),
        "components": {p: component_info(env, p) for p in sorted(submodules())},
        "cflagsProfile": f"{host_os}-{host_arch}",
    }


def purl(url, name, version, rev):
    m = re.match(r"https://github\.com/([^/]+)/([^/.]+)(\.git)?$", url)
    if m:
        return f"pkg:github/{m.group(1)}/{m.group(2)}@{rev or version}"
    return f"pkg:generic/{name}@{version}?vcs_url=git%2B{url}%40{rev}"


def sbom(env):
    m = manifest(env)
    urls = submodules()
    wanted = core_components(m["host"]["os"]) + m["enabledComponents"]
    comps = []
    for name in sorted(set(wanted)):
        info = m["components"].get(name, {"version": "", "revision": ""})
        url = urls.get(name, "")
        comps.append({
            "type": "library",
            "name": name,
            "version": info["version"],
            "purl": purl(url, name, info["version"], info["revision"]),
            "externalReferences": [{"type": "vcs", "url": url}] if url else [],
        })
    return {
        "$schema": "http://cyclonedx.org/schema/bom-1.6.schema.json",
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "component": {
                "type": "application",
                "name": m["name"],
                "version": m["version"],
                "purl": f"pkg:generic/elide/{m['name']}@{m['version']}",
                "supplier": {"name": "Elide", "url": ["https://elide.dev"]},
            },
        },
        "components": comps,
    }


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("manifest", "sbom"):
        print(__doc__, file=sys.stderr)
        return 2
    env = read_env_file(os.path.join(ROOT, "versions.env"))
    doc = manifest(env) if sys.argv[1] == "manifest" else sbom(env)
    json.dump(doc, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```
Run: `chmod +x scripts/gen-manifest.py && tests/run.sh manifest` → Expected: `0 failed`.

- [ ] **Step 4: Write the failing package check**

`tests/stages/90-package.check.sh` (common header, then):
```bash
name="$TOOLCHAIN_NAME-$TOOLCHAIN_VERSION-$HOST_OS-$HOST_ARCH"
a="$DIST_DIR/$name.tar.xz"
assert_file "$a"
assert_file "$a.sha256"
assert_file "$DIST_DIR/$name.sbom.cdx.json"
assert_eq "$(awk '{print $1}' "$a.sha256")" "$(sha256_of "$a")" "checksum matches"
assert_eq "$(awk '{print $2}' "$a.sha256")" "$name.tar.xz" "checksum names the file"
listing="$(tar -tJf "$a")"
assert_eq "$(printf '%s\n' "$listing" | cut -d/ -f1 | sort -u)" "$TOOLCHAIN_NAME" "single top-level dir"
for f in bin/elide-toolchain share/elide-toolchain/manifest.json share/elide-toolchain/VERSION share/elide-toolchain/sbom.cdx.json; do
  assert_contains "$listing" "$TOOLCHAIN_NAME/$f"
done
for t in $ALL_TARGETS; do
  assert_contains "$listing" "$TOOLCHAIN_NAME/bin/$t.cfg"
  assert_contains "$listing" "$TOOLCHAIN_NAME/share/elide-toolchain/cmake/$t.cmake"
  leaks="$(grep -rlF "$BUNDLE_DIR" --include='*.pc' --include='*.cmake' "$(sysroot_of "$t")" || true)"
  assert_eq "$leaks" "" "no build paths in $t .pc/.cmake files"
  assert_eq "$(find "$(sysroot_of "$t")" -name '*.la' | head -1)" "" "no libtool archives"
done
finish
```
Run: `bash tests/stages/90-package.check.sh` → Expected: FAIL.

- [ ] **Step 5: Implement `scripts/stages/90-package.sh`**

```bash
# shellcheck shell=bash
# Stage 90: finalize the bundle (front-ends, helper, metadata, relocatable sysroots, stripped
# tools) and write the archive, checksum and SBOM to $DIST_DIR.

stage_main() {
  local name archive meta="$BUNDLE_DIR/share/elide-toolchain" t
  install_frontends "$BUNDLE_DIR"
  install -m 0755 "$ROOT_DIR/src/elide-toolchain" "$BUNDLE_DIR/bin/elide-toolchain"
  mkdir -p "$meta"
  printf '%s\n' "$TOOLCHAIN_VERSION" > "$meta/VERSION"
  for t in $ALL_TARGETS; do relocate_prefix "$t"; done
  ENABLED_COMPONENTS="$(enabled_components | xargs)" python3 "$ROOT_DIR/scripts/gen-manifest.py" manifest > "$meta/manifest.json"
  ENABLED_COMPONENTS="$(enabled_components | xargs)" python3 "$ROOT_DIR/scripts/gen-manifest.py" sbom > "$meta/sbom.cdx.json"
  strip_tools

  name="$TOOLCHAIN_NAME-$TOOLCHAIN_VERSION-$HOST_OS-$HOST_ARCH"
  archive="$DIST_DIR/$name.tar.xz"
  mkdir -p "$DIST_DIR"
  rm -f "$archive" "$archive.sha256"
  XZ_OPT="-T0 -9" tar -C "$OUT_DIR" -cJf "$archive" "$TOOLCHAIN_NAME"
  printf '%s  %s\n' "$(sha256_of "$archive")" "$name.tar.xz" > "$archive.sha256"
  cp "$meta/sbom.cdx.json" "$DIST_DIR/$name.sbom.cdx.json"
  log "wrote $archive"
}

# relocate_prefix TRIPLE — make a sysroot's metadata location-independent: .pc files use
# prefix=/usr (Linux, with PKG_CONFIG_SYSROOT_DIR) or ${pcfiledir} (macOS overlay); CMake
# package files use CMAKE_CURRENT_LIST_DIR; libtool .la files are removed.
relocate_prefix() {
  local t="$1" sysroot usr stage1_usr f up
  sysroot="$(sysroot_of "$t")"
  usr="$sysroot/usr"
  stage1_usr="$STAGE1_DIR/sysroot/$t/usr"
  find "$sysroot" -name '*.la' -delete
  while IFS= read -r f; do
    if [ "$(triple_os "$t")" = linux ]; then
      sed -i.bak -e "s#$usr#/usr#g" -e "s#$stage1_usr#/usr#g" "$f"
    else
      sed -i.bak -e "s#$usr#\${pcfiledir}/../..#g" "$f"
    fi
    rm -f "$f.bak"
  done < <(find "$sysroot" -name '*.pc')
  while IFS= read -r f; do
    up="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[2], os.path.dirname(sys.argv[1])))' "$f" "$usr")"
    sed -i.bak -e "s#$usr#\${CMAKE_CURRENT_LIST_DIR}/$up#g" -e "s#$stage1_usr#\${CMAKE_CURRENT_LIST_DIR}/$up#g" "$f"
    rm -f "$f.bak"
  done < <(grep -rlF -e "$usr" -e "$stage1_usr" --include='*.cmake' "$sysroot" || true)
  return 0
}

strip_tools() {
  local f s="$BUNDLE_DIR/bin/llvm-strip"
  for f in "$BUNDLE_DIR"/bin/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    if [ "$HOST_OS" = linux ]; then
      if is_elf "$f"; then "$s" --strip-unneeded "$f"; fi
    else
      "$s" -x "$f" 2>/dev/null || true
    fi
  done
  return 0
}
```

- [ ] **Step 6: Run the stage and the check**

Run: `./build.sh --only 90-package && bash tests/stages/90-package.check.sh` → Expected: `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/gen-manifest.py scripts/stages/90-package.sh tests/unit/manifest.test.sh tests/stages/90-package.check.sh
git commit -m "feat: stage 90 — relocatable packaging with manifest and SBOM

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 19: Stage 95 — verification

**Files:**
- Create: `scripts/verify/checks.sh`, `scripts/stages/95-verify.sh`

**Interfaces:**
- Consumes: `elf.sh` helpers, `$OUT_DIR/glibc-files.txt`, `enabled_components`, `component_link`, the fixtures, the dist archive.
- Produces: `run_all_checks ROOT`, which exits non-zero on any failed check. Each check prints `ok    <name>` or `FAIL  <name>: <detail>`.

The checks *are* the tests (spec §6). TDD here means proving that each check fails on a deliberately broken bundle (Step 3) before trusting it to pass (Step 4).

- [ ] **Step 1: Implement `scripts/verify/checks.sh`**

```bash
# shellcheck shell=bash
# Bundle verification (spec §6). Operates on an extracted bundle ROOT, never on the build tree.

VERIFY_FAILURES=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }

smoke_dir() { printf '%s/smoke/%s\n' "$VERIFY_DIR" "$1"; }

# check_smoke ROOT TRIPLE — C and C++ hello-worlds compile, link and run (musl: fully static).
check_smoke() {
  local root="$1" t="$2" d static=() name="smoke $2${3:+ ($3)}"
  d="$(smoke_dir "$t")${3:+-$3}"
  mkdir -p "$d"
  if [ "$(triple_libc "$t")" = musl ]; then static=(-static); fi
  if ! "$root/bin/$t-clang" "${static[@]}" "$ROOT_DIR/tests/fixtures/hello.c" -o "$d/hello-c" 2>"$d/err"; then
    fail "$name" "C compile: $(head -3 "$d/err")"; return
  fi
  if ! "$root/bin/$t-clang++" "${static[@]}" "$ROOT_DIR/tests/fixtures/hello.cpp" -o "$d/hello-cxx" 2>"$d/err"; then
    fail "$name" "C++ compile: $(head -3 "$d/err")"; return
  fi
  if [ "$("$d/hello-c")" != "hello from elide-toolchain" ] || [ "$("$d/hello-cxx")" != "hello from elide-toolchain" ]; then
    fail "$name" "programs did not print the expected output"; return
  fi
  if [ "$(triple_libc "$t")" = musl ] && [ -n "$(interp_of "$d/hello-c")" ]; then
    fail "$name" "musl output is not static"; return
  fi
  pass "$name"
}

check_werror() {
  local root="$1" t="$2" tmp
  tmp="$(mktemp -d)"
  if "$root/bin/$t-clang" -Werror -c "$ROOT_DIR/tests/fixtures/hello.c" -o "$tmp/h.o" 2>"$tmp/err"; then
    pass "werror $t"
  else
    fail "werror $t" "$(head -3 "$tmp/err")"
  fi
  rm -rf "$tmp"
}

check_components() {
  local root="$1" t="$2" c link defs=() libs=() more=() static=() tmp
  for c in $(enabled_components); do
    link="$(component_link "$c")"
    [ -n "$link" ] || continue
    defs+=("-D${link%%|*}")
    read -r -a more <<< "${link#*|}"
    libs+=("${more[@]}")
  done
  if [ "$(triple_libc "$t")" != musl ]; then defs+=(-DHAVE_MIMALLOC); libs+=(-lmimalloc); else static=(-static); fi
  tmp="$(mktemp -d)"
  if "$root/bin/$t-clang" "${defs[@]}" -c "$ROOT_DIR/tests/fixtures/components.c" -o "$tmp/c.o" 2>"$tmp/err" \
    && "$root/bin/$t-clang++" "${static[@]}" "$tmp/c.o" "${libs[@]}" -lpthread -o "$tmp/c" 2>>"$tmp/err" \
    && "$tmp/c" >/dev/null 2>>"$tmp/err"; then
    pass "components $t"
  else
    fail "components $t" "$(head -5 "$tmp/err")"
  fi
  rm -rf "$tmp"
}

# check_glibc_floor ROOT TRIPLE — shipped tools, gnu-sysroot shared objects (excluding glibc's
# own files) and smoke outputs need nothing newer than GLIBC_FLOOR, and no libstdc++/libgcc_s.
check_glibc_floor() {
  local root="$1" t="$2" f rel v out="" sysroot="$root/sysroot/$2"
  while IFS= read -r f; do
    is_elf "$f" || continue
    rel="${f#"$sysroot"/}"
    if [ "$f" != "$rel" ] && grep -qxF "$rel" "$OUT_DIR/glibc-files.txt"; then continue; fi
    v="$(glibc_floor_violations "$f")"
    [ -z "$v" ] || out="$out$v"$'\n'
    case " $(needed_libs "$f" | xargs) " in
      *" libstdc++"*|*" libgcc_s"*) out="$out$f: needs libstdc++/libgcc_s"$'\n' ;;
    esac
  done < <(find "$root/bin" "$root/lib" "$sysroot/usr/lib" "$(smoke_dir "$t")" -type f \( -perm -u+x -o -name '*.so*' \) 2>/dev/null)
  if [ -z "$out" ]; then pass "glibc floor $t"; else fail "glibc floor $t" "$(printf '%s' "$out" | head -10)"; fi
}

check_interp() {
  local t="$2" want got
  want="/$(glibc_loader "$(triple_cpu "$t")")"
  got="$(interp_of "$(smoke_dir "$t")/hello-c")"
  if [ "$got" = "$want" ]; then pass "interp $t"; else fail "interp $t" "PT_INTERP $got, want $want"; fi
}

check_musl_libc() {
  local root="$1" t="$2" lib="$root/sysroot/$2/usr/lib/libc.a" tmp member sections
  tmp="$(mktemp -d)"
  member="$("$root/bin/llvm-ar" t "$lib" | grep -m1 '^printf\.')"
  (cd "$tmp" && "$root/bin/llvm-ar" x "$lib" "$member")
  sections="$("$root/bin/llvm-readelf" -S "$tmp/$member")"
  if is_yes "$MUSL_USE_LTO"; then
    case "$sections" in *.llvm.lto*) ;; *) fail "musl libc $t" "no .llvm.lto section in $member"; rm -rf "$tmp"; return ;; esac
    "$root/bin/llvm-objcopy" --dump-section ".llvm.lto=$tmp/bc" "$tmp/$member" "$tmp/discard.o"
    if ! "$root/bin/llvm-dis" "$tmp/bc" -o - 2>/dev/null | grep -q "target triple = \"$t\""; then
      fail "musl libc $t" "bitcode triple is not $t"; rm -rf "$tmp"; return
    fi
  fi
  case "$sections" in *" .text"*) ;; *) fail "musl libc $t" "no native .text in $member"; rm -rf "$tmp"; return ;; esac
  if ! "$root/bin/$t-clang" -static -fno-lto "$ROOT_DIR/tests/fixtures/hello.c" -o "$tmp/h" 2>/dev/null || ! "$tmp/h" >/dev/null; then
    fail "musl libc $t" "non-LTO static link failed"; rm -rf "$tmp"; return
  fi
  rm -rf "$tmp"
  pass "musl libc $t"
}

check_shims() {
  local root="$1" t="$2" p tmp
  p="$(musl_gcc_prefix "$t")"
  tmp="$(mktemp -d)"
  if "$root/bin/$p-gcc" -static "$ROOT_DIR/tests/fixtures/hello.c" -o "$tmp/h" 2>"$tmp/err" && "$tmp/h" >/dev/null; then
    pass "gcc shims $t"
  else
    fail "gcc shims $t" "$(head -3 "$tmp/err")"
  fi
  rm -rf "$tmp"
}

# check_containers ROOT — gnu output and the shipped clang run on glibc-2.34-era distros.
check_containers() {
  local root="$1" gnu musl image cmd
  gnu="$(bundle_triple_for_libc gnu)"
  musl="$(bundle_triple_for_libc musl)"
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    if is_yes "$REQUIRE_CONTAINER_CHECKS"; then fail "containers" "docker unavailable"; else warn "docker unavailable; skipping container checks"; fi
    return
  fi
  cmd="/smoke-gnu/hello-c && /smoke-gnu/hello-cxx && /smoke-musl/hello-c && /tc/bin/clang --version >/dev/null \
    && /tc/bin/$gnu-clang /src/hello.c -o /tmp/h && /tmp/h"
  for image in almalinux:9 ubuntu:22.04; do
    if docker run --rm -v "$root:/tc:ro" -v "$(smoke_dir "$gnu"):/smoke-gnu:ro" -v "$(smoke_dir "$musl"):/smoke-musl:ro" \
        -v "$ROOT_DIR/tests/fixtures:/src:ro" "$image" sh -c "$cmd" >/dev/null 2>"$VERIFY_DIR/docker.err"; then
      pass "container $image"
    else
      fail "container $image" "$(tail -3 "$VERIFY_DIR/docker.err")"
    fi
  done
}

check_macos_minos() {
  local root="$1" t="$2" f minos out=""
  while IFS= read -r f; do
    file -b "$f" | grep -q Mach-O || continue
    minos="$(vtool -show-build "$f" 2>/dev/null | awk '/minos/{print $2; exit}')"
    if [ -n "$minos" ] && version_lt "$MACOS_MIN" "$minos"; then out="$out$f: minos $minos"$'\n'; fi
  done < <(find "$root/bin" "$(smoke_dir "$t")" -type f -perm -u+x)
  if [ -z "$out" ]; then pass "macos minos $t"; else fail "macos minos $t" "$(printf '%s' "$out" | head -5)"; fi
}

check_darwin_dylibs() {
  local root="$1" f bad=""
  while IFS= read -r f; do
    file -b "$f" | grep -q Mach-O || continue
    bad="$bad$(otool -L "$f" | tail -n +2 | awk '{print $1}' \
      | grep -vE '^(/usr/lib/|/System/|@rpath/|@loader_path/|@executable_path/)' | sed "s#^#$f: #")"
  done < <(find "$root/bin" -type f -perm -u+x)
  if [ -z "$bad" ]; then pass "darwin dylibs"; else fail "darwin dylibs" "$(printf '%s' "$bad" | head -5)"; fi
}

check_no_build_paths() {
  local root="$1" leaks abs
  leaks="$(grep -rIlF "$ROOT_DIR" "$root" 2>/dev/null | head -5 || true)"
  abs="$(find "$root" -type l -lname '/*' | head -5)"
  if [ -n "$leaks" ]; then fail "no build paths" "text files mention $ROOT_DIR: $leaks"
  elif [ -n "$abs" ]; then fail "no build paths" "absolute symlinks: $abs"
  else pass "no build paths"; fi
}

check_manifest() {
  local root="$1" v
  v="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$root/share/elide-toolchain/manifest.json" 2>/dev/null || true)"
  if [ "$v" = "$TOOLCHAIN_VERSION" ] && [ "$("$root/bin/elide-toolchain" version)" = "$TOOLCHAIN_VERSION" ]; then
    pass "manifest"
  else
    fail "manifest" "manifest/VERSION do not report $TOOLCHAIN_VERSION"
  fi
}

# check_relocatable ROOT — copy the bundle under a path containing a space and rerun the smoke tests.
check_relocatable() {
  local root="$1" moved t
  moved="$VERIFY_DIR/reloc test/$TOOLCHAIN_NAME"
  rm -rf "$VERIFY_DIR/reloc test"; mkdir -p "$VERIFY_DIR/reloc test"
  cp -a "$root" "$moved"
  for t in $ALL_TARGETS; do check_smoke "$moved" "$t" relocated; done
  if "$moved/bin/elide-toolchain" doctor >/dev/null; then pass "doctor (relocated)"; else fail "doctor (relocated)" "see elide-toolchain doctor"; fi
  rm -rf "$VERIFY_DIR/reloc test"
}

run_all_checks() {
  local root="$1" t
  check_manifest "$root"
  check_no_build_paths "$root"
  for t in $ALL_TARGETS; do
    check_smoke "$root" "$t"
    check_werror "$root" "$t"
    check_components "$root" "$t"
    case "$(triple_libc "$t")" in
      gnu) check_glibc_floor "$root" "$t"; check_interp "$root" "$t" ;;
      musl) check_musl_libc "$root" "$t"; check_shims "$root" "$t" ;;
      darwin) check_macos_minos "$root" "$t" ;;
    esac
  done
  if [ "$HOST_OS" = linux ]; then check_containers "$root"; else check_darwin_dylibs "$root"; fi
  check_relocatable "$root"
  echo "verification: $VERIFY_FAILURES failure(s)"
  [ "$VERIFY_FAILURES" -eq 0 ]
}
```

- [ ] **Step 2: Implement `scripts/stages/95-verify.sh`**

```bash
# shellcheck shell=bash
# Stage 95: verify the packaged archive (not the build tree): checksum, then every check in
# scripts/verify/checks.sh against a fresh extraction.

# shellcheck source=scripts/verify/checks.sh
source "$ROOT_DIR/scripts/verify/checks.sh"

stage_main() {
  local name archive
  name="$TOOLCHAIN_NAME-$TOOLCHAIN_VERSION-$HOST_OS-$HOST_ARCH"
  archive="$DIST_DIR/$name.tar.xz"
  [ -f "$archive" ] || die "missing $archive; run 90-package"
  [ "$(awk '{print $1}' "$archive.sha256")" = "$(sha256_of "$archive")" ] || die "checksum mismatch for $archive"
  export VERIFY_DIR="$OUT_DIR/verify"
  fresh_dir "$VERIFY_DIR"
  tar -C "$VERIFY_DIR" -xJf "$archive"
  run_all_checks "$VERIFY_DIR/$TOOLCHAIN_NAME"
}
```

- [ ] **Step 3: Prove the checks catch breakage**

Corrupt a scratch copy of the archive in three known ways, then run the checks against each copy:
```bash
./build.sh --only 95-verify   # baseline: expect "0 failure(s)"
V=out/neg; rm -rf $V; mkdir -p $V; tar -C $V -xJf dist/elide-toolchain-*-linux-amd64.tar.xz
# (a) a build-path leak, (b) an absolute symlink, (c) a DT_RELR-linked gnu binary
echo "$PWD/out/x" > $V/elide-toolchain/share/leak.txt
ln -s /usr/lib/libc.so $V/elide-toolchain/sysroot/x86_64-unknown-linux-gnu/usr/lib/bad.so
$V/elide-toolchain/bin/x86_64-unknown-linux-gnu-clang -Wl,-z,pack-relative-relocs tests/fixtures/hello.c -o $V/elide-toolchain/bin/relr-probe
ROOT_DIR=$PWD bash -c 'source scripts/lib/env.sh; source scripts/verify/checks.sh; VERIFY_DIR=$PWD/out/neg; check_no_build_paths out/neg/elide-toolchain; check_glibc_floor out/neg/elide-toolchain x86_64-unknown-linux-gnu'
```
Expected: `FAIL  no build paths …` and `FAIL  glibc floor … GLIBC_ABI_DT_RELR`. If either check prints `ok`, it's broken: fix the check before continuing. Then `rm -rf out/neg`.

- [ ] **Step 4: Run the full verification**

Run: `./build.sh --only 95-verify`
Expected: every line is `ok`, ending with `verification: 0 failure(s)`. With Docker available locally, both container lines must pass.
If `werror <triple>` fails with `-Wunused-command-line-argument` (cfg link flags on a compile-only call), append `"-Qunused-arguments"` as the last `printf` argument in both branches of `render_cfg` (Task 9). Add `assert_contains "$cfg" "-Qunused-arguments"` to `tests/unit/frontends.test.sh`, then rerun `tests/run.sh`, `./build.sh --from 90-package`.

- [ ] **Step 5: Commit**

```bash
git add scripts/verify/checks.sh scripts/stages/95-verify.sh
git commit -m "feat: stage 95 — bundle verification (floors, relocatability, containers)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
## Phase F — Distribution

### Task 20: GitHub Action rewrite

**Files:**
- Create: `action/lib.ts`, `action/lib.test.ts`
- Rewrite: `action/main.ts`, `action/action.yml`, `action/package.json`, `action/dist/main.js` (built)

**Interfaces:**
- Consumes: the helper CLI contract (Task 17) and the asset naming (Task 18).
- Produces (lib.ts): `detectPlatform(platform, arch): Platform`, `parsePlatformOverride(os, arch, detected): Platform`, `normalizeVersion(v): string`, `assetName(version, platform): string`, `releaseUrl(repo, version, asset)`, `mirrorUrl(baseUrl, version, asset)`, `resolveVersion(input, opts): Promise<string>`, `parseSha256File(text): string`, `parseEnvJson(text): Record<string,string>`; constants `TOOL_NAME`, `DEFAULT_REPO`, `DEFAULT_BASE_URL`.
- Action inputs: `version` (default `latest`), `target`, `github-token` (default `${{ github.token }}`), `os`, `arch`, `archive`, `base-url`, `repo`. Outputs: `home`, `version`, `targets` (a JSON array).

- [ ] **Step 1: Write the failing tests**

`action/lib.test.ts`:
```ts
import { describe, expect, test } from "bun:test";
import {
  assetName, detectPlatform, mirrorUrl, normalizeVersion, parseEnvJson,
  parsePlatformOverride, parseSha256File, releaseUrl, resolveVersion,
} from "./lib";

describe("platform", () => {
  test("maps node platform/arch", () => {
    expect(detectPlatform("linux", "x64")).toEqual({ os: "linux", arch: "amd64" });
    expect(detectPlatform("darwin", "arm64")).toEqual({ os: "darwin", arch: "arm64" });
  });
  test("rejects unsupported", () => {
    expect(() => detectPlatform("win32", "x64")).toThrow(/Unsupported OS/);
    expect(() => detectPlatform("linux", "ia32")).toThrow(/Unsupported architecture/);
  });
  test("overrides", () => {
    const d = { os: "linux", arch: "amd64" } as const;
    expect(parsePlatformOverride("", "", d)).toEqual(d);
    expect(parsePlatformOverride("darwin", "arm64", d)).toEqual({ os: "darwin", arch: "arm64" });
    expect(() => parsePlatformOverride("windows", "", d)).toThrow(/Invalid os/);
  });
});

describe("versions and urls", () => {
  test("normalizes", () => {
    expect(normalizeVersion("v2026.10.0")).toBe("2026.10.0");
    expect(normalizeVersion(" 2026.10.3\n")).toBe("2026.10.3");
    expect(normalizeVersion("2026.10.0-dev.abc1234")).toBe("2026.10.0-dev.abc1234");
    expect(() => normalizeVersion("1.2.5")).toThrow(/Invalid version/);
  });
  test("asset and urls", () => {
    const a = assetName("2026.10.0", { os: "linux", arch: "arm64" });
    expect(a).toBe("elide-toolchain-2026.10.0-linux-arm64.tar.xz");
    expect(releaseUrl("elide-dev/toolchain", "2026.10.0", a))
      .toBe("https://github.com/elide-dev/toolchain/releases/download/v2026.10.0/" + a);
    expect(mirrorUrl("https://static.example.com/", "2026.10.0", a))
      .toBe("https://static.example.com/toolchain/2026.10.0/" + a);
  });
});

describe("resolveVersion", () => {
  const base = { repo: "elide-dev/toolchain", baseUrl: "https://m.example" };
  test("pinned version skips network", async () => {
    const fetchers = { json: async () => { throw new Error("no"); }, text: async () => { throw new Error("no"); } };
    expect(await resolveVersion("v2026.10.1", { ...base, fetchers })).toBe("2026.10.1");
  });
  test("latest via releases API, with token", async () => {
    let seen: Record<string, string> = {};
    const fetchers = {
      json: async (_u: string, h: Record<string, string>) => { seen = h; return { tag_name: "v2026.11.2" }; },
      text: async () => "",
    };
    expect(await resolveVersion("latest", { ...base, token: "t0k", fetchers })).toBe("2026.11.2");
    expect(seen.Authorization).toBe("Bearer t0k");
  });
  test("falls back to mirror latest.txt", async () => {
    const warnings: string[] = [];
    const fetchers = {
      json: async () => { throw new Error("rate limited"); },
      text: async (u: string) => { expect(u).toBe("https://m.example/toolchain/latest.txt"); return "2026.10.4\n"; },
    };
    expect(await resolveVersion("", { ...base, fetchers, warn: (m) => warnings.push(m) })).toBe("2026.10.4");
    expect(warnings.length).toBe(1);
  });
});

describe("parsers", () => {
  test("sha256 file", () => {
    const h = "a".repeat(64);
    expect(parseSha256File(`${h}  elide-toolchain-x.tar.xz\n`)).toBe(h);
    expect(() => parseSha256File("nope")).toThrow(/Invalid SHA256/);
  });
  test("env json", () => {
    expect(parseEnvJson('{"CC":"/x/bin/cc"}')).toEqual({ CC: "/x/bin/cc" });
    expect(() => parseEnvJson("[]")).toThrow(/not a JSON object/);
    expect(() => parseEnvJson('{"A":1}')).toThrow(/not a string/);
  });
});
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd action && bun test` → Expected: FAIL (`Cannot find module './lib'`).

- [ ] **Step 3: Implement `action/lib.ts`**

```ts
export type Os = "linux" | "darwin";
export type Arch = "amd64" | "arm64";
export interface Platform { os: Os; arch: Arch }

export const TOOL_NAME = "elide-toolchain";
export const DEFAULT_REPO = "elide-dev/toolchain";
export const DEFAULT_BASE_URL = "https://static.elideusercontent.com";

export function detectPlatform(platform: string, arch: string): Platform {
  const os: Os | null = platform === "linux" ? "linux" : platform === "darwin" ? "darwin" : null;
  if (!os) throw new Error(`Unsupported OS: ${platform} (supported: linux, darwin)`);
  const a: Arch | null = arch === "x64" ? "amd64" : arch === "arm64" ? "arm64" : null;
  if (!a) throw new Error(`Unsupported architecture: ${arch} (supported: x64, arm64)`);
  return { os, arch: a };
}

export function parsePlatformOverride(os: string, arch: string, detected: Platform): Platform {
  const o = os || detected.os;
  const a = arch || detected.arch;
  if (o !== "linux" && o !== "darwin") throw new Error(`Invalid os input: ${o} (linux or darwin)`);
  if (a !== "amd64" && a !== "arm64") throw new Error(`Invalid arch input: ${a} (amd64 or arm64)`);
  return { os: o, arch: a };
}

export function normalizeVersion(v: string): string {
  const s = v.trim().replace(/^v/, "");
  if (!/^\d{4}\.\d{1,2}\.\d+([-+][0-9A-Za-z.-]+)?$/.test(s)) {
    throw new Error(`Invalid version: ${v} (expected YYYY.MM.N or 'latest')`);
  }
  return s;
}

export function assetName(version: string, p: Platform): string {
  return `${TOOL_NAME}-${version}-${p.os}-${p.arch}.tar.xz`;
}

export function releaseUrl(repo: string, version: string, asset: string): string {
  return `https://github.com/${repo}/releases/download/v${version}/${asset}`;
}

export function mirrorUrl(baseUrl: string, version: string, asset: string): string {
  return `${baseUrl.replace(/\/+$/, "")}/toolchain/${version}/${asset}`;
}

export interface Fetchers {
  json(url: string, headers: Record<string, string>): Promise<any>;
  text(url: string): Promise<string>;
}

export interface ResolveOptions {
  repo: string;
  baseUrl: string;
  token?: string;
  fetchers: Fetchers;
  warn?: (message: string) => void;
}

export async function resolveVersion(input: string, opts: ResolveOptions): Promise<string> {
  const want = (input || "latest").trim();
  if (want !== "latest") return normalizeVersion(want);
  try {
    const headers: Record<string, string> = { Accept: "application/vnd.github+json" };
    if (opts.token) headers.Authorization = `Bearer ${opts.token}`;
    const release = await opts.fetchers.json(`https://api.github.com/repos/${opts.repo}/releases/latest`, headers);
    return normalizeVersion(String(release.tag_name));
  } catch (e) {
    opts.warn?.(`GitHub Releases lookup failed (${e}); falling back to mirror`);
    const text = await opts.fetchers.text(`${opts.baseUrl.replace(/\/+$/, "")}/toolchain/latest.txt`);
    return normalizeVersion(text);
  }
}

export function parseSha256File(content: string): string {
  const hash = (content.trim().split(/\s+/)[0] ?? "").toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(hash)) throw new Error(`Invalid SHA256 file content: ${content}`);
  return hash;
}

export function parseEnvJson(text: string): Record<string, string> {
  const obj: unknown = JSON.parse(text);
  if (typeof obj !== "object" || obj === null || Array.isArray(obj)) throw new Error("env output is not a JSON object");
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v !== "string") throw new Error(`env value for ${k} is not a string`);
  }
  return obj as Record<string, string>;
}
```

- [ ] **Step 4: Run the tests**

Run: `cd action && bun test` → Expected: all pass.

- [ ] **Step 5: Rewrite `action/main.ts`**

```ts
import * as core from "@actions/core";
import * as exec from "@actions/exec";
import * as tc from "@actions/tool-cache";
import { createHash } from "crypto";
import { existsSync } from "fs";
import { readFile } from "fs/promises";
import { join } from "path";
import {
  assetName, DEFAULT_BASE_URL, DEFAULT_REPO, detectPlatform, mirrorUrl, parseEnvJson,
  parsePlatformOverride, parseSha256File, releaseUrl, resolveVersion, TOOL_NAME,
} from "./lib";

async function sha256(path: string): Promise<string> {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

async function fetchJson(url: string, headers: Record<string, string>): Promise<any> {
  const res = await fetch(url, { headers });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return res.json();
}

async function fetchText(url: string): Promise<string> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return res.text();
}

/** Download an archive and its .sha256 from the first URL that works, verifying the checksum. */
async function downloadVerified(urls: string[]): Promise<string> {
  let lastError: unknown;
  for (const url of urls) {
    try {
      const [archive, sumFile] = await Promise.all([tc.downloadTool(url), tc.downloadTool(`${url}.sha256`)]);
      const expected = parseSha256File(await readFile(sumFile, "utf-8"));
      const actual = await sha256(archive);
      if (expected !== actual) throw new Error(`SHA256 mismatch for ${url}: expected ${expected}, got ${actual}`);
      core.info(`Downloaded and verified ${url}`);
      return archive;
    } catch (e) {
      lastError = e;
      core.warning(`Download from ${url} failed: ${e}`);
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}

async function helperOutput(helper: string, args: string[]): Promise<string> {
  const out = await exec.getExecOutput(helper, args, { silent: true });
  return out.stdout;
}

async function run(): Promise<void> {
  try {
    const repo = core.getInput("repo") || DEFAULT_REPO;
    const baseUrl = core.getInput("base-url") || DEFAULT_BASE_URL;
    const token = core.getInput("github-token") || undefined;
    const target = core.getInput("target");
    const archiveInput = core.getInput("archive");
    const platform = parsePlatformOverride(
      core.getInput("os"), core.getInput("arch"), detectPlatform(process.platform, process.arch));

    let root: string;
    if (archiveInput) {
      core.info(`Installing from local archive ${archiveInput}`);
      root = join(await tc.extractTar(archiveInput, undefined, ["xJ"]), TOOL_NAME);
    } else {
      const version = await resolveVersion(core.getInput("version"), {
        repo, baseUrl, token, fetchers: { json: fetchJson, text: fetchText }, warn: core.warning,
      });
      const asset = assetName(version, platform);
      const cacheArch = `${platform.os}-${platform.arch}`;
      let cached = tc.find(TOOL_NAME, version, cacheArch);
      if (cached) {
        core.info(`Using cached ${TOOL_NAME} ${version}`);
      } else {
        const archive = await downloadVerified([releaseUrl(repo, version, asset), mirrorUrl(baseUrl, version, asset)]);
        const extracted = await tc.extractTar(archive, undefined, ["xJ"]);
        cached = await tc.cacheDir(extracted, TOOL_NAME, version, cacheArch);
      }
      root = join(cached, TOOL_NAME);
    }

    const helper = join(root, "bin", "elide-toolchain");
    if (!existsSync(helper)) throw new Error(`Bundle is missing ${helper}`);
    core.addPath(join(root, "bin"));

    const envArgs = ["env", "--format", "json"];
    if (target) envArgs.push("--target", target);
    for (const [k, v] of Object.entries(parseEnvJson(await helperOutput(helper, envArgs)))) {
      core.exportVariable(k, v);
    }

    const version = (await helperOutput(helper, ["version"])).trim();
    const targets = (await helperOutput(helper, ["targets"])).split("\n").filter(Boolean);
    core.setOutput("home", root);
    core.setOutput("version", version);
    core.setOutput("targets", JSON.stringify(targets));
    core.info(`${TOOL_NAME} ${version} ready at ${root} (targets: ${targets.join(", ")})`);
  } catch (e) {
    core.setFailed(e instanceof Error ? e.message : String(e));
  }
}

run();
```

- [ ] **Step 6: Rewrite `action/action.yml` and `action/package.json`**

`action/action.yml`:
```yaml
name: Elide Toolchain
description: Install an Elide native toolchain bundle (clang/lld + musl/glibc/macOS sysroots)

inputs:
  version:
    description: "Toolchain version (YYYY.MM.N, optionally v-prefixed) or 'latest'"
    default: latest
  target:
    description: "Optional target triple; exports CC/CXX/AR/... and pkg-config/CMake settings for it"
    required: false
  github-token:
    description: "Token for the GitHub Releases API (avoids rate limits)"
    default: ${{ github.token }}
  os:
    description: "Override bundle OS (linux|darwin); defaults to the runner"
    required: false
  arch:
    description: "Override bundle arch (amd64|arm64); defaults to the runner"
    required: false
  archive:
    description: "Install from a local .tar.xz instead of downloading (testing)"
    required: false
  base-url:
    description: "Mirror base URL"
    default: https://static.elideusercontent.com
  repo:
    description: "GitHub repository publishing releases"
    default: elide-dev/toolchain

outputs:
  home:
    description: Bundle root (also exported as ELIDE_TOOLCHAIN_HOME)
  version:
    description: Installed bundle version
  targets:
    description: JSON array of target triples in the bundle

runs:
  using: node24
  main: dist/main.js
```
In `action/package.json`, set `"name": "setup-elide-toolchain"`, `"description": "GitHub Action to install an Elide toolchain bundle"`, add `"@actions/exec": "^1.1.1"` to `dependencies`, and add `"test": "bun test"` to `scripts`.

- [ ] **Step 7: Install, typecheck, test, build**

```bash
cd action && bun install && bun run typecheck && bun test && bun run build && cd ..
git diff --stat action/dist/main.js
```
Expected: typecheck clean, tests pass, `dist/main.js` regenerated.

- [ ] **Step 8: Smoke the action locally against the real bundle (Linux)**

```bash
cd action
INPUT_ARCHIVE="$(ls ../dist/elide-toolchain-*-linux-amd64.tar.xz)" INPUT_TARGET=x86_64-unknown-linux-gnu \
  GITHUB_ENV=$(mktemp) GITHUB_PATH=$(mktemp) GITHUB_OUTPUT=$(mktemp) RUNNER_TEMP=$(mktemp -d) RUNNER_TOOL_CACHE=$(mktemp -d) \
  node dist/main.js; echo "exit $?"
cd ..
```
Expected: `exit 0` and a final `elide-toolchain <version> ready at …` line. (@actions/core reads `INPUT_<NAME>` with hyphens kept as-is and the name upper-cased.)

- [ ] **Step 9: Commit**

```bash
git add action
git commit -m "feat(action): install any elide-toolchain bundle; version resolution + mirror fallback

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 21: CI and release workflows

**Files:**
- Rewrite: `.github/workflows/job.build.yml`, `.github/workflows/on.pr.yml`, `.github/workflows/on.push.yml`
- Create: `.github/workflows/job.action-e2e.yml`, `.github/workflows/on.release.yml`

**Interfaces:**
- Consumes: `./build.sh`, `TOOLCHAIN_VERSION`, `REQUIRE_CONTAINER_CHECKS`, `./action` (with `archive`), and `dist/*`.
- Produces: workflow artifacts named `elide-toolchain-<os>-<arch>` (containing `dist/*`); on `v*` tags, a GitHub Release carrying all bundles, checksums and SBOMs, mirrored to R2 at `toolchain/<version>/`, with `toolchain/latest.txt` updated.

- [ ] **Step 1: Write `job.build.yml`**

```yaml
name: "Job - Build"

on:
  workflow_dispatch:
    inputs:
      version:
        description: "Toolchain version (YYYY.MM.N or vYYYY.MM.N); empty = dev build"
        required: false
        type: string
  workflow_call:
    inputs:
      version:
        required: false
        type: string
        default: ""

permissions:
  contents: read

jobs:
  build:
    name: "Bundle (${{ matrix.os }}-${{ matrix.arch }})"
    runs-on: ${{ matrix.runner }}
    timeout-minutes: ${{ matrix.timeout }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: linux, arch: amd64, runner: linux-amd64-cipool, timeout: 720 }
          - { os: linux, arch: arm64, runner: linux-arm64-cipool, timeout: 720 }
          - { os: darwin, arch: arm64, runner: macos-15, timeout: 360 }
          - { os: darwin, arch: amd64, runner: macos-15-intel, timeout: 360 }
    env:
      REQUIRE_CONTAINER_CHECKS: ${{ matrix.os == 'linux' && 'yes' || 'no' }}
      INPUT_VERSION: ${{ inputs.version }}
    steps:
      - name: "Setup: Harden Runner"
        uses: step-security/harden-runner@c6295a65d1254861815972266d5933fd6e532bdf # v2.11.1
        with:
          egress-policy: audit
      - name: "Setup: Checkout"
        uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
        with:
          submodules: false
          fetch-depth: 1
          persist-credentials: false
      - name: "Setup: Submodules"
        run: git submodule update --init --depth=1 --recursive --jobs 8
      - name: "Setup: Packages (Linux)"
        if: matrix.os == 'linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends build-essential bison gawk python3 ninja-build \
            cmake rsync xz-utils curl clang lld llvm
      - name: "Setup: Packages (macOS)"
        if: matrix.os == 'darwin'
        run: brew install bash ninja cmake
      - name: "Setup: Version"
        id: version
        run: |
          if [ -n "$INPUT_VERSION" ]; then
            v="${INPUT_VERSION#v}"
          else
            v="$(. ./versions.env && echo "$TOOLCHAIN_VERSION")-dev.$(git rev-parse --short HEAD)"
          fi
          echo "version=$v" >> "$GITHUB_OUTPUT"
      - name: "Build: Toolchain"
        env:
          TOOLCHAIN_VERSION: ${{ steps.version.outputs.version }}
        run: ./build.sh
      - name: "Artifact: Bundle"
        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4 # v5
        with:
          name: elide-toolchain-${{ matrix.os }}-${{ matrix.arch }}
          compression-level: 0
          overwrite: true
          path: dist/*
```

- [ ] **Step 2: Write `job.action-e2e.yml`**

```yaml
name: "Job - Action E2E"

on:
  workflow_call: {}

permissions:
  contents: read

jobs:
  e2e:
    name: "Action (${{ matrix.os }}-${{ matrix.arch }} ${{ matrix.target }})"
    runs-on: ${{ matrix.runner }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: linux, arch: amd64, runner: linux-amd64-cipool, target: x86_64-unknown-linux-gnu }
          - { os: linux, arch: amd64, runner: linux-amd64-cipool, target: x86_64-unknown-linux-musl }
          - { os: linux, arch: arm64, runner: linux-arm64-cipool, target: aarch64-unknown-linux-gnu }
          - { os: linux, arch: arm64, runner: linux-arm64-cipool, target: aarch64-unknown-linux-musl }
          - { os: darwin, arch: arm64, runner: macos-15, target: arm64-apple-darwin }
          - { os: darwin, arch: amd64, runner: macos-15-intel, target: x86_64-apple-darwin }
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
        with:
          persist-credentials: false
      - uses: actions/download-artifact@634f93cb2916e3fdff6788551b99b062d0335ce0 # v5
        with:
          name: elide-toolchain-${{ matrix.os }}-${{ matrix.arch }}
          path: dist
      - name: "Locate archive"
        id: archive
        run: echo "path=$(ls "$PWD"/dist/elide-toolchain-*.tar.xz)" >> "$GITHUB_OUTPUT"
      - name: "Install via action"
        id: tc
        uses: ./action
        with:
          archive: ${{ steps.archive.outputs.path }}
          target: ${{ matrix.target }}
      - name: "Use it"
        run: |
          elide-toolchain doctor
          echo "home=${{ steps.tc.outputs.home }} targets=${{ steps.tc.outputs.targets }}"
          case "${{ matrix.target }}" in *-linux-musl) extra=-static ;; *) extra= ;; esac
          "$CC" $extra tests/fixtures/hello.c -o hello && ./hello
          "$CXX" $extra tests/fixtures/hello.cpp -o hello-cxx && ./hello-cxx
          test -f "$CMAKE_TOOLCHAIN_FILE"
```
Before committing, check that the pinned `actions/download-artifact` SHA is the current v5 release (`gh api repos/actions/download-artifact/git/ref/tags/v5 --jq .object.sha`). Replace it if it differs.

- [ ] **Step 3: Rewrite `on.pr.yml` and `on.push.yml`**

`on.pr.yml`:
```yaml
name: PR

on:
  pull_request:
    paths-ignore:
      - '**/*.md'
      - 'docs/**'

permissions:
  contents: read

concurrency:
  group: "ci-pr-${{ github.event.number }}"
  cancel-in-progress: true

jobs:
  unit:
    name: "Unit tests"
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0
        with:
          persist-credentials: false
      - run: git submodule update --init --depth=1 cflags
      - run: sudo apt-get install -y shellcheck
      - run: tests/run.sh
      - uses: oven-sh/setup-bun@735343b667d3e6f658f44d0eca948eb6282f2b76 # v2
      - run: cd action && bun install --frozen-lockfile && bun run typecheck && bun test
  build:
    needs: unit
    uses: ./.github/workflows/job.build.yml
    secrets: inherit
  e2e:
    needs: build
    uses: ./.github/workflows/job.action-e2e.yml
```
`on.push.yml`: the same three jobs, with `on: push: branches: [main]` (same `paths-ignore`) and `concurrency: group: "ci-main-${{ github.ref }}"`, `cancel-in-progress: false`.
`tests/run.sh` needs `cflags` and an initialized repo layout, but no other submodules. The `platform`/`flags` tests source `versions.env` only. As in Step 2, verify the `oven-sh/setup-bun` pin with `gh api repos/oven-sh/setup-bun/git/ref/tags/v2 --jq .object.sha`.

- [ ] **Step 4: Write `on.release.yml`**

```yaml
name: Release

on:
  push:
    tags: ["v*"]

permissions:
  contents: read

jobs:
  build:
    uses: ./.github/workflows/job.build.yml
    with:
      version: ${{ github.ref_name }}
    secrets: inherit
  e2e:
    needs: build
    uses: ./.github/workflows/job.action-e2e.yml
  publish:
    needs: [build, e2e]
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      id-token: write
      attestations: write
    steps:
      - uses: actions/download-artifact@634f93cb2916e3fdff6788551b99b062d0335ce0 # v5
        with:
          pattern: elide-toolchain-*
          merge-multiple: true
          path: dist
      - name: "Verify checksums"
        run: cd dist && for f in *.tar.xz; do sha256sum -c "$f.sha256"; done
      - name: "Provenance"
        uses: actions/attest-build-provenance@977bb373ede98d70efdf65b84cb5f73e068dcc2a # v3
        with:
          subject-path: "dist/*.tar.xz"
      - name: "GitHub Release"
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" dist/* --repo "$GITHUB_REPOSITORY" \
            --title "elide-toolchain ${GITHUB_REF_NAME#v}" --generate-notes
      - name: "Mirror: prepare"
        id: ver
        run: |
          echo "v=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
          mkdir -p latest && echo "${GITHUB_REF_NAME#v}" > latest/latest.txt
      - name: "Mirror: bundles"
        uses: elide-tools/r2-upload-action@main
        with:
          path: "./dist"
          target: "toolchain/${{ steps.ver.outputs.v }}"
          bucket: "elide-userdata-public"
          account-id: ${{ secrets.R2_ACCOUNT_ID }}
          access-key-id: ${{ secrets.R2_ACCESS_KEY_ID }}
          secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}
      - name: "Mirror: latest"
        uses: elide-tools/r2-upload-action@main
        with:
          path: "./latest"
          target: "toolchain"
          bucket: "elide-userdata-public"
          account-id: ${{ secrets.R2_ACCOUNT_ID }}
          access-key-id: ${{ secrets.R2_ACCESS_KEY_ID }}
          secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}
```
The mirror path matches `mirrorUrl` in `action/lib.ts`: `toolchain/<version>/<asset>` with no `v` prefix, and `toolchain/latest.txt`.

- [ ] **Step 5: Lint the workflows**

```bash
command -v actionlint >/dev/null || go install github.com/rhysd/actionlint/cmd/actionlint@latest
actionlint .github/workflows/*.yml
```
Expected: no errors (fix anything reported, e.g. expression typos).

- [ ] **Step 6: Commit**

```bash
git add .github/workflows
git commit -m "ci: four-host bundle matrix, action e2e, tagged releases with R2 mirror

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 22: README, cleanup, full end-to-end build

**Files:**
- Rewrite: `README.md`
- Delete: `scripts/legacy/build.sh`, `musl.sbom.json`, `latest` (symlink)
- Create: `docs/notes/build-timings.md`

**Interfaces:**
- Consumes: everything above; `docs/notes/mise-assets.md` (the mise snippet) and `docs/notes/glibc-2.34-gcc15.md`.

- [ ] **Step 1: Delete legacy files**

```bash
git rm -q scripts/legacy/build.sh musl.sbom.json latest
grep -rn "musl-toolchain\|1\.2\.5/\|MUSL_HOME\|musl-cross-make" --exclude-dir=out --exclude-dir=node_modules --exclude-dir=docs . \
  | grep -v '^./\(musl\|llvm\|glibc\|cflags\)/' || echo "no stale references"
```
Expected: `no stale references`. Fix anything else listed, except inside submodules.

- [ ] **Step 2: Rewrite README.md**

Sections, in order (prose drawn from the spec; tables exact):
1. **Elide Toolchain**: one paragraph covering what it is and who uses it (Elide, Komodo, Bali, GraalVM native-image).
2. **Bundles**: the triples table from Global Constraints, the floors (glibc 2.34, macOS 12.0, x86-64-v3 / armv8.2-a hosts), and the asset naming.
3. **Install**:
   - GitHub Actions, showing the `uses: elide-dev/toolchain/action@<ref>` example with `version`/`target`.
   - mise, with the snippet from `docs/notes/mise-assets.md`.
   - Manual: `curl -LO …releases/download/v<ver>/<asset>`, `shasum -a 256 -c`, `tar -xJf`.
4. **Use**: `<triple>-clang`, `elide-toolchain env --target …` (with `eval`), `CMAKE_TOOLCHAIN_FILE`, pkg-config, Rust (`CARGO_TARGET_*_LINKER`, rustc LLVM major ≤ bundle), GraalVM (`<cpu>-linux-musl-gcc` shims), `elide-toolchain doctor`.
5. **Layout**: the tree from spec §2.
6. **Migrating from musl-toolchain**: this table:

| Old (`$MUSL_HOME` = `…/1.2.5`) | New (`$ELIDE_TOOLCHAIN_HOME`) |
|---|---|
| `bin/clang`, `bin/llvm-bolt`, … | `bin/clang`, `bin/llvm-bolt`, … (unchanged names) |
| `lib/libz.a`, `lib/libcrypto.a`, `include/…` | `sysroot/<triple>/usr/lib/…`, `sysroot/<triple>/usr/include/…` |
| `x86_64-linux-musl/lib/libc++.a` | `lib/x86_64-unknown-linux-musl/libc++.a` |
| `lib/mimalloc-2.2/`, `lib/mimalloc-3.3/` | musl: built into `libc.a`; gnu/macOS: `sysroot/<triple>/usr/lib/libmimalloc.a` |
| `lib/clang/22/…` | `lib/clang/<llvmMajor>/…` (read `llvmMajor` from `share/elide-toolchain/manifest.json`) |
| `--sysroot=$MUSL_HOME/x86_64-linux-musl --gcc-toolchain=$MUSL_HOME` | `x86_64-unknown-linux-musl-clang` (cfg supplies everything) |
| `x86_64-linux-musl-gcc` | still present, as a shim over clang |
| `-lstdc++` | drop it; libc++ is implied |
| `musl-toolchain-<sha>-amd64.txz` | `elide-toolchain-<ver>-linux-amd64.tar.xz` |

7. **Building**:
   - host requirements per OS (apt list from Task 21; `brew install bash ninja cmake`)
   - `git submodule update --init --depth=1 --recursive`
   - `./build.sh` options, and the stage table from spec §3.3 (one line each)
   - `vars.sh` toggles
   - expected build times (from Step 4)
8. **Versions**: `versions.env`, `scripts/bump-submodules.sh`, `scripts/check-versions.sh`, CalVer tagging (`git tag vYYYY.MM.N && git push --tags` runs the release).
9. **Verification**: a bullet per check in Task 19, plus `tests/run.sh`.
10. **Flags**: the cflags profile model and the glibc DT_RELR note (spec §3.5).

- [ ] **Step 3: Run every unit test**

Run: `tests/run.sh && (cd action && bun test)`
Expected: all pass.

- [ ] **Step 4: Full clean build and verification on Linux, with timing**

```bash
time ./build.sh --clean 2>&1 | tee out/full-build.log
grep -E '^==> stage|verification:' out/full-build.log
```
Expected: every stage runs, ending in `verification: 0 failure(s)`. Then run every stage check together:
```bash
for c in tests/stages/*.check.sh; do echo "== $c"; bash "$c" || echo "FAILED $c"; done
```
Expected: no `FAILED` lines. Record wall-clock time per stage (from the log timestamps, or by rerunning `./build.sh --only <stage>` under `time` for the heavy ones) in `docs/notes/build-timings.md`, along with the host CPU and RAM.

- [ ] **Step 5: Commit**

```bash
git add -A README.md docs/notes/build-timings.md
git commit -m "docs: README for the universal toolchain; remove legacy musl-only files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Out of scope for this plan (tracked follow-ups)

- Migrating consumers: Elide, Komodo, Bali, labs/WHIPLASH, labs/HEATWAVE. Do this after the first `v2026.10.0` release, one consumer per branch.
- Renaming the GitHub repo to `elide-dev/toolchain` (the user's action). Until then, the action's `repo` default and release URLs point at a name that only exists after the rename; GitHub redirects old URLs after it.
- darwin-amd64 builder replacement when `macos-15-intel` is retired.
- Porting `llvm-propeller` to the staged build (the submodule stays; `BUILD_PROPELLER` is not offered).
