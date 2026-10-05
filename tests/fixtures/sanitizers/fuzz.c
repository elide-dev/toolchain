/* libFuzzer smoke target (-fsanitize=fuzzer,address); run with -runs=N, must not crash. */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static volatile char sink;
  char buf[16];
  if (size >= 4 && memcmp(data, "ELID", 4) == 0) {
    memcpy(buf, data, size < sizeof buf ? size : sizeof buf);
    sink = buf[0];
  }
  return 0;
}
