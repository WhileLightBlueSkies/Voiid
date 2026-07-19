//! Phase 3 tests: MLS group creation, joining, messaging, and call-key export.

use voiid_e2e_core::{GroupMember, GroupSession};

/// Alice creates a group, adds Bob, and they exchange a group message.
#[test]
fn two_member_group_message() {
    let alice = GroupMember::new(b"alice-device").expect("alice identity");
    let bob = GroupMember::new(b"bob-device").expect("bob identity");

    // Bob publishes a KeyPackage (to the backend in the real app).
    let bob_kp = bob.key_package().expect("bob key package");

    // Alice creates the group and adds Bob (the commit is merged internally).
    let mut alice_group = alice.create_group().expect("create group");
    let add = alice_group.add_member(&alice, &bob_kp).expect("add bob");

    // Bob joins from the Welcome + ratchet tree.
    let mut bob_group: GroupSession = bob
        .join_group(&add.welcome, &add.ratchet_tree)
        .expect("bob joins");

    // Alice -> group.
    let ct = alice_group.encrypt(&alice, b"hello group").expect("encrypt");
    let pt = bob_group.decrypt(&bob, &ct).expect("bob decrypts");
    assert_eq!(pt.as_deref(), Some(&b"hello group"[..]));

    // Bob -> group.
    let ct2 = bob_group.encrypt(&bob, b"hi alice").expect("encrypt 2");
    let pt2 = alice_group.decrypt(&alice, &ct2).expect("alice decrypts");
    assert_eq!(pt2.as_deref(), Some(&b"hi alice"[..]));
}

/// All members derive the SAME group call key from the exporter secret.
#[test]
fn group_call_key_agreement() {
    let alice = GroupMember::new(b"alice").unwrap();
    let bob = GroupMember::new(b"bob").unwrap();
    let bob_kp = bob.key_package().unwrap();

    let mut alice_group = alice.create_group().unwrap();
    let add = alice_group.add_member(&alice, &bob_kp).unwrap();
    let bob_group = bob.join_group(&add.welcome, &add.ratchet_tree).unwrap();

    let alice_key = alice_group.export_call_key(&alice, 32).unwrap();
    let bob_key = bob_group.export_call_key(&bob, 32).unwrap();
    assert_eq!(alice_key, bob_key, "members must derive the same call key");
    assert_eq!(alice_key.len(), 32);
}

// ---- MLS state persistence across app restart (serialize / restore / load_group) ----

/// A member serialized after joining a group can be restored (simulating an app
/// restart) and still send AND receive in that group — the MLS ratchet state
/// survived the round-trip.
#[test]
fn member_survives_restart() {
    let alice = GroupMember::new(b"alice-device").unwrap();
    let bob = GroupMember::new(b"bob-device").unwrap();
    let bob_kp = bob.key_package().unwrap();

    let mut alice_group = alice.create_group().unwrap();
    let add = alice_group.add_member(&alice, &bob_kp).unwrap();
    let mut bob_group: GroupSession = bob.join_group(&add.welcome, &add.ratchet_tree).unwrap();
    let group_id = alice_group.group_id();

    // Simulate a restart: serialize Alice + her group state, drop everything, restore.
    let alice_blob = alice.serialize().unwrap();
    drop(alice_group);
    drop(alice);
    let alice2 = GroupMember::restore(&alice_blob).unwrap();
    let mut alice_group2 = alice2.load_group(&group_id).unwrap();

    assert_eq!(alice_group2.member_count(), 2, "restored group keeps its membership");

    // Restored Alice -> Bob.
    let ct = alice_group2.encrypt(&alice2, b"after restart").unwrap();
    let pt = bob_group.decrypt(&bob, &ct).unwrap();
    assert_eq!(pt.as_deref(), Some(&b"after restart"[..]));

    // Bob -> restored Alice.
    let ct2 = bob_group.encrypt(&bob, b"welcome back").unwrap();
    let pt2 = alice_group2.decrypt(&alice2, &ct2).unwrap();
    assert_eq!(pt2.as_deref(), Some(&b"welcome back"[..]));
}

