#!/usr/bin/env bash
# Issue #18: reproduce Bazel's index -> isolated backend -> final link protocol.
# Usage: distributed-thinlto.sh BUNDLE TRIPLE (Linux, zstd enabled).
set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
bundle="$(cd "$1" && pwd -P)"
triple="$2"
cxx="$bundle/bin/$triple-clang++"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
static=(); case "$triple" in *-musl) static=(-static) ;; esac
cd "$tmp"

for source in main version; do
  "$cxx" -O2 -fPIC -flto=thin -fno-fat-lto-objects \
    -c "$ROOT_DIR/tests/fixtures/distributed-thinlto/$source.cpp" -o "$source.o"
done

# Explicit fat-LTO recreates the broken 2026.11.2 default: the test must actually
# exercise archive imports, rather than pass with an empty or inactive index.
mkdir control
cp main.o version.o control/
cp "$bundle/sysroot/$triple/usr/lib/libzstd.a" control/
(
  cd control
  # Index a private copy without implicit runtime libraries: lld writes index
  # sidecars beside archive members, which must not modify the installed bundle.
  "$cxx" "${static[@]}" -nostdlib -flto=thin -ffat-lto-objects \
    main.o version.o "$PWD/libzstd.a" -Wl,-e,main,--unresolved-symbols=ignore-all \
    -Wl,-plugin-opt=thinlto-index-only=index,-plugin-opt=thinlto-emit-imports-files -o app
  grep -F '.a(' ./*.imports >/dev/null || { echo "control did not import archive bitcode" >&2; exit 1; }
)

# Verify the default and both documented opt-outs. Project inputs are relative
# to the execroot; the installed sysroot and its fat archives are absolute.
for mode in default driver-opt-out linker-opt-out; do
  mkdir "$mode"
  cp main.o version.o "$mode/"
  (
    cd "$mode"
    extra=()
    case "$mode" in
      driver-opt-out) extra=(-fno-fat-lto-objects) ;;
      linker-opt-out) extra=(-ffat-lto-objects "-Wl,--no-fat-lto-objects") ;;
    esac
    "$cxx" "${static[@]}" -flto=thin "${extra[@]}" main.o version.o -lzstd \
      -Wl,-plugin-opt=thinlto-index-only=index,-plugin-opt=thinlto-emit-imports-files -o app
    test ! -e app
    # Prove distributed ThinLTO is still active between project objects.
    grep -Fx version.o main.o.imports >/dev/null || { echo "project bitcode was not imported" >&2; exit 1; }
    for source in main version; do
      test -s "$source.o.thinlto.bc"
      test -f "$source.o.imports"
      # A backend receives only its bitcode, index, and declared imports, as in
      # Bazel's sandbox. Reject archive-member syntax and paths outside execroot.
      mkdir "backend-$source"
      cp "$source.o" "$source.o.thinlto.bc" "backend-$source/"
      while IFS= read -r imported; do
        case "$imported" in
          main.o|version.o) cp "$imported" "backend-$source/" ;;
          *) echo "invalid distributed import: $imported" >&2; exit 1 ;;
        esac
      done < "$source.o.imports"
      (
        cd "backend-$source"
        "$cxx" -O2 -fPIC -c -x ir "$source.o" \
          -fthinlto-index="$source.o.thinlto.bc" -o native.o
      )
    done
    "$cxx" "${static[@]}" -flto=thin "${extra[@]}" \
      backend-main/native.o backend-version/native.o -lzstd -o app
    ./app
  )
done
