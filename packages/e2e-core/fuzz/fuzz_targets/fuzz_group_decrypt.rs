#![no_main]
//! Fuzz `GroupSession::decrypt` with attacker-controlled MLS message bytes.
//! Property: malformed input returns Err, never panics / UB.

use libfuzzer_sys::fuzz_target;
use voiid_e2e_core::GroupMember;

fuzz_target!(|data: &[u8]| {
    let alice = match GroupMember::new(b"alice") {
        Ok(a) => a,
        Err(_) => return,
    };
    let mut group = match alice.create_group() {
        Ok(g) => g,
        Err(_) => return,
    };

    // Feed raw fuzzer bytes as an incoming group message. Must not panic.
    let _ = group.decrypt(&alice, data);
});
