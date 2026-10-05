// Rust + C under ASan with clang's runtime (-Zsanitizer=address -Zexternal-clangrt, linked by
// <triple>-asan-clang). `main trip` makes the C side overflow a heap block.
extern "C" {
    fn c_overflow(i: i32) -> i32;
}

fn main() {
    let n = std::env::args().count() as i32;
    let v: Vec<u8> = vec![1; 8];
    if n > 1 {
        let r = unsafe { c_overflow(3 + n) };
        println!("{}", r);
    }
    println!("rust ok {}", v.len());
}
