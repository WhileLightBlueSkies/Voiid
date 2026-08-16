//! Prekey replenishment / exhaustion tests.
//!
//! Each inbound session a peer establishes consumes one of our published
//! one-time keys. If they run out, new senders must wait until we replenish.

use voiid_e2e_core::api;

/// Two different senders each consume a distinct one-time key; both succeed when
/// Bob published enough keys.
#[test]
fn distinct_senders_consume_distinct_keys() {
    let mut bob = api::create_identity();
    let bob_bundle = api::publish_bundle(&mut bob, 2);
    let bob_id = &bob_bundle.identity_key;
    assert!(bob_bundle.one_time_keys.len() >= 2);

    let mut alice = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let mut carol = api::create_identity();
    let carol_bundle = api::publish_bundle(&mut carol, 1);

    // Alice uses OTK[0], Carol uses OTK[1].
    let mut a_sess = api::start_session(&alice, bob_id, &bob_bundle.one_time_keys[0]).unwrap();
    let a_first = api::encrypt(&mut a_sess, b"from alice").unwrap();
    let mut c_sess = api::start_session(&carol, bob_id, &bob_bundle.one_time_keys[1]).unwrap();
    let c_first = api::encrypt(&mut c_sess, b"from carol").unwrap();

    // Bob accepts both — each consumes its own one-time key.
    let (_s1, p1) = api::accept_session(&mut bob, &alice_bundle.identity_key, &a_first).unwrap();
    let (_s2, p2) = api::accept_session(&mut bob, &carol_bundle.identity_key, &c_first).unwrap();
    assert_eq!(p1, b"from alice");
    assert_eq!(p2, b"from carol");
}

/// Reusing an already-CONSUMED one-time key fails on Bob's side — replay/key
/// reuse protection. (Bob consumed OTK[0] for Alice; Carol reusing OTK[0] must
/// not yield a valid session.)
#[test]
fn consumed_key_cannot_be_reused() {
    let mut bob = api::create_identity();
    let bob_bundle = api::publish_bundle(&mut bob, 1);
    let bob_id = &bob_bundle.identity_key;
    let otk = &bob_bundle.one_time_keys[0];

    let mut alice = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let mut a_sess = api::start_session(&alice, bob_id, otk).unwrap();
    let a_first = api::encrypt(&mut a_sess, b"hi").unwrap();
    // Bob consumes OTK[0].
    api::accept_session(&mut bob, &alice_bundle.identity_key, &a_first).unwrap();

    // Carol tries to start a session with the SAME (now-consumed) OTK.
    let mut carol = api::create_identity();
    let carol_bundle = api::publish_bundle(&mut carol, 1);
    let mut c_sess = api::start_session(&carol, bob_id, otk).unwrap();
    let c_first = api::encrypt(&mut c_sess, b"sneaky").unwrap();
    // Bob can't accept it: the one-time key is gone.
    assert!(api::accept_session(&mut bob, &carol_bundle.identity_key, &c_first).is_err());
}

/// After exhaustion, replenishing restores the ability to start new sessions.
#[test]
fn replenish_restores_capacity() {
    let mut bob = api::create_identity();
    let _initial = api::publish_bundle(&mut bob, 1); // 1 key, will be consumed

    // Consume the only key.
    let mut alice = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let bob_first_bundle = _initial;
    let mut a_sess = api::start_session(
        &alice,
        &bob_first_bundle.identity_key,
        &bob_first_bundle.one_time_keys[0],
    )
    .unwrap();
    let a_first = api::encrypt(&mut a_sess, b"first").unwrap();
    api::accept_session(&mut bob, &alice_bundle.identity_key, &a_first).unwrap();

    // Bob replenishes; fresh keys are returned.
    let fresh = api::replenish_prekeys(&mut bob, 3);
    assert_eq!(fresh.one_time_keys.len(), 3);
    assert_eq!(
        fresh.identity_key, bob_first_bundle.identity_key,
        "identity stable"
    );

    // A new sender can establish a session with a fresh key.
    let mut dave = api::create_identity();
    let dave_bundle = api::publish_bundle(&mut dave, 1);
    let mut d_sess =
        api::start_session(&dave, &fresh.identity_key, &fresh.one_time_keys[0]).unwrap();
    let d_first = api::encrypt(&mut d_sess, b"after replenish").unwrap();
    let (_s, pt) = api::accept_session(&mut bob, &dave_bundle.identity_key, &d_first).unwrap();
    assert_eq!(pt, b"after replenish");
}

