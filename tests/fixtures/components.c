/* Links one symbol from each covered component. HAVE_* macros come from
   component_link in scripts/lib/components.sh. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef HAVE_ZLIB
#include <zlib.h>
#endif
#ifdef HAVE_ZSTD
#include <zstd.h>
#endif
#ifdef HAVE_BROTLI
#include <brotli/decode.h>
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
#include <openssl/crypto.h>
#endif
#ifdef HAVE_MIMALLOC
#include <mimalloc.h>
#endif

int main(void) {
#ifdef HAVE_ZLIB
  printf("zlib %s\n", zlibVersion());
#endif
#ifdef HAVE_ZSTD
  printf("zstd %u\n", ZSTD_versionNumber());
#endif
#ifdef HAVE_BROTLI
  printf("brotli %u\n", BrotliDecoderVersion());
#endif
#ifdef HAVE_SNAPPY
  printf("snappy %zu\n", snappy_max_compressed_length(16));
#endif
#ifdef HAVE_LZ4
  printf("lz4 %d\n", LZ4_versionNumber());
#endif
#ifdef HAVE_CRC32C
  printf("crc32c %u\n", crc32c_value((const uint8_t *)"abc", 3));
#endif
#ifdef HAVE_CRYPTO
  printf("crypto %s\n", OpenSSL_version(OPENSSL_VERSION));
#endif
#ifdef HAVE_MIMALLOC
  void *p = mi_malloc(16);
  mi_free(p);
  printf("mimalloc ok\n");
#endif
  return 0;
}
