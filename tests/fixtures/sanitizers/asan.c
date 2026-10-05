/* ASan trigger: heap-buffer-overflow (index depends on argc so it cannot be folded away). */
#include <stdlib.h>

int main(int argc, char **argv) {
  (void)argv;
  int *p = malloc(4 * sizeof(int));
  int r = p[argc + 3];
  free(p);
  return r;
}
