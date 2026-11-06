/* Cross-module optimization through a shipped fat archive (issue #13): with the bundle's
 * default Linux LTO link, ZSTD_versionNumber's bitcode from libzstd.a is imported and inlined
 * into main, and the member's unused ZSTD_versionString is dropped. A non-LTO link (or
 * -fno-fat-lto-objects) uses the archive's native code: main calls ZSTD_versionNumber. */
#include <zstd.h>

int main(void) { return ZSTD_versionNumber() == ZSTD_VERSION_NUMBER ? 0 : 1; }
