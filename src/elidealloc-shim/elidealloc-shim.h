/*
 * elidealloc-shim.h: allocation-hint partitioning for elide-toolchain consumers (ABI v1).
 *
 * libelidealloc-shim turns compiler-provided allocation hints into heap partitions:
 *  - MemProf hot/cold `operator new(size_t, __hot_cold_t)` (tcmalloc-compatible ABI), enabled
 *    by linking with -Wl,-mllvm,-supports-hot-cold-new and a -fmemory-profile-use profile;
 *  - explicit partition requests through this C API.
 * Partitions: DEFAULT (the process allocator, unchanged), HOT and COLD (dedicated heaps).
 * The backend allocator is chosen at build time (mimalloc today; "forward" = plain libc).
 * Link: pkg-config --libs elidealloc-shim  (gnu: -lelidealloc-shim -lmimalloc).
 * Environment (read once): ELIDEALLOC_COLD_MAX (63), ELIDEALLOC_HOT_MIN (240),
 * ELIDEALLOC_COLD_RESERVE_MB (256), ELIDEALLOC_HOT_RESERVE_MB (256), ELIDEALLOC_HOT_LARGE_PAGES (0),
 * ELIDEALLOC_DISABLE (0), ELIDEALLOC_STATS (0; 1 = print counters to stderr at exit).
 */
#ifndef ELIDEALLOC_SHIM_H
#define ELIDEALLOC_SHIM_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

#define ELIDEALLOC_ABI_VERSION 1

typedef enum { ELIDEALLOC_DEFAULT = 0, ELIDEALLOC_HOT = 1, ELIDEALLOC_COLD = 2 } elidealloc_temp;

typedef struct {
  size_t cold_reserve_mb;  /* dedicated address range for COLD (0 = none) */
  size_t hot_reserve_mb;   /* dedicated address range for HOT (0 = none) */
  int hot_large_pages;     /* allow large OS pages for HOT */
  unsigned cold_max;       /* hint <= cold_max -> COLD */
  unsigned hot_min;        /* hint >= hot_min -> HOT (MemProf: cold 1, notcold 128, ambiguous 222, hot 254) */
  int disable;             /* 1: every hint goes to DEFAULT */
} elidealloc_config;

typedef struct {
  size_t allocs[3];        /* hinted allocations served, by elidealloc_temp */
  size_t bytes[3];         /* requested bytes, by elidealloc_temp */
  size_t fallbacks;        /* partition allocations that fell back to DEFAULT */
} elidealloc_stats;

int elidealloc_abi_version(void);
const char *elidealloc_backend_name(void);
/* 0 on success; -1 once any partition exists (call before the first hinted allocation). */
int elidealloc_configure(const elidealloc_config *config);
/* Allocate in a partition. token_class is reserved for allocation tokens (ABI v2); pass 0.
 * Free with free(). NULL + errno=ENOMEM on failure. */
void *elidealloc_malloc(size_t size, elidealloc_temp temp, size_t token_class);
void *elidealloc_aligned_alloc(size_t align, size_t size, elidealloc_temp temp, size_t token_class);
/* Partition that served p (DEFAULT for anything else). */
elidealloc_temp elidealloc_partition_of(const void *p, size_t *token_class_out);
void elidealloc_get_stats(elidealloc_stats *out);

#ifdef __cplusplus
}

/* tcmalloc-compatible hot/cold operator new (what MemProf's rewrite calls). Declared so C++
 * code can pass hints explicitly: hint 0 = coldest .. 255 = hottest. */
#include <cstdint>
#include <new>
enum class __hot_cold_t : std::uint8_t {};
void *operator new(std::size_t, __hot_cold_t);
void *operator new[](std::size_t, __hot_cold_t);
void *operator new(std::size_t, const std::nothrow_t &, __hot_cold_t) noexcept;
void *operator new[](std::size_t, const std::nothrow_t &, __hot_cold_t) noexcept;
void *operator new(std::size_t, std::align_val_t, __hot_cold_t);
void *operator new[](std::size_t, std::align_val_t, __hot_cold_t);
void *operator new(std::size_t, std::align_val_t, const std::nothrow_t &, __hot_cold_t) noexcept;
void *operator new[](std::size_t, std::align_val_t, const std::nothrow_t &, __hot_cold_t) noexcept;
#endif
#endif
