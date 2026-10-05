/* TSan trigger: two threads increment a global without synchronisation. */
#include <pthread.h>

static int g;

static void *work(void *arg) {
  g++;
  return arg;
}

int main(void) {
  pthread_t a, b;
  pthread_create(&a, 0, work, 0);
  pthread_create(&b, 0, work, 0);
  pthread_join(a, 0);
  pthread_join(b, 0);
  return g == 0;
}
