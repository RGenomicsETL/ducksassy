// Exercise the pinned Emscripten std's exception ABI independently of search input.
#[no_mangle]
pub extern "C" fn probe_catch() -> i32 {
    std::panic::catch_unwind(|| panic!("wasm panic probe")).is_err() as i32
}
