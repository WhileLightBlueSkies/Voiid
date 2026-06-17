#![no_main]
//! Fuzz `decrypt_media` with attacker-controlled blob + media key fields.
//! Property: malformed input returns Err, never panics / UB.

use libfuzzer_sys::fuzz_target;
use voiid_e2e_core::{api, MediaKey};

fuzz_target!(|data: &[u8]| {
    // Split the input into pieces used for the key fields and the blob.
    let n = data.len();
    let a = n / 3;
    let b = 2 * n / 3;
    let key = String::from_utf8_lossy(&data[..a]).into_owned();
    let nonce = String::from_utf8_lossy(&data[a..b]).into_owned();
    let ciphertext = data[b..].to_vec();

    let media_key = MediaKey {
        key,
        nonce,
        ciphertext_sha256: String::from_utf8_lossy(data).into_owned(),
    };
    let _ = api::decrypt_media(&media_key, &ciphertext);
});
