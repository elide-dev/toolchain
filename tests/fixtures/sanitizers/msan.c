// Copyright the Elide Toolchain contributors.
// SPDX-License-Identifier: Apache-2.0 OR MIT
/* MSan trigger: branch on an uninitialised local. */
#include <stdio.h>

int main(int argc, char **argv) {
  (void)argv;
  int x;
  if (argc > 5) x = 1;
  if (x) puts("y");
  return 0;
}
