/* Cross-module optimization through a shipped fat archive (issue #13): with the bundle's
 * default Linux LTO link, ZSTD_versionNumber's bitcode from libzstd.a is imported, inlined and
 * dropped, so the output defines no ZSTD_versionNumber symbol. A non-LTO link (or
 * -fno-fat-lto-objects) uses the archive's native code and keeps a global definition. */
#include <zstd.h>

int main(void) { return ZSTD_versionNumber() == ZSTD_VERSION_NUMBER ? 0 : 1; }
