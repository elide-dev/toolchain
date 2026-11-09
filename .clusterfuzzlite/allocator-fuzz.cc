// Copyright the Elide Toolchain contributors.
// SPDX-License-Identifier: Apache-2.0 OR MIT
// Exercise the production shim with its sanitizer-compatible libc backend.
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>
#include "elidealloc-shim.h"
#include "frontend.h"

static void check(bool condition) {
  if (!condition) std::abort();
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 4) return 0;
  elidealloc_config cfg{0, 0, 0, data[0], data[1], data[2] & 1};
  check(elidealloc_configure(&cfg) == 0);
  check(elidealloc_configure(nullptr) == -1);
  check(elidealloc_abi_version() == ELIDEALLOC_ABI_VERSION);
  for (size_t i = 4; i + 4 <= size && i < 1024; i += 4) {
    const size_t n = 1 + data[i + 1] * 4;
    const size_t align = size_t{1} << (3 + data[i + 2] % 7);
    const unsigned hint = data[i + 3];
    const auto h = static_cast<__hot_cold_t>(hint);
    const auto expected = cfg.disable ? ELIDEALLOC_DEFAULT
        : hint <= cfg.cold_max ? ELIDEALLOC_COLD
        : hint >= cfg.hot_min ? ELIDEALLOC_HOT : ELIDEALLOC_DEFAULT;
    check(elidealloc::temp_of_hint(hint) == expected);
    const unsigned op = data[i] % 10;
    void *p = nullptr;
    switch (op) {
      case 0: p = elidealloc_malloc(n, static_cast<elidealloc_temp>(hint % 3), 0); break;
      case 1: p = elidealloc_aligned_alloc(align, n, static_cast<elidealloc_temp>(hint % 3), 0); break;
      case 2: p = operator new(n, h); break;
      case 3: p = operator new[](n, h); break;
      case 4: p = operator new(n, std::nothrow, h); break;
      case 5: p = operator new[](n, std::nothrow, h); break;
      case 6: p = operator new(n, std::align_val_t(align), h); break;
      case 7: p = operator new[](n, std::align_val_t(align), h); break;
      case 8: p = operator new(n, std::align_val_t(align), std::nothrow, h); break;
      case 9: p = operator new[](n, std::align_val_t(align), std::nothrow, h); break;
    }
    check(p != nullptr);
    if (op == 1 || op >= 6) check(reinterpret_cast<uintptr_t>(p) % align == 0);
    size_t cls = 123;
    check(elidealloc_partition_of(p, &cls) == ELIDEALLOC_DEFAULT && cls == 0);
    std::memset(p, hint, n);
    check(static_cast<uint8_t *>(p)[n - 1] == hint);
    if (op < 2) std::free(p);
    else if (op < 6) {
      if (op % 2) operator delete[](p); else operator delete(p);
    } else {
      if (op % 2) operator delete[](p, std::align_val_t(align));
      else operator delete(p, std::align_val_t(align));
    }
  }
  elidealloc_stats stats{};
  elidealloc_get_stats(&stats);
  check(stats.allocs[ELIDEALLOC_HOT] == 0 && stats.allocs[ELIDEALLOC_COLD] == 0);
  check(elidealloc_partition_of(nullptr, nullptr) == ELIDEALLOC_DEFAULT);
  elidealloc_get_stats(nullptr);
  return 0;
}
