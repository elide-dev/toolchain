#include <cstddef>
__attribute__((noinline)) char *alloc(size_t n) {
  return new char[n];
}
__attribute__((noinline)) char *viaHot(size_t n) {
  return alloc(n);
}
__attribute__((noinline)) char *viaCold(size_t n) {
  return alloc(n);
}
#include "elidealloc-shim.h"
int main() {
  char *a = viaHot(10);
  char *b = viaCold(10);
  // Line numbers above are load-bearing: memprof-ctx.yaml matches alloc() line 3 col 10,
  // viaHot/viaCold line +1 col 10, and main lines +1/+2 col 13. The YAML profile makes the
  // viaCold context cold (hint 1 -> COLD) and the viaHot context notcold (hint 128 -> DEFAULT).
  bool forward = elidealloc_partition_of(nullptr, nullptr) == ELIDEALLOC_DEFAULT &&
                 elidealloc_backend_name()[0] == 'f';
  int rc = elidealloc_partition_of(a, nullptr) == ELIDEALLOC_DEFAULT ? 0 : 2;
  if (!forward) rc |= elidealloc_partition_of(b, nullptr) == ELIDEALLOC_COLD ? 0 : 4;
  delete[] a;
  delete[] b;
  return rc;
}
