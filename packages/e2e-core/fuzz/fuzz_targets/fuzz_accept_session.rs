#![no_main]
//! Fuzz `accept_session` — the entry point that builds a session from an
//! attacker-supplied first message. Property: no panic / UB on malformed input.

use libfuzzer_sys::fuzz_target;
use voiid_e2e_core::{api, WireMessage};

fuzz_target!(|data: &[u8]| {
    let mut bob = api::create_identity();
    let _ = api::publish_bundle(&mut bob, 2);

    // Use part of the data as a (likely-bogus) identity key, the rest as body.
    let split = data.len() / 2;
    let id_key = String::from_utf8_lossy(&data[..split]).into_owned();
    let body = String::from_utf8_lossy(&data[split..]).into_owned();

    for msg_type in [0u64, 1] {
        let wire = WireMessage {
            msg_type,
            body: body.clone(),
        };
        let _ = api::accept_session(&mut bob, &id_key, &wire);
    }
});
