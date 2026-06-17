//! Group membership churn: remove a member (and verify they're locked out),
//! then re-add them.

use voiid_e2e_core::{GroupMember, GroupSession};

/// Build a 3-member group (alice creator, bob, carol). Returns each member's
/// identity handle and their joined GroupSession.
fn three_member_group() -> (
    (GroupMember, GroupSession),
    (GroupMember, GroupSession),
    (GroupMember, GroupSession),
) {
    let alice = GroupMember::new(b"alice").unwrap();
    let bob = GroupMember::new(b"bob").unwrap();
    let carol = GroupMember::new(b"carol").unwrap();

    let bob_kp = bob.key_package().unwrap();
    let carol_kp = carol.key_package().unwrap();

    let mut ag = alice.create_group().unwrap();

    // Add Bob.
    let add_bob = ag.add_member(&alice, &bob_kp).unwrap();
    let mut bg = bob.join_group(&add_bob.welcome, &add_bob.ratchet_tree).unwrap();

    // Add Carol. Bob must process the add commit to stay in sync.
    let add_carol = ag.add_member(&alice, &carol_kp).unwrap();
    bg.decrypt(&bob, &add_carol.commit).unwrap(); // process commit (returns None)
    let cg = carol
        .join_group(&add_carol.welcome, &add_carol.ratchet_tree)
        .unwrap();

    ((alice, ag), (bob, bg), (carol, cg))
}

/// After removal, the remaining members keep talking and the removed member
/// can no longer decrypt new messages.
#[test]
fn remove_locks_out_member() {
    let ((alice, mut ag), (bob, mut bg), (carol, mut cg)) = three_member_group();
    assert_eq!(ag.member_count(), 3);

    // Sanity: all three can exchange a message first.
    let hello = ag.encrypt(&alice, b"hi all").unwrap();
    assert_eq!(bg.decrypt(&bob, &hello).unwrap().as_deref(), Some(&b"hi all"[..]));
    assert_eq!(cg.decrypt(&carol, &hello).unwrap().as_deref(), Some(&b"hi all"[..]));

    // Alice removes Carol; Bob processes the removal commit.
    let commit = ag.remove_member(&alice, b"carol").unwrap();
    bg.decrypt(&bob, &commit).unwrap();
    assert_eq!(ag.member_count(), 2);

    // Alice and Bob can still talk.
    let after = ag.encrypt(&alice, b"carol is gone").unwrap();
    assert_eq!(bg.decrypt(&bob, &after).unwrap().as_deref(), Some(&b"carol is gone"[..]));

    // Carol, with stale state, must NOT be able to decrypt the post-removal
    // message. (She never received the rekeying commit, and even the ciphertext
    // is under the new epoch's keys.)
    assert!(cg.decrypt(&carol, &after).is_err());
}

/// A removed member can be re-added and resumes participating.
#[test]
fn re_add_after_removal() {
    let ((alice, mut ag), (bob, mut bg), (_carol, mut _cg)) = three_member_group();

    // Remove Carol.
    let commit = ag.remove_member(&alice, b"carol").unwrap();
    bg.decrypt(&bob, &commit).unwrap();
    assert_eq!(ag.member_count(), 2);

    // Re-add Carol. A re-joining client starts with fresh per-group key state,
    // so she rejoins as a fresh GroupMember (same stable identity label). This
    // mirrors a real client that left and comes back with a new KeyPackage.
    let carol2 = GroupMember::new(b"carol").unwrap();
    let carol_kp2 = carol2.key_package().unwrap();
    let re = ag.add_member(&alice, &carol_kp2).unwrap();
    bg.decrypt(&bob, &re.commit).unwrap();
    let mut cg2 = carol2.join_group(&re.welcome, &re.ratchet_tree).unwrap();
    assert_eq!(ag.member_count(), 3);

    // Carol receives group messages again.
    let msg = ag.encrypt(&alice, b"welcome back carol").unwrap();
    assert_eq!(
        cg2.decrypt(&carol2, &msg).unwrap().as_deref(),
        Some(&b"welcome back carol"[..])
    );
}

/// Removing a non-existent member fails cleanly.
#[test]
fn remove_unknown_member_errors() {
    let ((alice, mut ag), _, _) = three_member_group();
    assert!(ag.remove_member(&alice, b"nobody").is_err());
}