/// The device reports a sane maximum one-time-key capacity.
#[test]
fn max_one_time_keys_is_positive() {
    let bob = api::create_identity();
    assert!(api::max_one_time_keys(&bob) >= 1);
}

// ---------------------------------------------------------------------------
// Fallback key (the X3DH "signed prekey" role).
//
// Without a fallback key, a device whose one-time keys are all consumed is
// simply unreachable until it replenishes — a silent availability failure for
// popular or long-idle accounts. The fallback key is not consumed by use, so it
// keeps the device reachable indefinitely.
// ---------------------------------------------------------------------------

/// THE PROPERTY THE WHOLE FEATURE EXISTS FOR.
///
/// Bob published exactly one one-time key and Alice took it. Before the fallback
/// key, Carol was stuck: no key to fetch, no way to send a first message, no
/// error the user could act on. Now the server hands Carol the fallback key and
/// her message opens.
#[test]
fn a_sender_can_reach_a_device_whose_one_time_keys_are_gone() {
    let mut bob = api::create_identity();
    let bob_bundle = api::publish_bundle(&mut bob, 1);
    let bob_id = &bob_bundle.identity_key;
    let fallback = bob_bundle
        .fallback_key
        .as_ref()
        .expect("first bundle must carry a fallback key");

    // Alice consumes Bob's only one-time key.
    let mut alice = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let mut a_sess = api::start_session(&alice, bob_id, &bob_bundle.one_time_keys[0]).unwrap();
    let a_first = api::encrypt(&mut a_sess, b"from alice").unwrap();
    api::accept_session(&mut bob, &alice_bundle.identity_key, &a_first).unwrap();

    // Carol arrives with no one-time key left to fetch, and uses the fallback.
    let mut carol = api::create_identity();
    let carol_bundle = api::publish_bundle(&mut carol, 1);
    let mut c_sess = api::start_session(&carol, bob_id, fallback).unwrap();
    let c_first = api::encrypt(&mut c_sess, b"from carol").unwrap();

    let (_s, plaintext) =
        api::accept_session(&mut bob, &carol_bundle.identity_key, &c_first).unwrap();
    assert_eq!(plaintext, b"from carol");
}

/// Unlike a one-time key, the fallback key is NOT consumed — that is the whole
/// point. Several senders must all get through with it.
#[test]
fn the_fallback_key_is_not_consumed_by_use() {
    let mut bob = api::create_identity();
    let bob_bundle = api::publish_bundle(&mut bob, 0);
    let bob_id = &bob_bundle.identity_key;
    let fallback = bob_bundle.fallback_key.as_ref().unwrap();

    for i in 0..3 {
        let mut sender = api::create_identity();
        let sender_bundle = api::publish_bundle(&mut sender, 1);
        let mut sess = api::start_session(&sender, bob_id, fallback).unwrap();
        let msg = api::encrypt(&mut sess, b"hello").unwrap();
        let (_s, plaintext) = api::accept_session(&mut bob, &sender_bundle.identity_key, &msg)
            .unwrap_or_else(|e| panic!("sender {i} could not reach Bob via fallback: {e:?}"));
        assert_eq!(plaintext, b"hello");
    }
}

/// Rotation issues a NEW key, and the PREVIOUS one still opens sessions that were
/// already in flight against it. If rotation invalidated the old key immediately,
/// every message sent in the rotation window would fail to decrypt.
#[test]
fn rotation_issues_a_new_key_and_the_previous_one_still_opens_in_flight_messages() {
    let mut bob = api::create_identity();
    let first = api::publish_bundle(&mut bob, 0);
    let bob_id = first.identity_key.clone();
    let old_fallback = first.fallback_key.clone().unwrap();

    // Alice fetched the old key and is composing while Bob rotates.
    let mut alice = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let mut a_sess = api::start_session(&alice, &bob_id, &old_fallback).unwrap();
    let a_first = api::encrypt(&mut a_sess, b"sent before rotation").unwrap();

    let rotated = api::rotate_fallback_key(&mut bob);
    let new_fallback = rotated.fallback_key.clone().unwrap();
    assert_ne!(new_fallback, old_fallback, "rotation must issue a new key");

    // Alice's in-flight message still opens against the retired key.
    let (_s, plaintext) =
        api::accept_session(&mut bob, &alice_bundle.identity_key, &a_first).unwrap();
    assert_eq!(plaintext, b"sent before rotation");

    // And the new key works for anyone arriving after.
    let mut carol = api::create_identity();
    let carol_bundle = api::publish_bundle(&mut carol, 1);
    let mut c_sess = api::start_session(&carol, &bob_id, &new_fallback).unwrap();
    let c_first = api::encrypt(&mut c_sess, b"sent after rotation").unwrap();
    let (_s, plaintext) =
        api::accept_session(&mut bob, &carol_bundle.identity_key, &c_first).unwrap();
    assert_eq!(plaintext, b"sent after rotation");
}

