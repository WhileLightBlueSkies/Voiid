#![no_main]
//! Fuzz `Session::decrypt` with attacker-controlled WireMessage bytes.
//! Property: malformed input must return Err, never panic / UB.

use libfuzzer_sys::fuzz_target;
use voiid_e2e_core::{api, WireMessage};

fuzz_target!(|data: &[u8]| {
    // Establish a real session so decrypt has ratchet state to work against.
    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let _ab = api::publish_bundle(&mut alice, 1);
    let bob_bundle = api::publish_bundle(&mut bob, 1);
    let Some(otk) = bob_bundle.one_time_keys.first() else { return };
    let Ok(mut alice_session) = api::start_session(&alice, &bob_bundle.identity_key, otk) else {
        return;
    };
    let Ok(first) = api::encrypt(&mut alice_session, b"seed") else { return };
    let Ok((mut bob_session, _)) =
        api::accept_session(&mut bob, &_ab.identity_key, &first)
    else {
        return;
    };

    // Feed fuzzer bytes as the body of a WireMessage of each type.
    let body = String::from_utf8_lossy(data).into_owned();
    for msg_type in [0u64, 1, 2, u64::MAX] {
        let wire = WireMessage {
            msg_type,
            body: body.clone(),
        };
        // Must not panic. Result is ignored.
        let _ = api::decrypt(&mut bob_session, &wire);
    }
});
