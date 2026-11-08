// Copyright the Elide Toolchain contributors.
// SPDX-License-Identifier: Apache-2.0 OR MIT
// Rust-driven link through the bundle clang/lld with -Clinker-plugin-lto (issue #13): with
// lld --fat-lto-objects, libzstd.a's bitcode joins the LTO link and ZSTD_versionNumber is
// internalized, so its unused ZSTD_versionString is dropped; without it, the native code keeps it.
extern "C" {
    fn ZSTD_versionNumber() -> u32;
}

fn main() {
    let v = unsafe { ZSTD_versionNumber() };
    std::process::exit(if v > 0 { 0 } else { 1 });
}
