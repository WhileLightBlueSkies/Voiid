//! Tests for safety-number verification.

use voiid_e2e_core::api;

/// Both users compute the SAME safety number regardless of argument order.
#[test]
fn safety_number_is_symmetric() {
    let alice = api::create_identity();
    let bob = api::create_identity();
    let a = alice.fingerprint();
    let b = bob.fingerprint();
    let aid = b"alice-id";
    let bid = b"bob-id";

    let alice_view = api::safety_number(aid, &a, bid, &b);
    let bob_view = api::safety_number(bid, &b, aid, &a);

    assert_eq!(alice_view, bob_view, "both sides must see the same number");
    // 12 groups of 5 digits, space-separated → 60 digits + 11 spaces.
    assert_eq!(alice_view.chars().filter(|c| c.is_ascii_digit()).count(), 60);
}

/// A different peer key yields a different safety number (so a MITM swapping
/// keys would be visible).
#[test]
fn different_peer_changes_number() {
    let alice = api::create_identity();
    let bob = api::create_identity();
    let mallory = api::create_identity();
    let aid = b"alice-id";
    let bid = b"bob-id";

    let real = api::safety_number(aid, &alice.fingerprint(), bid, &bob.fingerprint());
    let mitm = api::safety_number(aid, &alice.fingerprint(), bid, &mallory.fingerprint());

    assert_ne!(real, mitm, "swapping Bob for Mallory must change the number");
}

/// A different identifier (same key) changes the number — identity binding.
#[test]
fn different_identifier_changes_number() {
    let alice = api::create_identity();
    let bob = api::create_identity();
    let a = alice.fingerprint();
    let b = bob.fingerprint();

    let n1 = api::safety_number(b"alice-id", &a, b"bob-id", &b);
    let n2 = api::safety_number(b"alice-id", &a, b"bob-OTHER", &b);
    assert_ne!(n1, n2, "binding a different identifier must change the number");
}
