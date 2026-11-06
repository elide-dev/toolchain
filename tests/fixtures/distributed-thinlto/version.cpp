#include <zstd.h>

unsigned component_version() { return ZSTD_versionNumber(); }
