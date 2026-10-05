/* HWASan trigger: out-of-bounds write (tag mismatch). */
#include <stdlib.h>

int main(int argc, char **argv) {
  (void)argv;
  char *p = malloc(16);
  p[16 + argc - 1] = 1;
  free(p);
  return 0;
}
