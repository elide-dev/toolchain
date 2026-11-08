// Copyright the Elide Toolchain contributors.
// SPDX-License-Identifier: Apache-2.0 OR MIT
__attribute__((noinline)) long master_fn(const long *p) { return p[0] * 3 + p[1] * 5 + p[2]; }
