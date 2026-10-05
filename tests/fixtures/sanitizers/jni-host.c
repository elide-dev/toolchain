/* Uninstrumented host (stand-in for the JVM): dlopen a sanitized library and call into it. */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  void *h = dlopen(argv[1], RTLD_NOW);
  if (!h) {
    printf("dlopen: %s\n", dlerror());
    return 2;
  }
  int (*f)(int) = (int (*)(int))dlsym(h, "native_bug");
  return f ? f(argc + 2) : 2;
}
