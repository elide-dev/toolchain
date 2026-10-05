/* Clean use of the mimalloc API. Under a sanitizer add-on libmimalloc.a is the forwarding shim
   (src/mimalloc-sanitizer-shim.c), so these allocations are visible to, and clean under, every
   sanitizer. */
#include <mimalloc.h>
#include <string.h>

int main(void) {
  char *a = mi_malloc(64);
  char *b = mi_zalloc_aligned(128, 64);
  if (!a || !b) return 2;
  memset(a, 1, 64);
  a = mi_realloc(a, 256);
  if (!a) return 2;
  memset(a + 64, 2, 192);
  int ok = a[0] == 1 && a[255] == 2 && b[127] == 0 && mi_usable_size(a) >= 256;
  mi_free(a);
  mi_free(b);
  return ok ? 0 : 1;
}
