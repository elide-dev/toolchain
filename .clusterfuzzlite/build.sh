#!/bin/bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -euo pipefail
# ClusterFuzzLite provides compiler/sanitizer flags and the fuzzing engine.
# Only the small first-party shim is compiled; LLVM and bundled libraries are not built.
# shellcheck disable=SC2086
"$CXX" $CXXFLAGS -std=c++17 -pthread -Isrc/elidealloc-shim \
  src/elidealloc-shim/core.cc src/elidealloc-shim/hotcold.cc \
  src/elidealloc-shim/backend-forward.cc .clusterfuzzlite/allocator-fuzz.cc \
  $LIB_FUZZING_ENGINE -o "$OUT/allocator_fuzz"