/// Forgetting the previous key closes the window: sessions can no longer be
/// established against a retired fallback key. This is the forward-secrecy half
/// of rotation — without it, rotating would accomplish nothing.
#[test]
fn forgetting_the_previous_key_closes_the_window() {
    let mut bob = api::create_identity();
    let first = api::publish_bundle(&mut bob, 0);
    let bob_id = first.identity_key.clone();
    let old_fallback = first.fallback_key.clone().unwrap();

    // A sender who kept the old key around and only now tries to use it.
    let mut mallory = api::create_identity();
    let mallory_bundle = api::publish_bundle(&mut mallory, 1);
    let mut m_sess = api::start_session(&mallory, &bob_id, &old_fallback).unwrap();
    let m_first = api::encrypt(&mut m_sess, b"stale key").unwrap();

    api::rotate_fallback_key(&mut bob);
    assert!(
        api::forget_previous_fallback_key(&mut bob),
        "there was a previous key to forget"
    );

    assert!(
        api::accept_session(&mut bob, &mallory_bundle.identity_key, &m_first).is_err(),
        "a forgotten fallback key must not establish a session"
    );
}

/// The first bundle a device ever publishes must carry a fallback key. If it
/// didn't, a device would be reachable only until its one-time keys ran out —
/// exactly the hole this closes.
#[test]
fn the_first_bundle_always_carries_a_fallback_key() {
    let mut device = api::create_identity();
    assert!(api::current_fallback_key(&device).is_none());

    let bundle = api::publish_bundle(&mut device, 5);
    assert!(bundle.fallback_key.is_some());
    assert_eq!(api::current_fallback_key(&device), bundle.fallback_key);
}

/// Replenishing one-time keys must not silently rotate the fallback key — they
/// are on independent schedules, and an accidental rotation would retire a key
/// the backend is still handing out.
#[test]
fn replenishing_one_time_keys_does_not_rotate_the_fallback_key() {
    let mut bob = api::create_identity();
    let first = api::publish_bundle(&mut bob, 1);
    let original = first.fallback_key.clone().unwrap();

    let topped_up = api::replenish_prekeys(&mut bob, 5);
    assert!(
        topped_up.fallback_key.is_none(),
        "replenish should report no NEW fallback key"
    );
    assert_eq!(
        api::current_fallback_key(&bob),
        Some(original),
        "the live fallback key must be unchanged"
    );
}

/// The fallback key survives a persist/restore cycle: sessions started against it
/// still open after the app restarts. The private half rides along in the pickle.
#[test]
fn the_fallback_key_survives_persistence() {
    let pickle_key = [7u8; 32];
    let mut bob = api::create_identity();
    let bundle = api::publish_bundle(&mut bob, 0);
    let bob_id = bundle.identity_key.clone();
    let fallback = bundle.fallback_key.clone().unwrap();

    let pickled = bob.to_pickle(&pickle_key);
    let mut restored =
        voiid_e2e_core::IdentityKeys::from_pickle(&pickled, &pickle_key).expect("restore identity");

    let mut alice = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let mut a_sess = api::start_session(&alice, &bob_id, &fallback).unwrap();
    let a_first = api::encrypt(&mut a_sess, b"after restart").unwrap();

    let (_s, plaintext) =
        api::accept_session(&mut restored, &alice_bundle.identity_key, &a_first).unwrap();
    assert_eq!(plaintext, b"after restart");
}
