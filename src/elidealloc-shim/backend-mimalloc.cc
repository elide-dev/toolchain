// mimalloc backend (#1): partition heaps are mimalloc 3.x first-class heaps (allocate and free
// from any thread, separate pages), each bound to an exclusive arena when reserve_mb > 0, so
// ownership is an arena-range check. musl: mimalloc is libc's allocator (libc.a's mimalloc.o);
// gnu: libmimalloc.a with MI_OVERRIDE=ON must be linked (-lmimalloc).
#include <mimalloc.h>

#include "backend.h"

namespace elidealloc::backend {

struct heap {
  mi_heap_t *h;
  mi_arena_id_t arena;
};

const char *const name = "mimalloc";

heap *heap_create(elidealloc_temp, size_t, size_t reserve_mb, bool large_pages) {
  mi_arena_id_t id = nullptr;
  mi_heap_t *h = nullptr;
  if (reserve_mb != 0 &&
      mi_reserve_os_memory_ex(reserve_mb << 20, /*commit=*/false, large_pages, /*exclusive=*/true, &id) == 0)
    h = mi_heap_new_in_arena(id);
  if (h == nullptr) {
    id = nullptr;
    h = mi_heap_new();
  }
  if (h == nullptr) return nullptr;
  auto *r = static_cast<heap *>(mi_malloc(sizeof(heap)));  // lives for the process
  if (r == nullptr) {
    mi_heap_delete(h);
    return nullptr;
  }
  r->h = h;
  r->arena = id;
  return r;
}

void heap_destroy(heap *r) {
  mi_heap_delete(r->h);
  mi_free(r);
}

void *alloc(heap *r, size_t size, size_t align) {
  if (r == nullptr) return align ? mi_malloc_aligned(size, align) : mi_malloc(size);
  return align ? mi_heap_malloc_aligned(r->h, size, align) : mi_heap_malloc(r->h, size);
}

void *realloc(heap *r, void *p, size_t size) {
  return r ? mi_heap_realloc(r->h, p, size) : mi_realloc(p, size);
}

void free(void *p) { mi_free(p); }

size_t usable_size(const void *p) { return mi_usable_size(p); }

bool owns(const heap *r, const void *p) {
  return r->arena ? mi_arena_contains(r->arena, p) : mi_heap_contains(r->h, p);
}

}  // namespace elidealloc::backend
