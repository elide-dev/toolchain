/* PIE-marked archive bitcode must not turn this shared library's TLS into local-exec. */
static _Thread_local volatile int value;

int shared_tls_next(void) {
  return ++value;
}
