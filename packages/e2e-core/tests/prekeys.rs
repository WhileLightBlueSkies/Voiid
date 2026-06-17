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
    let mut a_sess =
        api::start_session(&alice, &bob_first_bundle.identity_key, &bob_first_bundle.one_time_keys[0])
            .unwrap();
    let a_first = api::encrypt(&mut a_sess, b"first").unwrap();
    api::accept_session(&mut bob, &alice_bundle.identity_key, &a_first).unwrap();

    // Bob replenishes; fresh keys are returned.
    let fresh = api::replenish_prekeys(&mut bob, 3);
    assert_eq!(fresh.one_time_keys.len(), 3);
    assert_eq!(fresh.identity_key, bob_first_bundle.identity_key, "identity stable");

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
