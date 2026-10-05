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
#ifdef HAVE_SQLITE3ELIDE
#include <sqlite3.h>
/* From sqlite3jni.h, which needs jni.h: the shim must be inside libsqlite3elide.a. */
extern int sqlite_isStatic(void *env, void *reserved);
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
#ifdef HAVE_SQLITE3ELIDE
  {
    sqlite3 *db = NULL;
    if (sqlite3_libversion_number() != SQLITE_VERSION_NUMBER) { fprintf(stderr, "sqlite3elide: header/library mismatch\n"); return 1; }
    if (!sqlite3_compileoption_used("MAX_ATTACHED=25") || !sqlite3_compileoption_used("ENABLE_API_ARMOR")) {
      fprintf(stderr, "sqlite3elide: compile options missing\n"); return 1;
    }
    if (!sqlite_isStatic(NULL, NULL)) { fprintf(stderr, "sqlite3elide: shim not built with SQLITE_GVM_STATIC\n"); return 1; }
    if (sqlite3_open(":memory:", &db) != SQLITE_OK ||
        sqlite3_exec(db, "CREATE VIRTUAL TABLE t USING fts5(x); INSERT INTO t VALUES('ok');", NULL, NULL, NULL) != SQLITE_OK) {
      fprintf(stderr, "sqlite3elide: %s\n", db ? sqlite3_errmsg(db) : "open failed"); return 1;
    }
    sqlite3_close(db);
    printf("sqlite3elide %s\n", sqlite3_libversion());
  }
#endif
  return 0;
}
