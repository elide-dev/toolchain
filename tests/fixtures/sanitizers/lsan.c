// Copyright the Elide Toolchain contributors.
// SPDX-License-Identifier: Apache-2.0 OR MIT
/* LSan trigger: the only pointer to a heap block is dropped. */
#include <stdlib.h>

void *keep;

int main(void) {
  keep = malloc(77);
  keep = 0;
  return 0;
}
