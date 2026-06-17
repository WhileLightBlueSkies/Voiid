//! Phase 4 tests: 1:1 and group call key derivation.

use voiid_e2e_core::api;

/// Both parties in a 1:1 call derive identical SRTP keys from the shared secret
/// that travelled over the ratchet.
#[test]
fn one_to_one_call_keys_match() {
    // Establish a 1:1 session and send the call secret over it.
    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let bob_bundle = api::publish_bundle(&mut bob, 1);
    let otk = bob_bundle.one_time_keys.first().unwrap();
    let mut alice_session = api::start_session(&alice, &bob_bundle.identity_key, otk).unwrap();

    let secret = api::new_call_secret();
    let payload = serde_json::to_vec(&secret).unwrap();
    let wire = api::encrypt(&mut alice_session, &payload).unwrap();

    let (_bob_session, recv) =
        api::accept_session(&mut bob, &alice_bundle.identity_key, &wire).unwrap();
    let bob_secret: voiid_e2e_core::CallSecret = serde_json::from_slice(&recv).unwrap();

    let alice_keys = api::srtp_keys_for_1to1(&secret).unwrap();
    let bob_keys = api::srtp_keys_for_1to1(&bob_secret).unwrap();

    assert_eq!(alice_keys, bob_keys);
    assert_eq!(alice_keys.master_key.len(), 16);
    assert_eq!(alice_keys.master_salt.len(), 14);
}

/// Different call secrets derive different keys (no fixed/predictable output).
#[test]
fn distinct_secrets_distinct_keys() {
    let a = api::srtp_keys_for_1to1(&api::new_call_secret()).unwrap();
    let b = api::srtp_keys_for_1to1(&api::new_call_secret()).unwrap();
    assert_ne!(a, b);
}

/// All group members derive identical SRTP keys for a group call.
#[test]
fn group_call_keys_match() {
    use voiid_e2e_core::GroupMember;

    let alice = GroupMember::new(b"alice").unwrap();
    let bob = GroupMember::new(b"bob").unwrap();
    let bob_kp = bob.key_package().unwrap();

    let mut alice_group = alice.create_group().unwrap();
    let add = alice_group.add_member(&alice, &bob_kp).unwrap();
    let bob_group = bob.join_group(&add.welcome, &add.ratchet_tree).unwrap();

    let alice_keys = api::srtp_keys_for_group(&alice_group, &alice).unwrap();
    let bob_keys = api::srtp_keys_for_group(&bob_group, &bob).unwrap();
    assert_eq!(alice_keys, bob_keys);
    assert_eq!(alice_keys.master_key.len(), 16);
}
