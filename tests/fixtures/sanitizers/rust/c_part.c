// Copyright the Elide Toolchain contributors.
// SPDX-License-Identifier: Apache-2.0 OR MIT
/* C half of the Rust sanitizer check (tests/fixtures/sanitizers/rust/main.rs). */
#include <stdlib.h>

int c_overflow(int i) {
  int *p = malloc(4 * sizeof(int));
  int r = p[i];
  free(p);
  return r;
}
