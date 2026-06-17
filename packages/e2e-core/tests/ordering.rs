//! Out-of-order delivery tests for 1:1 sessions.
//!
//! vodozemac implements the Double Ratchet's skipped-message-key store
//! (up to 40 retained keys, max gap 2000), so messages that arrive out of
//! sequence still decrypt. These tests pin that behavior and its limits.

use voiid_e2e_core::{api, WireMessage};

fn establish() -> (
    voiid_e2e_core::Session, // alice
    voiid_e2e_core::Session, // bob
) {
    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let bob_bundle = api::publish_bundle(&mut bob, 1);
    let otk = bob_bundle.one_time_keys.first().unwrap();

    let mut alice_session = api::start_session(&alice, &bob_bundle.identity_key, otk).unwrap();
    // First message establishes Bob's side.
    let first = api::encrypt(&mut alice_session, b"establish").unwrap();
    let (mut bob_session, _) =
        api::accept_session(&mut bob, &alice_bundle.identity_key, &first).unwrap();
    // Bob replies so Alice ratchets to Normal messages.
    let reply = api::encrypt(&mut bob_session, b"ack").unwrap();
    api::decrypt(&mut alice_session, &reply).unwrap();
    (alice_session, bob_session)
}

/// Messages delivered in reverse order all decrypt to the right plaintext.
#[test]
fn reverse_order_delivery() {
    let (mut alice, mut bob) = establish();

    let msgs: Vec<WireMessage> = (0..5)
        .map(|i| api::encrypt(&mut alice, format!("msg-{i}").as_bytes()).unwrap())
        .collect();

    // Bob receives them last-to-first.
    for i in (0..5).rev() {
        let pt = api::decrypt(&mut bob, &msgs[i]).unwrap();
        assert_eq!(pt, format!("msg-{i}").as_bytes());
    }
}

/// A message can be skipped, later messages decrypt, then the skipped one still
/// decrypts from the stored skipped key.
#[test]
fn skip_then_backfill() {
    let (mut alice, mut bob) = establish();

    let m0 = api::encrypt(&mut alice, b"zero").unwrap();
    let m1 = api::encrypt(&mut alice, b"one").unwrap();
    let m2 = api::encrypt(&mut alice, b"two").unwrap();

    // Bob gets m2 first (skipping m0, m1), then backfills.
    assert_eq!(api::decrypt(&mut bob, &m2).unwrap(), b"two");
    assert_eq!(api::decrypt(&mut bob, &m0).unwrap(), b"zero");
    assert_eq!(api::decrypt(&mut bob, &m1).unwrap(), b"one");
}

/// Interleaved bidirectional out-of-order traffic stays consistent.
#[test]
fn interleaved_bidirectional() {
    let (mut alice, mut bob) = establish();

    let a1 = api::encrypt(&mut alice, b"a1").unwrap();
    let b1 = api::encrypt(&mut bob, b"b1").unwrap();
    let a2 = api::encrypt(&mut alice, b"a2").unwrap();

    // Deliver in a jumbled order.
    assert_eq!(api::decrypt(&mut alice, &b1).unwrap(), b"b1");
    assert_eq!(api::decrypt(&mut bob, &a2).unwrap(), b"a2");
    assert_eq!(api::decrypt(&mut bob, &a1).unwrap(), b"a1");
}

/// Within the retained-key window, a moderately large gap still backfills.
#[test]
fn gap_within_window() {
    let (mut alice, mut bob) = establish();

    // Send 30 messages; deliver the 30th, then backfill several earlier ones.
    let msgs: Vec<WireMessage> = (0..30)
        .map(|i| api::encrypt(&mut alice, format!("m{i}").as_bytes()).unwrap())
        .collect();

    assert_eq!(api::decrypt(&mut bob, &msgs[29]).unwrap(), b"m29");
    // Backfill the last ~30 (within the 40-key retention window).
    for (i, msg) in msgs.iter().enumerate().take(29) {
        assert_eq!(api::decrypt(&mut bob, msg).unwrap(), format!("m{i}").as_bytes());
    }
}
