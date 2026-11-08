// Copyright the Elide Toolchain contributors.
// SPDX-License-Identifier: Apache-2.0 OR MIT
#include <zstd.h>

unsigned component_version() { return ZSTD_versionNumber(); }
