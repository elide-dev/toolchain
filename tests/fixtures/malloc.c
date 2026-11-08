// Copyright the Elide Toolchain contributors.
// SPDX-License-Identifier: Apache-2.0 OR MIT
#include <stdio.h>
#include <stdlib.h>

int main(void) {
  char *p = malloc(100);
  if (!p) return 1;
  puts("malloc ok");
  free(p);
  return 0;
}
