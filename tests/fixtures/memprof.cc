#include <cstdlib>
#include <cstring>
#include <new>
__attribute__((noinline)) char *alloc(size_t n) { return new char[n]; }
__attribute__((noinline)) char *viaHot(size_t n) { return alloc(n); }
__attribute__((noinline)) char *viaCold(size_t n) { return alloc(n); }
int main(int argc, char **) {
  long s = 0;
  for (int i = 0; i < 100000; i++) {
    char *p = viaHot(64);
    for (int k = 0; k < 64; k++) { p[k] = k; s += p[k]; }
    delete[] p;
  }
  for (int i = 0; i < 4; i++) {
    char *p = viaCold(64);
    p[0] = 1; s += p[0];
    delete[] p;
  }
  return s == 42;
}
