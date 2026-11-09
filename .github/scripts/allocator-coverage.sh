#!/bin/bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -euo pipefail
cd "$(dirname "$0")/../.."
CXX=${CXX:-clang++-18}
LLVM_PROFDATA=${LLVM_PROFDATA:-llvm-profdata-18}
LLVM_COV=${LLVM_COV:-llvm-cov-18}
report="$PWD/dist/coverage/allocator"
mkdir -p "$report"
"$CXX" -std=c++17 -O1 -g -pthread -Isrc/elidealloc-shim \
  -fprofile-instr-generate -fcoverage-mapping -fsanitize=fuzzer,address \
  src/elidealloc-shim/core.cc src/elidealloc-shim/hotcold.cc \
  src/elidealloc-shim/backend-forward.cc .clusterfuzzlite/allocator-fuzz.cc \
  -o "$report/allocator_fuzz"
LLVM_PROFILE_FILE="$report/profile.profraw" \
  "$report/allocator_fuzz" -seed=1 -runs=100000 -max_len=1024 > "$report/fuzz.log" 2>&1
"$LLVM_PROFDATA" merge -sparse "$report/profile.profraw" -o "$report/profile.profdata"
"$LLVM_COV" export "$report/allocator_fuzz" -instr-profile="$report/profile.profdata" \
  -ignore-filename-regex='allocator-fuzz.cc|/usr/|/opt/' > "$report/coverage.json"
"$LLVM_COV" report "$report/allocator_fuzz" -instr-profile="$report/profile.profdata" \
  -ignore-filename-regex='allocator-fuzz.cc|/usr/|/opt/' | tee "$report/summary.txt"
