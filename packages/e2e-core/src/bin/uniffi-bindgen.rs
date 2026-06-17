//! Standalone binding generator. Build the cdylib, then run:
//!   cargo run --bin uniffi-bindgen -- generate --library \
//!     target/debug/libvoiid_e2e_core.dylib --language swift --out-dir bindings/swift
//!   ... --language kotlin --out-dir bindings/kotlin
fn main() {
    uniffi::uniffi_bindgen_main()
}
