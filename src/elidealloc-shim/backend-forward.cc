// forward backend: no partitions; everything is the C library's allocator. Used where the
// process allocator cannot free partition-heap pointers (darwin, where static mimalloc does not
// override free) or where musl is built without mimalloc.
#include <cstdlib>
#if defined(__APPLE__)
#include <malloc/malloc.h>
#else
#include <malloc.h>
#endif

#include "backend.h"

namespace elidealloc::backend {

struct heap {};

const char *const name = "forward";

heap *heap_create(elidealloc_temp, size_t, size_t, bool) { return nullptr; }

void heap_destroy(heap *) {}

void *alloc(heap *, size_t size, size_t align) {
  if (align == 0) return std::malloc(size);
  if (align < sizeof(void *)) align = sizeof(void *);
  void *p = nullptr;
  return posix_memalign(&p, align, size) == 0 ? p : nullptr;
}

void *realloc(heap *, void *p, size_t size) { return std::realloc(p, size); }

void free(void *p) { std::free(p); }

size_t usable_size(const void *p) {
#if defined(__APPLE__)
  return malloc_size(p);
#else
  return malloc_usable_size(const_cast<void *>(p));
#endif
}

bool owns(const heap *, const void *) { return false; }

}  // namespace elidealloc::backend
