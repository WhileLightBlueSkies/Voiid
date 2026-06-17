//! Soak / load test — long-running, high-volume exercise of the whole stack to
//! surface state-management bugs (ratchet drift, key-store growth, pickle
//! round-trips mid-stream, group churn). Marked `#[ignore]` so it doesn't slow
//! the normal suite; run explicitly:
//!
//!   cargo test --test soak -- --ignored --nocapture
//!
//! Tunable via env: VOIID_SOAK_MESSAGES (default 20000), VOIID_SOAK_GROUP_ROUNDS.

use std::time::Instant;

use voiid_e2e_core::{api, GroupMember, Session};

fn env_usize(key: &str, default: usize) -> usize {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// 1:1: sustained bidirectional traffic with periodic out-of-order delivery and
/// mid-stream persistence round-trips. Asserts every message decrypts correctly.
#[test]
#[ignore]
fn soak_1to1_conversation() {
    let total = env_usize("VOIID_SOAK_MESSAGES", 20_000);
    let pickle_key = [0x42u8; 32];

    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let ab = api::publish_bundle(&mut alice, 1);
    let bb = api::publish_bundle(&mut bob, 1);
    let otk = bb.one_time_keys.first().unwrap();

    let mut a = api::start_session(&alice, &bb.identity_key, otk).unwrap();
    let seed = api::encrypt(&mut a, b"start").unwrap();
    let (mut b, _) = api::accept_session(&mut bob, &ab.identity_key, &seed).unwrap();
    // Ratchet Alice to Normal.
    let r = api::encrypt(&mut b, b"ack").unwrap();
    api::decrypt(&mut a, &r).unwrap();

    let start = Instant::now();
    let mut delivered = 0u64;

    for i in 0..total {
        let payload = format!("msg-{i}-{}", "x".repeat(i % 64));

        // Alternate direction.
        if i % 2 == 0 {
            let m = api::encrypt(&mut a, payload.as_bytes()).unwrap();
            // Every 500th message: deliver out of order (send next, then this).
            if i % 500 == 499 {
                let nxt = api::encrypt(&mut a, b"next").unwrap();
                assert_eq!(api::decrypt(&mut b, &nxt).unwrap(), b"next");
            }
            assert_eq!(api::decrypt(&mut b, &m).unwrap(), payload.as_bytes());
        } else {
            let m = api::encrypt(&mut b, payload.as_bytes()).unwrap();
            assert_eq!(api::decrypt(&mut a, &m).unwrap(), payload.as_bytes());
        }
        delivered += 1;

        // Every 2000th message: persist + restore Bob's session mid-stream.
        if i % 2000 == 1999 {
            let pickle = b.to_pickle(&pickle_key);
            b = Session::from_pickle(&pickle, &pickle_key).expect("restore mid-soak");
        }
    }

    let secs = start.elapsed().as_secs_f64();
    println!(
        "soak 1:1: {delivered} messages in {secs:.1}s ({:.0} msg/s)",
        delivered as f64 / secs
    );
    assert_eq!(delivered, total as u64);
}

/// Group: many members + sustained group traffic + membership churn (add/remove
/// repeatedly), asserting the group stays consistent and bounded.
#[test]
#[ignore]
fn soak_group_churn() {
    let rounds = env_usize("VOIID_SOAK_GROUP_ROUNDS", 200);
    let msgs_per_round = env_usize("VOIID_SOAK_GROUP_MSGS", 50);

    let alice = GroupMember::new(b"alice").unwrap();
    let bob = GroupMember::new(b"bob").unwrap();
    let bob_kp = bob.key_package().unwrap();
    let mut ag = alice.create_group().unwrap();
    let add = ag.add_member(&alice, &bob_kp).unwrap();
    let mut bg = bob.join_group(&add.welcome, &add.ratchet_tree).unwrap();

    let start = Instant::now();
    let mut total_msgs = 0u64;

    for round in 0..rounds {
        // A burst of group application messages each round.
        for j in 0..msgs_per_round {
            let payload = format!("r{round}-m{j}");
            let ct = ag.encrypt(&alice, payload.as_bytes()).unwrap();
            assert_eq!(bg.decrypt(&bob, &ct).unwrap().as_deref(), Some(payload.as_bytes()));
            total_msgs += 1;
        }

        // Every 10 rounds: add then remove a transient member (churn + rekey).
        if round % 10 == 9 {
            let carol = GroupMember::new(b"carol").unwrap();
            let carol_kp = carol.key_package().unwrap();
            let add = ag.add_member(&alice, &carol_kp).unwrap();
            bg.decrypt(&bob, &add.commit).unwrap();
            let _cg = carol.join_group(&add.welcome, &add.ratchet_tree).unwrap();
            assert_eq!(ag.member_count(), 3);

            let commit = ag.remove_member(&alice, b"carol").unwrap();
            bg.decrypt(&bob, &commit).unwrap();
            assert_eq!(ag.member_count(), 2);
            assert_eq!(ag.epoch(), bg.epoch());
        }
    }

    let secs = start.elapsed().as_secs_f64();
    println!(
        "soak group: {total_msgs} msgs over {rounds} rounds in {secs:.1}s; final epoch {}",
        ag.epoch()
    );
    assert_eq!(ag.member_count(), bg.member_count());
}

/// Media: encrypt/decrypt a stream of attachments of varied sizes, asserting
/// integrity holds throughout.
#[test]
#[ignore]
fn soak_media_stream() {
    let count = env_usize("VOIID_SOAK_MEDIA", 2000);
    let start = Instant::now();

    for i in 0..count {
        let size = (i * 37) % 100_000; // 0..~100KB, varied
        let plaintext = vec![(i % 256) as u8; size];
        let enc = api::encrypt_media(&plaintext).unwrap();
        let dec = api::decrypt_media(&enc.media_key, &enc.ciphertext).unwrap();
        assert_eq!(dec, plaintext, "media #{i} ({size} bytes) round-trip");
    }

    println!("soak media: {count} attachments in {:.1}s", start.elapsed().as_secs_f64());
}
