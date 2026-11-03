fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    assert!(std::panic::catch_unwind(|| panic!("exercise cleanup personality")).is_err());
}
