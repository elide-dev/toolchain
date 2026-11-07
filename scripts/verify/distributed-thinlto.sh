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
  cp "$source.o" "$source.indexing.o"
done

# Match Bazel's CppLTOIndexing options, including split plugin options, path
# rewriting, a distinct indexing-object suffix, and the final-link response file.
split_index_options=(
  "-Wl,-plugin-opt,thinlto-index-only=final.params"
  "-Wl,-plugin-opt,thinlto-emit-imports-files"
  '-Wl,-plugin-opt,thinlto-prefix-replace=;backends/'
  '-Wl,-plugin-opt,thinlto-object-suffix-replace=.indexing.o;.o'
  "-Wl,-plugin-opt,obj-path=merged.o"
)

# Explicit fat-LTO recreates the broken 2026.11.2 default: the test must actually
# exercise archive imports, rather than pass with an empty or inactive index.
mkdir control
cp main.indexing.o version.indexing.o control/
cp "$bundle/sysroot/$triple/usr/lib/libzstd.a" control/
(
  cd control
  # Index a private copy without implicit runtime libraries: lld writes index
  # sidecars beside archive members, which must not modify the installed bundle.
  "$cxx" "${static[@]}" -nostdlib -flto=thin -ffat-lto-objects \
    main.indexing.o version.indexing.o "$PWD/libzstd.a" -Wl,-e,main,--unresolved-symbols=ignore-all \
    "${split_index_options[@]}" -o app
  grep -F '.a(' backends/*.imports >/dev/null || { echo "control did not import archive bitcode" >&2; exit 1; }
  grep -F '.a(' final.params >/dev/null || { echo "control did not list archive backends" >&2; exit 1; }
)

# Verify the default and both documented opt-outs. Project inputs are relative
# to the execroot; the installed sysroot and its fat archives are absolute.
modes=(default-split default-joined driver-opt-out linker-opt-out)
case "$triple" in *-gnu) modes+=(shared-split) ;; esac
for mode in "${modes[@]}"; do
  mkdir "$mode"
  cp main.o version.o main.indexing.o version.indexing.o "$mode/"
  (
    cd "$mode"
    extra=()
    shared=()
    index_options=("${split_index_options[@]}")
    case "$mode" in
      default-joined)
        index_options=(
          "-Wl,-plugin-opt=thinlto-index-only=final.params"
          "-Wl,-plugin-opt=thinlto-emit-imports-files"
          '-Wl,-plugin-opt=thinlto-prefix-replace=;backends/'
          '-Wl,-plugin-opt=thinlto-object-suffix-replace=.indexing.o;.o'
          "-Wl,-plugin-opt=obj-path=merged.o"
        ) ;;
      driver-opt-out) extra=(-fno-fat-lto-objects) ;;
      linker-opt-out) extra=(-ffat-lto-objects "-Wl,--no-fat-lto-objects") ;;
      shared-split) shared=(-shared) ;;
    esac
    "$cxx" "${static[@]}" "${shared[@]}" -flto=thin "${extra[@]}" \
      main.indexing.o version.indexing.o -lzstd -lc++ -lc++abi "${index_options[@]}" -o app
    test ! -e app
    # Bazel feeds this list to the final link. It must contain only backend
    # output paths, with no archive members or absolute execroot paths.
    printf '%s\n' backends/main.o backends/version.o > expected.params
    LC_ALL=C sort final.params > actual.params
    cmp expected.params actual.params
    # Prove distributed ThinLTO is still active between project objects.
    grep -Fx version.o backends/main.o.imports >/dev/null || { echo "project bitcode was not imported" >&2; exit 1; }
    for source in main version; do
      test -s "backends/$source.o.thinlto.bc"
      test -f "backends/$source.o.imports"
      # A backend receives only its bitcode, index, and declared imports, as in
      # Bazel's sandbox. Reject archive-member syntax and paths outside execroot.
      mkdir "backend-$source"
      cp "$source.o" "backends/$source.o.thinlto.bc" "backend-$source/"
      while IFS= read -r imported; do
        case "$imported" in
          main.o|version.o) cp "$imported" "backend-$source/" ;;
          *) echo "invalid distributed import: $imported" >&2; exit 1 ;;
        esac
      done < "backends/$source.o.imports"
      (
        cd "backend-$source"
        "$cxx" -O2 -fPIC -c -x ir "$source.o" \
          -fthinlto-index="$source.o.thinlto.bc" -o native.o
      )
      cp "backend-$source/native.o" "backends/$source.o"
    done
    "$cxx" "${static[@]}" "${shared[@]}" -flto=thin "${extra[@]}" \
      @final.params -lzstd -lc++ -lc++abi -o app
    test -s app
    if [[ $mode != shared-split ]]; then ./app; fi
    echo "ok distributed ThinLTO $triple $mode"
  )
done
