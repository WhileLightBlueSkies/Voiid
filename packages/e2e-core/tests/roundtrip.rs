//! Primary E2E tests live here (in Rust), per the "test the core once" rule.
//! Bindings get light smoke tests of their own so no platform silently breaks.

use voiid_e2e_core::api;

/// Alice and Bob can establish a session and exchange messages both ways.
#[test]
fn full_conversation_roundtrip() {
    // Each device generates its own identity. Private keys never leave here.
    let mut alice = api::create_identity();
    let mut bob = api::create_identity();

    // Both publish bundles so each side knows the other's Curve25519 identity
    // key. In the real app these go to the backend relay.
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let bob_bundle = api::publish_bundle(&mut bob, 5);
    let bob_otk = bob_bundle
        .one_time_keys
        .first()
        .expect("bundle should contain one-time keys");

    // Alice -> Bob: the first message establishes the session (PreKey message).
    let mut alice_session =
        api::start_session(&alice, &bob_bundle.identity_key, bob_otk).expect("start session");
    let first = api::encrypt(&mut alice_session, b"hello bob").expect("encrypt first");
    assert_eq!(first.msg_type, 0, "first message must be a PreKey message");

    // Bob accepts the inbound session and reads the first message.
    let (mut bob_session, plaintext) =
        api::accept_session(&mut bob, &alice_bundle.identity_key, &first).expect("accept session");
    assert_eq!(plaintext, b"hello bob");

    // Bob -> Alice reply.
    let reply = api::encrypt(&mut bob_session, b"hi alice").expect("encrypt reply");
    let decrypted = api::decrypt(&mut alice_session, &reply).expect("decrypt reply");
    assert_eq!(decrypted, b"hi alice");

    // A follow-up Alice -> Bob message (now a Normal message, type 1).
    let second = api::encrypt(&mut alice_session, b"how are you").expect("encrypt 2");
    assert_eq!(second.msg_type, 1, "follow-up should be a Normal message");
    let decrypted2 = api::decrypt(&mut bob_session, &second).expect("decrypt 2");
    assert_eq!(decrypted2, b"how are you");
}

/// The session-dedup property (libsignal `promote_matching_session` equivalent):
/// the id of an accepted session EQUALS the `prekey_session_id` of the PreKey message
/// that established it, AND every subsequent PreKey message from the same outbound
/// session reports the SAME id — so a receiver can detect "already have this session"
/// and reuse it instead of re-accepting (which would burn another one-time key).
#[test]
fn prekey_session_id_matches_and_is_stable() {
    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let bob_bundle = api::publish_bundle(&mut bob, 5);
    let bob_otk = bob_bundle.one_time_keys.first().expect("otk");

    let mut alice_session =
        api::start_session(&alice, &bob_bundle.identity_key, bob_otk).expect("start");
    let first = api::encrypt(&mut alice_session, b"m1").expect("enc1");
    // A second PreKey message (Alice hasn't received a reply yet → still PreKey).
    let second = api::encrypt(&mut alice_session, b"m2").expect("enc2");
    assert_eq!(first.msg_type, 0);
    assert_eq!(second.msg_type, 0);

    // Both PreKey messages carry the SAME session id (same outbound session).
    let id1 = api::prekey_session_id(&first).expect("prekey id 1");
    let id2 = api::prekey_session_id(&second).expect("prekey id 2");
    assert_eq!(id1, id2, "all PreKey msgs of one session share an id");

    // Bob accepts the first; the resulting session's id matches the message's id.
    let (bob_session, _) =
        api::accept_session(&mut bob, &alice_bundle.identity_key, &first).expect("accept");
    assert_eq!(
        api::session_id(&bob_session),
        id1,
        "accepted session id must equal the PreKey's session id (dedup key)"
    );

    // The second PreKey decrypts on the SAME session — no re-accept needed.
    let mut bob_session = bob_session;
    let p2 = api::decrypt(&mut bob_session, &second).expect("decrypt 2nd prekey on same session");
    assert_eq!(p2, b"m2");

    // A Normal message has no prekey session id.
    let reply = api::encrypt(&mut bob_session, b"r").expect("reply");
    let normal = api::encrypt(&mut bob_session, b"r2").expect("reply2");
    let _ = reply;
    assert_eq!(api::prekey_session_id(&normal), None);
}

/// A tampered ciphertext must fail to decrypt rather than return garbage.
#[test]
fn tampered_message_is_rejected() {
    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let bob_bundle = api::publish_bundle(&mut bob, 1);
    let otk = bob_bundle.one_time_keys.first().unwrap();

    let mut session = api::start_session(&alice, &bob_bundle.identity_key, otk).unwrap();
    let mut wire = api::encrypt(&mut session, b"secret").unwrap();
    wire.body.push('A'); // tamper with the base64 body

    assert!(api::accept_session(&mut bob, &alice_bundle.identity_key, &wire).is_err());
}

/// Persisted (pickled) sessions and identities round-trip correctly.
#[test]
fn persistence_roundtrip() {
    let pickle_key = [7u8; 32];

    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let bob_bundle = api::publish_bundle(&mut bob, 1);
    let otk = bob_bundle.one_time_keys.first().unwrap();

    let mut alice_session = api::start_session(&alice, &bob_bundle.identity_key, otk).unwrap();
    let first = api::encrypt(&mut alice_session, b"persist me").unwrap();
    let (bob_session, _pt) =
        api::accept_session(&mut bob, &alice_bundle.identity_key, &first).unwrap();

    // Persist and restore Bob's session, then continue the conversation.
    let pickle = bob_session.to_pickle(&pickle_key);
    let mut restored =
        voiid_e2e_core::Session::from_pickle(&pickle, &pickle_key).expect("restore session");

    let next = api::encrypt(&mut alice_session, b"after restart").unwrap();
    let got = api::decrypt(&mut restored, &next).expect("decrypt after restore");
    assert_eq!(got, b"after restart");
}
