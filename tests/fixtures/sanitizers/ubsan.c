/* UBSan trigger: signed integer overflow. */
#include <limits.h>
#include <stdio.h>

int main(int argc, char **argv) {
  (void)argv;
  int x = INT_MAX;
  x += argc;
  printf("%d\n", x);
  return 0;
}
