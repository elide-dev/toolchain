/* JNI-shaped native library: built -shared with -shared-libsan and loaded by an uninstrumented
   host (jni-host.c) with the sanitizer runtime LD_PRELOADed. */
#include <stdlib.h>

int native_bug(int i) {
  int *p = malloc(4 * sizeof(int));
  int r = p[i];
  free(p);
  return r;
}
