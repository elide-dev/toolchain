// frontend.h: shared between core.cc and hotcold.cc (internal, hidden).
#pragma once
#include <cstddef>

#include "elidealloc-shim.h"

namespace elidealloc {

// Temperature for a MemProf hint (0 coldest .. 255 hottest) under the current thresholds.
elidealloc_temp temp_of_hint(unsigned hint);

// Allocate from partition (temp, token_class). Returns nullptr when the request belongs to the
// default allocator (DEFAULT, class 0) or the partition could not serve it; the caller then
// uses the stock allocation path (operator new / malloc), which keeps stock semantics.
void *partition_alloc(size_t size, size_t align, elidealloc_temp temp, size_t token_class);

// Count a hinted allocation served by the default allocator.
void note_default(size_t size);

}  // namespace elidealloc
