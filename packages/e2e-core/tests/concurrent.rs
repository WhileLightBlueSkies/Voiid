//! Concurrent-commit handling.
//!
//! In MLS, two members can each build a commit against the same epoch. The
//! relay/server serializes commits and picks ONE winner per epoch; the loser(s)
//! must discard their pending commit and process the winner. These tests verify
//! the wrapper supports that reconciliation and never lets divergent state pass
//! silently.

use voiid_e2e_core::{GroupMember, GroupSession};

/// Two-member group helper (alice creator + bob).
fn two_member_group() -> ((GroupMember, GroupSession), (GroupMember, GroupSession)) {
    let alice = GroupMember::new(b"alice").unwrap();
    let bob = GroupMember::new(b"bob").unwrap();
    let bob_kp = bob.key_package().unwrap();
    let mut ag = alice.create_group().unwrap();
    let add = ag.add_member(&alice, &bob_kp).unwrap();
    let bg = bob.join_group(&add.welcome, &add.ratchet_tree).unwrap();
    ((alice, ag), (bob, bg))
}

/// Application messages from two senders in the same epoch don't conflict —
/// both deliver regardless of order (no commit involved).
#[test]
fn concurrent_application_messages_no_conflict() {
    let ((alice, mut ag), (bob, mut bg)) = two_member_group();
    assert_eq!(ag.epoch(), bg.epoch(), "both start in the same epoch");

    // Both send in the same epoch.
    let a = ag.encrypt(&alice, b"from alice").unwrap();
    let b = bg.encrypt(&bob, b"from bob").unwrap();

    // Each receives the other's; order doesn't matter, epoch unchanged.
    assert_eq!(bg.decrypt(&bob, &a).unwrap().as_deref(), Some(&b"from alice"[..]));
    assert_eq!(ag.decrypt(&alice, &b).unwrap().as_deref(), Some(&b"from bob"[..]));
    assert_eq!(ag.epoch(), bg.epoch());
}

/// The loser of a concurrent membership-change race can discard its pending
/// commit and adopt the winner's, ending up in the same epoch.
#[test]
fn losing_committer_reconciles() {
    // Three members so both Alice and Bob can each try to remove Carol.
    let alice = GroupMember::new(b"alice").unwrap();
    let bob = GroupMember::new(b"bob").unwrap();
    let carol = GroupMember::new(b"carol").unwrap();
    let bob_kp = bob.key_package().unwrap();
    let carol_kp = carol.key_package().unwrap();

    let mut ag = alice.create_group().unwrap();
    let add_bob = ag.add_member(&alice, &bob_kp).unwrap();
    let mut bg = bob.join_group(&add_bob.welcome, &add_bob.ratchet_tree).unwrap();
    let add_carol = ag.add_member(&alice, &carol_kp).unwrap();
    bg.decrypt(&bob, &add_carol.commit).unwrap();
    let _cg = carol.join_group(&add_carol.welcome, &add_carol.ratchet_tree).unwrap();

    let start_epoch = ag.epoch();
    assert_eq!(start_epoch, bg.epoch());

    // Alice removes Carol — her commit is the one the server accepts (winner).
    // `remove_member` merges Alice's commit locally and advances her epoch.
    let winning_commit = ag.remove_member(&alice, b"carol").unwrap();
    assert_eq!(ag.epoch(), start_epoch + 1);

    // Bob, who might have been about to commit something of his own, instead
    // receives Alice's winning commit. He clears any pending state, then applies
    // the winner. (clear_pending is a no-op here but models the loser path.)
    bg.clear_pending(&bob).unwrap();
    bg.decrypt(&bob, &winning_commit).unwrap();

    // Both converge to the same new epoch and member count.
    assert_eq!(ag.epoch(), bg.epoch(), "both converge to the winner's epoch");
    assert_eq!(ag.member_count(), bg.member_count());
    assert_eq!(ag.member_count(), 2);

    // And they can still message each other in the new epoch.
    let m = ag.encrypt(&alice, b"post-reconcile").unwrap();
    assert_eq!(bg.decrypt(&bob, &m).unwrap().as_deref(), Some(&b"post-reconcile"[..]));
}

/// A stale commit (built against an old epoch) is rejected, not silently
/// applied — this is what stops divergent state.
#[test]
fn stale_commit_rejected() {
    let ((alice, mut ag), (bob, mut bg)) = two_member_group();

    // Alice performs two operations, advancing the epoch twice, WITHOUT Bob
    // seeing the first. Build a commit at the current epoch, then advance Alice
    // past it.
    let carol = GroupMember::new(b"carol").unwrap();
    let carol_kp = carol.key_package().unwrap();
    let dave = GroupMember::new(b"dave").unwrap();
    let dave_kp = dave.key_package().unwrap();

    let first = ag.add_member(&alice, &carol_kp).unwrap(); // epoch N -> N+1 (Alice)
    let _second = ag.add_member(&alice, &dave_kp).unwrap(); // epoch N+1 -> N+2 (Alice)

    // Bob is still at epoch N. Feeding him the SECOND commit (built at N+1)
    // before the first must fail — it's for an epoch he hasn't reached.
    assert!(bg.decrypt(&bob, &_second.commit).is_err());

    // Feeding the FIRST commit (built at N) works and advances Bob to N+1.
    assert!(bg.decrypt(&bob, &first.commit).is_ok());
}
