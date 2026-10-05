/* LSan trigger: the only pointer to a heap block is dropped. */
#include <stdlib.h>

void *keep;

int main(void) {
  keep = malloc(77);
  keep = 0;
  return 0;
}
