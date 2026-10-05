// hotcold.cc: tcmalloc-compatible MemProf hot/cold operator new overloads. LLVM's
// SimplifyLibCalls (-optimize-hot-cold-new, enabled in the ThinLTO link together with
// -supports-hot-cold-new) rewrites hinted `new` calls to these. Hints map to partitions via
// temp_of_hint(); DEFAULT, or a partition that cannot serve, falls through to the stock
// ::operator new (so user replacements and new_handler semantics are kept).
#include <cstddef>
#include <cstdint>
#include <new>

#include "elidealloc-shim.h"  // declares __hot_cold_t (global namespace: mangles as 12__hot_cold_t)
#include "frontend.h"

#define ELIDEALLOC_NEW __attribute__((visibility("default")))

namespace {

inline void *hinted(size_t n, size_t align, __hot_cold_t h) {
  elidealloc_temp t = elidealloc::temp_of_hint(static_cast<uint8_t>(h));
  if (t != ELIDEALLOC_DEFAULT) {
    if (void *p = elidealloc::partition_alloc(n, align, t, 0)) return p;
  } else {
    elidealloc::note_default(n);
  }
  return nullptr;
}

}  // namespace

ELIDEALLOC_NEW void *operator new(size_t n, __hot_cold_t h) {
  if (void *p = hinted(n, 0, h)) return p;
  return ::operator new(n);
}
ELIDEALLOC_NEW void *operator new[](size_t n, __hot_cold_t h) {
  if (void *p = hinted(n, 0, h)) return p;
  return ::operator new[](n);
}
ELIDEALLOC_NEW void *operator new(size_t n, const std::nothrow_t &tag, __hot_cold_t h) noexcept {
  if (void *p = hinted(n, 0, h)) return p;
  return ::operator new(n, tag);
}
ELIDEALLOC_NEW void *operator new[](size_t n, const std::nothrow_t &tag, __hot_cold_t h) noexcept {
  if (void *p = hinted(n, 0, h)) return p;
  return ::operator new[](n, tag);
}
ELIDEALLOC_NEW void *operator new(size_t n, std::align_val_t a, __hot_cold_t h) {
  if (void *p = hinted(n, static_cast<size_t>(a), h)) return p;
  return ::operator new(n, a);
}
ELIDEALLOC_NEW void *operator new[](size_t n, std::align_val_t a, __hot_cold_t h) {
  if (void *p = hinted(n, static_cast<size_t>(a), h)) return p;
  return ::operator new[](n, a);
}
ELIDEALLOC_NEW void *operator new(size_t n, std::align_val_t a, const std::nothrow_t &tag, __hot_cold_t h) noexcept {
  if (void *p = hinted(n, static_cast<size_t>(a), h)) return p;
  return ::operator new(n, a, tag);
}
ELIDEALLOC_NEW void *operator new[](size_t n, std::align_val_t a, const std::nothrow_t &tag, __hot_cold_t h) noexcept {
  if (void *p = hinted(n, static_cast<size_t>(a), h)) return p;
  return ::operator new[](n, a, tag);
}
