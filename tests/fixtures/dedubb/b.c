#include <stdio.h>
long master_fn(const long *p);
__attribute__((noinline)) long fold_fn(const long *p) { return p[0] * 3 + p[1] * 5 + p[2]; }
int main(void) { long v[3] = {1, 2, 3}; printf("%ld\n", master_fn(v) + fold_fn(v)); return 0; }