/// BOTH members restart (independently) and the group keeps working.
#[test]
fn both_members_survive_restart() {
    let alice = GroupMember::new(b"alice").unwrap();
    let bob = GroupMember::new(b"bob").unwrap();
    let bob_kp = bob.key_package().unwrap();

    let mut alice_group = alice.create_group().unwrap();
    let add = alice_group.add_member(&alice, &bob_kp).unwrap();
    let bob_group: GroupSession = bob.join_group(&add.welcome, &add.ratchet_tree).unwrap();
    let gid = alice_group.group_id();

    let alice_blob = alice.serialize().unwrap();
    let bob_blob = bob.serialize().unwrap();
    let bob_gid = bob_group.group_id();
    drop(alice_group);
    drop(bob_group);

    let alice2 = GroupMember::restore(&alice_blob).unwrap();
    let bob2 = GroupMember::restore(&bob_blob).unwrap();
    let mut alice_g = alice2.load_group(&gid).unwrap();
    let mut bob_g = bob2.load_group(&bob_gid).unwrap();

    let ct = alice_g.encrypt(&alice2, b"both restarted").unwrap();
    let pt = bob_g.decrypt(&bob2, &ct).unwrap();
    assert_eq!(pt.as_deref(), Some(&b"both restarted"[..]));
}

/// After restoring, a member can still perform group operations — e.g. add a
/// third member — proving the signer + provider are fully functional post-restore.
#[test]
fn restored_member_can_add_member() {
    let alice = GroupMember::new(b"alice").unwrap();
    let bob = GroupMember::new(b"bob").unwrap();
    let carol = GroupMember::new(b"carol").unwrap();

    let mut alice_group = alice.create_group().unwrap();
    let add_bob = alice_group.add_member(&alice, &bob.key_package().unwrap()).unwrap();
    let mut bob_group: GroupSession = bob.join_group(&add_bob.welcome, &add_bob.ratchet_tree).unwrap();
    let gid = alice_group.group_id();

    // Alice restarts.
    let blob = alice.serialize().unwrap();
    drop(alice_group);
    let alice2 = GroupMember::restore(&blob).unwrap();
    let mut alice_g = alice2.load_group(&gid).unwrap();

    // Restored Alice adds Carol.
    let add_carol = alice_g.add_member(&alice2, &carol.key_package().unwrap()).unwrap();
    let mut carol_group: GroupSession = carol.join_group(&add_carol.welcome, &add_carol.ratchet_tree).unwrap();
    assert_eq!(alice_g.member_count(), 3);

    // Bob applies the commit and everyone can talk.
    assert_eq!(bob_group.decrypt(&bob, &add_carol.commit).unwrap(), None, "commit applied, no plaintext");
    let ct = alice_g.encrypt(&alice2, b"carol is here").unwrap();
    assert_eq!(bob_group.decrypt(&bob, &ct).unwrap().as_deref(), Some(&b"carol is here"[..]));
    assert_eq!(carol_group.decrypt(&carol, &ct).unwrap().as_deref(), Some(&b"carol is here"[..]));
}

/// load_group with an unknown group id fails cleanly (no panic).
#[test]
fn load_unknown_group_errors() {
    let alice = GroupMember::new(b"alice").unwrap();
    let _g = alice.create_group().unwrap();
    let blob = alice.serialize().unwrap();
    let alice2 = GroupMember::restore(&blob).unwrap();
    assert!(alice2.load_group(b"no-such-group").is_err());
}

/// A restored member re-serializes to a blob that still restores (idempotent).
#[test]
fn restore_roundtrip_is_stable() {
    let alice = GroupMember::new(b"alice").unwrap();
    let mut g = alice.create_group().unwrap();
    g.add_member(&alice, &GroupMember::new(b"bob").unwrap().key_package().unwrap()).ok();
    let gid = g.group_id();

    let blob1 = alice.serialize().unwrap();
    let alice2 = GroupMember::restore(&blob1).unwrap();
    let blob2 = alice2.serialize().unwrap();
    let alice3 = GroupMember::restore(&blob2).unwrap();
    // Still able to open the group after two round-trips.
    assert_eq!(alice3.load_group(&gid).unwrap().member_count(), 2);
}
