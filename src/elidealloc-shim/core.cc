// core.cc: libelidealloc-shim frontend: hint/token policy, partition table, configuration,
// statistics and the public C API. Allocator-agnostic: all allocation goes through backend.h.
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <mutex>

#include "backend.h"
#include "elidealloc-shim.h"
#include "frontend.h"

#define ELIDEALLOC_API extern "C" __attribute__((visibility("default")))

namespace elidealloc {
namespace {

constexpr size_t kMaxClasses = 16;  // token classes (v2); v1 uses class 0 only

std::atomic<backend::heap *> g_part[kMaxClasses][3];
std::atomic<int> g_frozen{0};       // set once any partition heap exists
std::once_flag g_config_once;
elidealloc_config g_cfg = {256, 256, 0, 63, 240, 0};
std::atomic<size_t> g_allocs[3], g_bytes[3], g_fallbacks;

size_t env_num(const char *name, size_t dflt) {
  const char *e = std::getenv(name);
  return (e != nullptr && *e != '\0') ? static_cast<size_t>(std::strtoul(e, nullptr, 10)) : dflt;
}

void print_stats() {
  static const char *const kNames[3] = {"default", "hot", "cold"};
  for (int t = 0; t < 3; t++)
    std::fprintf(stderr, "elidealloc[%s]: %s allocs=%zu bytes=%zu\n", backend::name, kNames[t],
                 g_allocs[t].load(), g_bytes[t].load());
  std::fprintf(stderr, "elidealloc[%s]: fallbacks=%zu\n", backend::name, g_fallbacks.load());
}

void load_config() {
  std::call_once(g_config_once, [] {
    g_cfg.cold_reserve_mb = env_num("ELIDEALLOC_COLD_RESERVE_MB", g_cfg.cold_reserve_mb);
    g_cfg.hot_reserve_mb = env_num("ELIDEALLOC_HOT_RESERVE_MB", g_cfg.hot_reserve_mb);
    g_cfg.hot_large_pages = static_cast<int>(env_num("ELIDEALLOC_HOT_LARGE_PAGES", g_cfg.hot_large_pages));
    g_cfg.cold_max = static_cast<unsigned>(env_num("ELIDEALLOC_COLD_MAX", g_cfg.cold_max));
    g_cfg.hot_min = static_cast<unsigned>(env_num("ELIDEALLOC_HOT_MIN", g_cfg.hot_min));
    g_cfg.disable = static_cast<int>(env_num("ELIDEALLOC_DISABLE", g_cfg.disable));
    if (env_num("ELIDEALLOC_STATS", 0) != 0) std::atexit(print_stats);
  });
}

backend::heap *heap_for(elidealloc_temp t, size_t cls) {
  std::atomic<backend::heap *> &slot = g_part[cls % kMaxClasses][t];
  if (backend::heap *h = slot.load(std::memory_order_acquire)) return h;
  size_t mb = t == ELIDEALLOC_HOT ? g_cfg.hot_reserve_mb : g_cfg.cold_reserve_mb;
  backend::heap *h = backend::heap_create(t, cls, mb, t == ELIDEALLOC_HOT && g_cfg.hot_large_pages);
  if (h == nullptr) return nullptr;
  backend::heap *expected = nullptr;
  if (!slot.compare_exchange_strong(expected, h, std::memory_order_acq_rel)) {
    backend::heap_destroy(h);  // lost the race: use the winner's heap
    return expected;
  }
  g_frozen.store(1, std::memory_order_release);
  return h;
}

}  // namespace

elidealloc_temp temp_of_hint(unsigned hint) {
  load_config();
  if (g_cfg.disable) return ELIDEALLOC_DEFAULT;
  if (hint <= g_cfg.cold_max) return ELIDEALLOC_COLD;
  if (hint >= g_cfg.hot_min) return ELIDEALLOC_HOT;
  return ELIDEALLOC_DEFAULT;  // notcold (128) and ambiguous (222) stay with the stock allocator
}

void note_default(size_t size) {
  g_allocs[ELIDEALLOC_DEFAULT].fetch_add(1, std::memory_order_relaxed);
  g_bytes[ELIDEALLOC_DEFAULT].fetch_add(size, std::memory_order_relaxed);
}

void *partition_alloc(size_t size, size_t align, elidealloc_temp t, size_t cls) {
  load_config();
  if ((t == ELIDEALLOC_DEFAULT && cls == 0) || g_cfg.disable) return nullptr;
  if (t != ELIDEALLOC_HOT && t != ELIDEALLOC_COLD) return nullptr;  // DEFAULT token classes: v2
  backend::heap *h = heap_for(t, cls);
  void *p = h ? backend::alloc(h, size, align) : nullptr;
  if (p == nullptr) {
    g_fallbacks.fetch_add(1, std::memory_order_relaxed);
    return nullptr;
  }
  g_allocs[t].fetch_add(1, std::memory_order_relaxed);
  g_bytes[t].fetch_add(size, std::memory_order_relaxed);
  return p;
}

}  // namespace elidealloc

using namespace elidealloc;

ELIDEALLOC_API int elidealloc_abi_version(void) { return ELIDEALLOC_ABI_VERSION; }

ELIDEALLOC_API const char *elidealloc_backend_name(void) { return backend::name; }

ELIDEALLOC_API int elidealloc_configure(const elidealloc_config *c) {
  if (c == nullptr || g_frozen.load(std::memory_order_acquire)) return -1;
  load_config();  // consume the environment first so the explicit config wins
  g_cfg = *c;
  return 0;
}

static void *c_alloc(size_t size, size_t align, elidealloc_temp t, size_t cls) {
  if (void *p = partition_alloc(size, align, t, cls)) return p;
  note_default(size);
  void *p = backend::alloc(nullptr, size, align);
  if (p == nullptr) errno = ENOMEM;
  return p;
}

ELIDEALLOC_API void *elidealloc_malloc(size_t size, elidealloc_temp t, size_t cls) {
  return c_alloc(size, 0, t, cls);
}

ELIDEALLOC_API void *elidealloc_aligned_alloc(size_t align, size_t size, elidealloc_temp t, size_t cls) {
  return c_alloc(size, align, t, cls);
}

ELIDEALLOC_API elidealloc_temp elidealloc_partition_of(const void *p, size_t *cls_out) {
  if (cls_out) *cls_out = 0;
  if (p == nullptr) return ELIDEALLOC_DEFAULT;
  for (size_t c = 0; c < kMaxClasses; c++)
    for (int t = ELIDEALLOC_HOT; t <= ELIDEALLOC_COLD; t++) {
      backend::heap *h = g_part[c][t].load(std::memory_order_acquire);
      if (h != nullptr && backend::owns(h, p)) {
        if (cls_out) *cls_out = c;
        return static_cast<elidealloc_temp>(t);
      }
    }
  return ELIDEALLOC_DEFAULT;
}

ELIDEALLOC_API void elidealloc_get_stats(elidealloc_stats *out) {
  if (out == nullptr) return;
  for (int t = 0; t < 3; t++) {
    out->allocs[t] = g_allocs[t].load(std::memory_order_relaxed);
    out->bytes[t] = g_bytes[t].load(std::memory_order_relaxed);
  }
  out->fallbacks = g_fallbacks.load(std::memory_order_relaxed);
}
