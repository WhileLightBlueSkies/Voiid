//! Negative / edge-case tests — the cases an auditor checks. Encryption that
//! only works on the happy path is not secure; these assert it FAILS correctly.

use voiid_e2e_core::{api, Session};

// ---- 1:1 session ----

/// A wrong/empty one-time key must be rejected, not silently accepted.
#[test]
fn start_session_rejects_bad_keys() {
    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let _ = api::publish_bundle(&mut bob, 1);
    let bundle = api::publish_bundle(&mut alice, 1);

    assert!(api::start_session(&alice, "not-base64!!", "also-bad").is_err());
    assert!(api::start_session(&alice, &bundle.identity_key, "").is_err());
}

/// A Normal (non-PreKey) message cannot bootstrap a session — accept must fail
/// rather than create a bogus session.
///
/// Note on Olm semantics: the initiator keeps sending PreKey (type 0) messages
/// until the peer REPLIES; only then does she ratchet to Normal (type 1)
/// messages. So we must complete a round-trip before a Normal message exists.
#[test]
fn accept_rejects_non_prekey_message() {
    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let bob_bundle = api::publish_bundle(&mut bob, 2);
    let otk = bob_bundle.one_time_keys.first().unwrap();

    let mut alice_session = api::start_session(&alice, &bob_bundle.identity_key, otk).unwrap();
    let first = api::encrypt(&mut alice_session, b"prekey").unwrap();
    let (mut bob_session, _pt) =
        api::accept_session(&mut bob, &alice_bundle.identity_key, &first).unwrap();

    // Bob replies; Alice consumes it, which ratchets her to Normal messages.
    let reply = api::encrypt(&mut bob_session, b"ack").unwrap();
    api::decrypt(&mut alice_session, &reply).unwrap();
    let normal = api::encrypt(&mut alice_session, b"normal").unwrap();
    assert_eq!(normal.msg_type, 1, "after a reply, messages are Normal");

    // A fresh receiver cannot bootstrap a session from a Normal message.
    let mut carol = api::create_identity();
    assert!(api::accept_session(&mut carol, &alice_bundle.identity_key, &normal).is_err());
}

/// Replaying the same message twice must not decrypt twice (ratchet replay
/// protection).
#[test]
fn replay_is_rejected() {
    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let bob_bundle = api::publish_bundle(&mut bob, 1);
    let otk = bob_bundle.one_time_keys.first().unwrap();

    let mut alice_session = api::start_session(&alice, &bob_bundle.identity_key, otk).unwrap();
    let first = api::encrypt(&mut alice_session, b"hi").unwrap();
    let (mut bob_session, _) =
        api::accept_session(&mut bob, &alice_bundle.identity_key, &first).unwrap();

    let m = api::encrypt(&mut alice_session, b"once").unwrap();
    assert_eq!(api::decrypt(&mut bob_session, &m).unwrap(), b"once");
    // Second decrypt of the identical message must fail.
    assert!(api::decrypt(&mut bob_session, &m).is_err());
}

/// A pickle restored with the wrong key must fail, not return a usable session.
#[test]
fn pickle_wrong_key_fails() {
    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let _ = api::publish_bundle(&mut alice, 1);
    let bob_bundle = api::publish_bundle(&mut bob, 1);
    let otk = bob_bundle.one_time_keys.first().unwrap();
    let session = api::start_session(&alice, &bob_bundle.identity_key, otk).unwrap();

    let pickle = session.to_pickle(&[1u8; 32]);
    assert!(Session::from_pickle(&pickle, &[2u8; 32]).is_err());
    assert!(Session::from_pickle("garbage", &[1u8; 32]).is_err());
}

// ---- media ----

/// Empty plaintext still round-trips (zero-length attachment).
#[test]
fn media_empty_roundtrips() {
    let enc = api::encrypt_media(b"").unwrap();
    assert_eq!(api::decrypt_media(&enc.media_key, &enc.ciphertext).unwrap(), b"");
}

/// A media key with a wrong-length key/nonce is rejected.
#[test]
fn media_bad_key_length_rejected() {
    let mut enc = api::encrypt_media(b"data").unwrap();
    enc.media_key.key = "AAAA".to_string(); // decodes to 3 bytes, not a 32-byte key
    assert!(api::decrypt_media(&enc.media_key, &enc.ciphertext).is_err());
}

// ---- verification ----

/// A small difference in a key changes the safety number (no collisions on
/// near-identical inputs).
#[test]
fn safety_number_sensitive_to_key() {
    let a = api::safety_number(b"id1", "AAAA", b"id2", "BBBB");
    let b = api::safety_number(b"id1", "AAAA", b"id2", "BBBC");
    assert_ne!(a, b);
}

/// Safety number format: exactly 12 groups of 5 digits.
#[test]
fn safety_number_format() {
    let n = api::safety_number(b"id1", "alice-key", b"id2", "bob-key");
    let groups: Vec<&str> = n.split(' ').collect();
    assert_eq!(groups.len(), 12);
    assert!(groups.iter().all(|g| g.len() == 5 && g.chars().all(|c| c.is_ascii_digit())));
}
