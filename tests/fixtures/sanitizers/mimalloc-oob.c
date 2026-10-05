/* ASan trigger through the mimalloc API: detected only because the add-on's libmimalloc.a
   forwards to the intercepted libc allocator. */
#include <mimalloc.h>

int main(int argc, char **argv) {
  (void)argv;
  char *p = mi_malloc(16);
  p[16 + argc - 1] = 1;
  mi_free(p);
  return 0;
}
