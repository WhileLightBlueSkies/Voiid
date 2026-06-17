//! Randomized robustness tests — a lightweight stand-in for the cargo-fuzz
//! targets that runs under plain `cargo test`. Hammers the attacker-facing
//! decrypt entry points with thousands of random and mutated inputs and asserts
//! they only ever return Err (never panic / hang). The `fuzz/` crate provides
//! deeper libFuzzer coverage when run with `cargo fuzz`.

use rand::{Rng, RngCore, SeedableRng};
use rand::rngs::StdRng;
use voiid_e2e_core::{api, GroupMember, MediaKey, WireMessage};

/// Deterministic RNG so failures reproduce. Seed is fixed.
fn rng() -> StdRng {
    StdRng::seed_from_u64(0x0560_1DEA_DBEE_F001)
}

/// Session::decrypt never panics on random WireMessage bodies.
#[test]
fn session_decrypt_survives_garbage() {
    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let ab = api::publish_bundle(&mut alice, 1);
    let bob_bundle = api::publish_bundle(&mut bob, 1);
    let otk = bob_bundle.one_time_keys.first().unwrap();
    let mut alice_session = api::start_session(&alice, &bob_bundle.identity_key, otk).unwrap();
    let first = api::encrypt(&mut alice_session, b"seed").unwrap();
    let (mut bob_session, _) = api::accept_session(&mut bob, &ab.identity_key, &first).unwrap();

    let mut r = rng();
    for _ in 0..5000 {
        let len = r.gen_range(0..256);
        let mut buf = vec![0u8; len];
        r.fill_bytes(&mut buf);
        // Random body: sometimes valid base64-ish, sometimes raw.
        let body = if r.gen_bool(0.5) {
            vodozemac::base64_encode(&buf)
        } else {
            String::from_utf8_lossy(&buf).into_owned()
        };
        let wire = WireMessage {
            msg_type: r.gen(),
            body,
        };
        // The only requirement: it returns (no panic). Almost always Err.
        let _ = api::decrypt(&mut bob_session, &wire);
    }
}

/// accept_session never panics on random identity keys + message bodies.
#[test]
fn accept_session_survives_garbage() {
    let mut r = rng();
    for _ in 0..3000 {
        let mut bob = api::create_identity();
        let _ = api::publish_bundle(&mut bob, 1);

        let mut idbuf = vec![0u8; r.gen_range(0..64)];
        r.fill_bytes(&mut idbuf);
        let mut bodybuf = vec![0u8; r.gen_range(0..200)];
        r.fill_bytes(&mut bodybuf);

        let wire = WireMessage {
            msg_type: r.gen_range(0..3),
            body: vodozemac::base64_encode(&bodybuf),
        };
        let id = vodozemac::base64_encode(&idbuf);
        let _ = api::accept_session(&mut bob, &id, &wire);
    }
}

/// GroupSession::decrypt never panics on random MLS message bytes.
#[test]
fn group_decrypt_survives_garbage() {
    let alice = GroupMember::new(b"alice").unwrap();
    let mut group = alice.create_group().unwrap();

    let mut r = rng();
    for _ in 0..2000 {
        let len = r.gen_range(0..512);
        let mut buf = vec![0u8; len];
        r.fill_bytes(&mut buf);
        let _ = group.decrypt(&alice, &buf);
    }
}

/// decrypt_media never panics on random key/nonce/blob combinations.
#[test]
fn media_decrypt_survives_garbage() {
    let mut r = rng();
    for _ in 0..5000 {
        let mut kb = vec![0u8; r.gen_range(0..40)];
        r.fill_bytes(&mut kb);
        let mut nb = vec![0u8; r.gen_range(0..20)];
        r.fill_bytes(&mut nb);
        let mut blob = vec![0u8; r.gen_range(0..128)];
        r.fill_bytes(&mut blob);

        let mk = MediaKey {
            key: vodozemac::base64_encode(&kb),
            nonce: vodozemac::base64_encode(&nb),
            ciphertext_sha256: vodozemac::base64_encode(&blob),
        };
        let _ = api::decrypt_media(&mk, &blob);
    }
}

/// Safety-number generation never panics on arbitrary byte inputs.
#[test]
fn safety_number_survives_garbage() {
    // Fewer iterations: each safety_number does 2x5200 SHA-512 rounds.
    let mut r = rng();
    for _ in 0..100 {
        let mut a = vec![0u8; r.gen_range(0..64)];
        let mut b = vec![0u8; r.gen_range(0..64)];
        r.fill_bytes(&mut a);
        r.fill_bytes(&mut b);
        let fa = String::from_utf8_lossy(&a).into_owned();
        let fb = String::from_utf8_lossy(&b).into_owned();
        let n = api::safety_number(&a, &fa, &b, &fb);
        // Output is always the fixed 12-group format.
        assert_eq!(n.split(' ').count(), 12);
    }
}
