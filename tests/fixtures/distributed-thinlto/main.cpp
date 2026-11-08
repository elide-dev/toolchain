// Copyright the Elide Toolchain contributors.
// SPDX-License-Identifier: Apache-2.0 OR MIT
// Keep a project-to-project import as well as references to the shipped libc++.
#include <iostream>
#include <zstd.h>

unsigned component_version();

int main() {
  const unsigned version = component_version();
  std::cout << version << '\n';
  return version == ZSTD_VERSION_NUMBER ? 0 : 1;
}
