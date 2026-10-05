/* Sanitizer add-on false-positive check: push real data through every enabled component and
   branch on everything they write. Buffers are heap-allocated on purpose: MSan treats static
   storage as initialised, which would hide stores made by uninstrumented code (spike D).
   HAVE_* macros come from component_link in scripts/lib/components.sh (HAVE_BROTLI also links
   -lbrotlienc here). Exit 0 iff every round trip matches. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef HAVE_ZLIB
#include <zlib.h>
#endif
#ifdef HAVE_ZSTD
#include <zstd.h>
#endif
#ifdef HAVE_BROTLI
#include <brotli/decode.h>
#include <brotli/encode.h>
#endif
#ifdef HAVE_SNAPPY
#include <snappy-c.h>
#endif
#ifdef HAVE_LZ4
#include <lz4.h>
#endif
#ifdef HAVE_CRC32C
#include <crc32c/crc32c.h>
#endif
#ifdef HAVE_CRYPTO
#include <openssl/sha.h>
#endif
#ifdef HAVE_MIMALLOC
#include <mimalloc.h>
#endif

#define N 65536
static unsigned char *in, *out, *back;

static int check(const char *name, size_t n) {
  int ok = n == N && memcmp(back, in, N) == 0;
  printf("%-7s %s\n", name, ok ? "ok" : "MISMATCH");
  memset(back, 0, N);
  return ok ? 0 : 1;
}

int main(void) {
  int rc = 0;
  in = malloc(N);
  out = malloc(2 * N);
  back = malloc(N);
  if (!in || !out || !back) return 2;
  for (int i = 0; i < N; i++) in[i] = (unsigned char)("elide toolchain "[i % 16] ^ (i / 997));
#ifdef HAVE_ZLIB
  {
    uLongf zl = 2 * N, zb = N;
    if (compress2(out, &zl, in, N, 6) != Z_OK || uncompress(back, &zb, out, zl) != Z_OK) zb = 0;
    rc |= check("zlib", zb);
  }
#endif
#ifdef HAVE_ZSTD
  {
    size_t s = ZSTD_compress(out, 2 * N, in, N, 3);
    size_t d = ZSTD_isError(s) ? 0 : ZSTD_decompress(back, N, out, s);
    rc |= check("zstd", ZSTD_isError(d) ? 0 : d);
  }
#endif
#ifdef HAVE_LZ4
  {
    int l = LZ4_compress_default((const char *)in, (char *)out, N, 2 * N);
    int d = l > 0 ? LZ4_decompress_safe((const char *)out, (char *)back, l, N) : -1;
    rc |= check("lz4", d < 0 ? 0 : (size_t)d);
  }
#endif
#ifdef HAVE_BROTLI
  {
    size_t bl = 2 * N, bd = N;
    if (!BrotliEncoderCompress(5, 22, BROTLI_MODE_GENERIC, N, in, &bl, out)
        || BrotliDecoderDecompress(bl, out, &bd, back) != BROTLI_DECODER_RESULT_SUCCESS) bd = 0;
    rc |= check("brotli", bd);
  }
#endif
#ifdef HAVE_SNAPPY
  {
    size_t sl = 2 * N, sd = N;
    if (snappy_compress((const char *)in, N, (char *)out, &sl) != SNAPPY_OK
        || snappy_uncompress((const char *)out, sl, (char *)back, &sd) != SNAPPY_OK) sd = 0;
    rc |= check("snappy", sd);
  }
#endif
#ifdef HAVE_CRYPTO
  {
    unsigned char *h = malloc(SHA256_DIGEST_LENGTH);
    SHA256(in, N, h);
    printf("sha256  %s\n", h[0] & 1 ? "odd" : "even");
    free(h);
  }
#endif
#ifdef HAVE_CRC32C
  printf("crc32c  %s\n", crc32c_value(in, N) & 1 ? "odd" : "even");
#endif
#ifdef HAVE_MIMALLOC
  {
    char *m = mi_malloc(N);
    memcpy(m, in, N);
    rc |= memcmp(m, in, N) != 0;
    mi_free(m);
  }
#endif
  free(in);
  free(out);
  free(back);
  return rc;
}
