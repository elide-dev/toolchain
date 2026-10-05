// libelidealloc-shim behaviour test (spec §5). Exit 0 = pass; prints the first failure.
// Expectations depend on the backend the library reports (forward = no partitions).
// Modes: no argument = full test; "disabled" = run under ELIDEALLOC_DISABLE=1;
// "hotmin200" = run under ELIDEALLOC_HOT_MIN=200 (thresholds are tunable).
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <thread>

#include "elidealloc-shim.h"

static int failures = 0;
#define EXPECT(cond)                                                     \
  do {                                                                   \
    if (!(cond)) {                                                       \
      std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      failures++;                                                        \
    }                                                                    \
  } while (0)

static elidealloc_temp part(const void *p) { return elidealloc_partition_of(p, nullptr); }
static __hot_cold_t hint(unsigned v) { return static_cast<__hot_cold_t>(v); }

int main(int argc, char **argv) {
  const bool forward = std::strcmp(elidealloc_backend_name(), "forward") == 0;
  const elidealloc_temp HOT = forward ? ELIDEALLOC_DEFAULT : ELIDEALLOC_HOT;
  const elidealloc_temp COLD = forward ? ELIDEALLOC_DEFAULT : ELIDEALLOC_COLD;
  const char *mode = argc > 1 ? argv[1] : "";
  EXPECT(elidealloc_abi_version() == ELIDEALLOC_ABI_VERSION);

  if (std::strcmp(mode, "disabled") == 0) {
    void *c = operator new(64, hint(1));
    void *h = operator new(64, hint(254));
    EXPECT(part(c) == ELIDEALLOC_DEFAULT && part(h) == ELIDEALLOC_DEFAULT);
    operator delete(c); operator delete(h);
    return failures ? 1 : 0;
  }
  if (std::strcmp(mode, "hotmin200") == 0) {
    void *a = operator new(64, hint(222));  // ambiguous becomes hot with ELIDEALLOC_HOT_MIN=200
    EXPECT(part(a) == HOT);
    operator delete(a);
    return failures ? 1 : 0;
  }

  // Hint mapping with default thresholds: cold <= 63, hot >= 240; notcold and ambiguous stay default.
  void *cold = operator new(64, hint(1));
  void *hot = operator new[](64, hint(254));
  void *notcold = operator new(64, hint(128));
  void *ambiguous = operator new[](64, hint(222));
  EXPECT(part(cold) == COLD);
  EXPECT(part(hot) == HOT);
  EXPECT(part(notcold) == ELIDEALLOC_DEFAULT);
  EXPECT(part(ambiguous) == ELIDEALLOC_DEFAULT);
  std::memset(cold, 1, 64); std::memset(hot, 2, 64);
  operator delete(cold); operator delete[](hot); operator delete(notcold); operator delete[](ambiguous);

  // All eight overloads, alignment.
  const std::align_val_t al{256};
  void *v[8] = {
      operator new(16, hint(1)),
      operator new[](16, hint(1)),
      operator new(16, std::nothrow, hint(1)),
      operator new[](16, std::nothrow, hint(1)),
      operator new(16, al, hint(1)),
      operator new[](16, al, hint(1)),
      operator new(16, al, std::nothrow, hint(1)),
      operator new[](16, al, std::nothrow, hint(1)),
  };
  for (int i = 0; i < 8; i++) {
    EXPECT(v[i] != nullptr);
    EXPECT(part(v[i]) == COLD);
    if (i >= 4) EXPECT(reinterpret_cast<uintptr_t>(v[i]) % 256 == 0);
  }
  operator delete(v[0]); operator delete[](v[1]); operator delete(v[2]); operator delete[](v[3]);
  operator delete(v[4], al); operator delete[](v[5], al); operator delete(v[6], al); operator delete[](v[7], al);

  // OOM: a partition that cannot serve falls back to the stock nothrow new, which returns null.
  // (The throwing variants also fall back to the stock operator new; what that does on OOM is the
  // process allocator's business, e.g. gnu's mimalloc override aborts without a new_handler.)
  EXPECT(operator new(SIZE_MAX / 2, std::nothrow, hint(1)) == nullptr);
  EXPECT(operator new[](SIZE_MAX / 2, std::nothrow, hint(254)) == nullptr);

  // Cross-thread: allocate cold in one thread, free in another, allocate cold again there.
  void *x = operator new(128, hint(1));
  void *y = nullptr;
  std::thread th([&] {
    operator delete(x);
    y = operator new(128, hint(1));
  });
  th.join();
  EXPECT(part(y) == COLD);
  operator delete(y);

  // C API.
  void *c = elidealloc_malloc(32, ELIDEALLOC_COLD, 0);
  void *d = elidealloc_aligned_alloc(64, 100, ELIDEALLOC_HOT, 0);
  EXPECT(c != nullptr && part(c) == COLD);
  EXPECT(d != nullptr && part(d) == HOT && reinterpret_cast<uintptr_t>(d) % 64 == 0);
  std::free(c); std::free(d);
  EXPECT(part(nullptr) == ELIDEALLOC_DEFAULT);

  // Stats and frozen configuration.
  elidealloc_stats st;
  elidealloc_get_stats(&st);
  if (!forward) {
    EXPECT(st.allocs[ELIDEALLOC_COLD] >= 12);
    EXPECT(st.allocs[ELIDEALLOC_HOT] >= 2);
  }
  EXPECT(st.allocs[ELIDEALLOC_DEFAULT] >= 2);
  elidealloc_config cfg = {0, 0, 0, 10, 250, 0};
  EXPECT(elidealloc_configure(&cfg) == (forward ? 0 : -1));

  if (failures == 0) std::printf("elidealloc-shim test passed (backend %s)\n", elidealloc_backend_name());
  return failures ? 1 : 0;
}
