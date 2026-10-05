/* mimalloc API shim for sanitizer add-ons (spec 2026-10-05 §7.1, spike E).
 *
 * Under ASan/TSan/MSan the sanitizer runtime owns malloc. The real libmimalloc.a either
 * overrides malloc (MI_OVERRIDE=ON: crashes at startup under ASan/TSan) or hides its blocks
 * from the sanitizer (MI_OVERRIDE=OFF: ASan misses overflows, MSan reports false positives from
 * mimalloc's raw-syscall reads). This archive replaces libmimalloc.a in each sanitizer sysroot
 * (sysroot/<triple>+<san>) and forwards the commonly used mi_* API to the libc allocator, which
 * every sanitizer intercepts. Heaps, arenas and statistics are not modelled: heap/arena calls are
 * deliberately absent, so code needing them fails to link instead of misbehaving. */
#include <errno.h>
#include <malloc.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <mimalloc.h>

static size_t mul_ovf(size_t a, size_t b, size_t *out) { return __builtin_mul_overflow(a, b, out); }

static void *aligned(size_t size, size_t alignment) {
  void *p = NULL;
  if (alignment < sizeof(void *)) alignment = sizeof(void *);
  if (posix_memalign(&p, alignment, size ? size : 1) != 0) return NULL;
  return p;
}

void *mi_malloc(size_t size) { return malloc(size); }
void *mi_calloc(size_t count, size_t size) { return calloc(count, size); }
void *mi_realloc(void *p, size_t newsize) { return realloc(p, newsize); }
void *mi_expand(void *p, size_t newsize) { return (p && malloc_usable_size(p) >= newsize) ? p : NULL; }
void mi_free(void *p) { free(p); }
char *mi_strdup(const char *s) { return strdup(s); }
char *mi_strndup(const char *s, size_t n) { return strndup(s, n); }
char *mi_realpath(const char *fname, char *resolved_name) { return realpath(fname, resolved_name); }

void *mi_malloc_small(size_t size) { return malloc(size); }
void *mi_zalloc_small(size_t size) { return calloc(1, size); }
void *mi_zalloc(size_t size) { return calloc(1, size); }
void *mi_mallocn(size_t count, size_t size) {
  size_t n;
  if (mul_ovf(count, size, &n)) { errno = ENOMEM; return NULL; }
  return malloc(n);
}
void *mi_reallocn(void *p, size_t count, size_t size) {
  size_t n;
  if (mul_ovf(count, size, &n)) { errno = ENOMEM; return NULL; }
  return realloc(p, n);
}
void *mi_reallocf(void *p, size_t newsize) {
  void *q = realloc(p, newsize);
  if (!q && newsize) free(p);
  return q;
}
void *mi_recalloc(void *p, size_t newcount, size_t size) {
  size_t n, old = p ? malloc_usable_size(p) : 0;
  if (mul_ovf(newcount, size, &n)) { errno = ENOMEM; return NULL; }
  void *q = realloc(p, n);
  if (q && n > old) memset((char *)q + old, 0, n - old);
  return q;
}
size_t mi_usable_size(const void *p) { return p ? malloc_usable_size((void *)p) : 0; }
size_t mi_good_size(size_t size) { return size; }
void mi_free_size(void *p, size_t size) { (void)size; free(p); }

void *mi_malloc_aligned(size_t size, size_t alignment) { return aligned(size, alignment); }
void *mi_zalloc_aligned(size_t size, size_t alignment) {
  void *p = aligned(size, alignment);
  if (p) memset(p, 0, size);
  return p;
}
void *mi_calloc_aligned(size_t count, size_t size, size_t alignment) {
  size_t n;
  if (mul_ovf(count, size, &n)) { errno = ENOMEM; return NULL; }
  return mi_zalloc_aligned(n, alignment);
}
void *mi_realloc_aligned(void *p, size_t newsize, size_t alignment) {
  void *q;
  size_t old;
  if (!p) return aligned(newsize, alignment);
  if (((uintptr_t)p % (alignment ? alignment : 1)) == 0) return realloc(p, newsize);
  old = malloc_usable_size(p);
  q = aligned(newsize, alignment);
  if (q) { memcpy(q, p, old < newsize ? old : newsize); free(p); }
  return q;
}
void mi_free_size_aligned(void *p, size_t size, size_t alignment) { (void)size; (void)alignment; free(p); }
void mi_free_aligned(void *p, size_t alignment) { (void)alignment; free(p); }

size_t mi_malloc_size(const void *p) { return mi_usable_size(p); }
size_t mi_malloc_good_size(size_t size) { return size; }
size_t mi_malloc_usable_size(const void *p) { return mi_usable_size(p); }
int mi_posix_memalign(void **p, size_t alignment, size_t size) { return posix_memalign(p, alignment, size); }
void *mi_memalign(size_t alignment, size_t size) { return aligned(size, alignment); }
void *mi_aligned_alloc(size_t alignment, size_t size) { return aligned(size, alignment); }
void *mi_valloc(size_t size) { return aligned(size, 4096); }
void *mi_pvalloc(size_t size) { return aligned((size + 4095) & ~(size_t)4095, 4096); }
void *mi_reallocarray(void *p, size_t count, size_t size) { return mi_reallocn(p, count, size); }
int mi_reallocarr(void *ptrp, size_t count, size_t size) {
  void **pp = (void **)ptrp;
  void *q = mi_reallocn(*pp, count, size);
  if (!q && count && size) return ENOMEM;
  *pp = q;
  return 0;
}

void mi_collect(bool force) { (void)force; }
int mi_version(void) { return MI_MALLOC_VERSION; }
void mi_stats_reset(void) {}
void mi_stats_merge(void) {}
void mi_stats_print(void *out) { (void)out; }
bool mi_option_is_enabled(mi_option_t option) { (void)option; return false; }
void mi_option_enable(mi_option_t option) { (void)option; }
void mi_option_disable(mi_option_t option) { (void)option; }
void mi_option_set_enabled(mi_option_t option, bool enable) { (void)option; (void)enable; }
long mi_option_get(mi_option_t option) { (void)option; return 0; }
long mi_option_get_clamp(mi_option_t option, long min, long max) { (void)option; (void)max; return min > 0 ? min : 0; }
void mi_option_set(mi_option_t option, long value) { (void)option; (void)value; }
