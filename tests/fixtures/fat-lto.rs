// Rust-driven link through the bundle clang/lld with -Clinker-plugin-lto (issue #13): with
// lld --fat-lto-objects, libzstd.a's bitcode joins the LTO link and ZSTD_versionNumber is
// internalized (inlined or local); without it, the archive's native code keeps a global symbol.
extern "C" {
    fn ZSTD_versionNumber() -> u32;
}

fn main() {
    let v = unsafe { ZSTD_versionNumber() };
    std::process::exit(if v > 0 { 0 } else { 1 });
}
