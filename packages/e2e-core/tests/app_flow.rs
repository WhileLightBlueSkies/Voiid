//! Reproduce the EXACT app bootstrap + send/accept sequence to chase the
//! "first message of a fresh conversation fails acceptSession, rest succeed" bug.

use voiid_e2e_core::{api, IdentityKeys};

const PK: [u8; 32] = [9u8; 32];

/// Mimics Android receiver bootstrap: create → publishBundle(0) [register] →
/// persist → replenish(50) → persist → upload. Then iOS sender fetches the FIRST
/// (oldest) one-time key, starts a session, sends msg1. Receiver restores from the
/// persisted pickle (as the app does on a fresh process) and accepts msg1.
#[test]
fn first_message_decrypts_after_register_then_replenish() {
    // ---- Receiver (Bob / Android) bootstrap, exactly like E2EManager ----
    let mut bob = api::create_identity();
    let _ = api::publish_bundle(&mut bob, 0); // register: identity key only
    let bob_pickle_after_register = bob.to_pickle(&PK);
    // restore (app persists + later reads back)
    let mut bob = IdentityKeys::from_pickle(&bob_pickle_after_register, &PK).unwrap();

    let bundle = api::replenish_prekeys(&mut bob, 50); // ensurePrekeys
    let bob_pickle = bob.to_pickle(&PK); // persist BEFORE upload (app order)
    assert_eq!(bundle.one_time_keys.len(), 50, "should publish 50 OTKs");

    // The server hands out the OLDEST key first (order by created_at limit 1).
    // Our bundle Vec order may differ from server order, so test BOTH the first
    // and a middle key to see if a specific position fails.
    let first_otk = bundle.one_time_keys.first().unwrap().clone();

    // ---- Sender (Alice / iOS) ----
    let mut alice = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 0);

    let mut alice_sess =
        api::start_session(&alice, &bundle.identity_key, &first_otk).expect("start");
    let msg1 = api::encrypt(&mut alice_sess, b"FIRST message").expect("enc1");
    let msg2 = api::encrypt(&mut alice_sess, b"second message").expect("enc2");

    // ---- Receiver restores from the persisted pickle and accepts ----
    let mut bob2 = IdentityKeys::from_pickle(&bob_pickle, &PK).unwrap();
    let (mut sess, pt1) = api::accept_session(&mut bob2, &alice_bundle.identity_key, &msg1)
        .expect("FIRST message must accept+decrypt");
    assert_eq!(pt1, b"FIRST message");

    // Second message should decrypt on the same session.
    let pt2 = api::decrypt(&mut sess, &msg2).expect("second decrypts");
    assert_eq!(pt2, b"second message");
}

/// Same, but the sender uses EVERY one of the 50 published keys in turn — proves
/// every published key the server could hand out is actually accept-able.
#[test]
fn every_published_otk_is_acceptable() {
    let mut bob = api::create_identity();
    let _ = api::publish_bundle(&mut bob, 0);
    let bundle = api::replenish_prekeys(&mut bob, 50);
    let bob_pickle = bob.to_pickle(&PK);

    let mut alice = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 0);

    for (i, otk) in bundle.one_time_keys.iter().enumerate() {
        let mut a = api::start_session(&alice, &bundle.identity_key, otk)
            .unwrap_or_else(|e| panic!("start with otk #{i}: {e:?}"));
        let m = api::encrypt(&mut a, b"hi").unwrap();
        // fresh restore each time (each accept consumes one key)
        let mut b = IdentityKeys::from_pickle(&bob_pickle, &PK).unwrap();
        let (_s, pt) = api::accept_session(&mut b, &alice_bundle.identity_key, &m)
            .unwrap_or_else(|e| panic!("accept with otk #{i}: {e:?}"));
        assert_eq!(pt, b"hi", "otk #{i} failed to decrypt");
    }
}
