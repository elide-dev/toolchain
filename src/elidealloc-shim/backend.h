// backend.h: libelidealloc-shim's internal allocator interface (not installed, not ABI).
// Exactly one backend-<name>.cc is compiled in, selected at build time
// (-DELIDEALLOC_BACKEND_MIMALLOC or -DELIDEALLOC_BACKEND_FORWARD). A backend must be the
// process allocator too: the shim never wraps free()/operator delete, so free() has to accept
// pointers from any partition heap.
#pragma once
#include <cstddef>

#include "elidealloc-shim.h"

namespace elidealloc::backend {

struct heap;  // opaque per-partition handle

// Create a partition heap with an optional dedicated address range. nullptr if unsupported
// (the frontend then serves the partition from the default allocator).
heap *heap_create(elidealloc_temp temp, size_t token_class, size_t reserve_mb, bool large_pages);
void heap_destroy(heap *h);                            // only after losing a creation race
void *alloc(heap *h, size_t size, size_t align);       // align 0 = natural; nullptr on failure
void *realloc(heap *h, void *p, size_t size);          // stays in h when it must move
void free(void *p);                                    // any pointer, any heap, any thread
size_t usable_size(const void *p);
bool owns(const heap *h, const void *p);
extern const char *const name;

}  // namespace elidealloc::backend
