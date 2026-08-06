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

/// Grow a group to N leaves and measure what that costs on the wire.
///
/// THE UNMEASURED RISK THIS EXISTS TO MEASURE. Voiid targets 1000-member groups, and the
/// MLS core has no cap — but no test in this repo has ever exceeded three members, and the
/// leaf keys are X-Wing/ML-KEM-768. Post-quantum KEM public keys are large, and a Welcome
/// carries the ratchet tree, so Welcome size grows with membership. Multi-megabyte Welcomes
/// at N=1000 are plausible and nobody has ever looked.
///
/// MEASURED 2026-08-06 on this machine, release build. The feared multi-megabyte Welcome
/// did NOT materialise, and the reason is worth knowing:
///
///     n=1     welcome 1467 B   tree     3.9 KB   add    1.7 ms
///     n=100   welcome 1467 B   tree   146   KB   add   11   ms
///     n=1000  welcome 1467 B   tree  1376   KB   add   93   ms
///     1000 members in 53 s; commits sent across the whole build-up: 572 MB
///
/// The Welcome is CONSTANT at ~1.5 KB — it carries the joiner's own secrets, not the group.
/// What grows is the RATCHET TREE, sent alongside it, and that reaches only ~1.3 MB at 1000.
/// So the transport concern is real but an order of magnitude smaller than feared, and it
/// lands on a different artifact than expected.
///
/// THE NUMBER THAT SHOULD WORRY SOMEONE is the last one: 572 MB of commits to build a
/// 1000-member group one add at a time, because every add commits to everyone already
/// present. That is a fan-out problem, not a crypto one — batching adds into fewer commits
/// is the fix, and it is not attempted here.
///
/// No threshold is asserted. There is no agreed budget yet, and a number invented here
/// would be enforced as if it meant something.
///
/// `#[ignore]` — it builds N groups' worth of key material and is far too slow for CI.
///   cargo test --release --test soak -- --ignored group_scale --nocapture
///   VOIID_SOAK_MEMBERS=1000 cargo test --release --test soak -- --ignored group_scale --nocapture
#[test]
#[ignore]
fn group_scale_welcome_and_tree_size() {
    // Defaults to 200 rather than 1000: a useful curve without a coffee break. The point of
    // the env var is that the person who cares about 1000 can ask for it.
    let members = env_usize("VOIID_SOAK_MEMBERS", 200);

    let alice = GroupMember::new(b"alice").unwrap();
    let mut ag = alice.create_group().unwrap();

    // Sampled rather than recorded per-member: the interesting thing is the GROWTH, and
    // 1000 rows of output buries it.
    let sample_at: Vec<usize> = [1, 10, 50, 100, 250, 500, 750, 1000]
        .into_iter()
        .filter(|n| *n <= members)
        .collect();

    let started = Instant::now();
    let mut last_welcome = 0usize;
    let mut last_tree = 0usize;
    let mut commit_total = 0usize;

    for i in 0..members {
        let m = GroupMember::new(format!("m{i}").as_bytes()).unwrap();
        let kp = m.key_package().unwrap();

        let t0 = Instant::now();
        let out = ag.add_member(&alice, &kp).unwrap();
        let add_micros = t0.elapsed().as_micros();

        last_welcome = out.welcome.len();
        last_tree = out.ratchet_tree.len();
        commit_total += out.commit.len();

        let n = i + 1;
        if sample_at.contains(&n) {
            // Confirm the Welcome actually WORKS at this size, not merely that it was
            // produced — a Welcome that cannot be joined is not a smaller problem.
            let joined = m.join_group(&out.welcome, &out.ratchet_tree);
            assert!(joined.is_ok(), "member {n} could not join from its Welcome");

            println!(
                "  n={n:<5} welcome={:>9} B  ratchet_tree={:>9} B  commit={:>7} B  add={add_micros:>8} us",
                last_welcome, last_tree, out.commit.len()
            );
        }
    }

    println!(
        "\n  {} members in {:?}\n  final welcome {:.2} MB, ratchet tree {:.2} MB, commits sent {:.2} MB total",
        members,
        started.elapsed(),
        last_welcome as f64 / 1_048_576.0,
        last_tree as f64 / 1_048_576.0,
        commit_total as f64 / 1_048_576.0,
    );
    assert_eq!(ag.member_count() as usize, members + 1);
}
