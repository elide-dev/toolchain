// Rust smoke test: links through <triple>-clang and exercises unwinding (catch_unwind), which
// on gnu needs -lgcc_s to resolve (to libunwind, via the sysroot's libgcc_s.so linker script).
fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let caught = std::panic::catch_unwind(|| panic!("unwind test")).is_err();
    if caught {
        println!("hello from elide-toolchain");
    } else {
        std::process::exit(1);
    }
}
