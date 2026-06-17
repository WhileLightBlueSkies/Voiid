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
