//! Post-quantum 1:1 prekey tests (GATED scaffold).
//!
//! These verify the ML-KEM-768 prekey round-trip: a sender encapsulating to a
//! peer's published PQ prekey derives the SAME shared secret the peer derives by
//! decapsulating. This is the building block for PQXDH; mixing it into the live
//! handshake is gated behind external review (see src/pqxdh.rs).

#![cfg(feature = "pq-1to1-prekeys")]

use voiid_e2e_core::api;

/// Encapsulate → decapsulate yields matching 32-byte shared secrets.
#[test]
fn ml_kem_prekey_roundtrip() {
    // Bob publishes a PQ prekey.
    let bob_prekey = api::generate_pq_prekey();
    let bob_pub = bob_prekey.public_key_b64();

    // Alice encapsulates to it.
    let (ciphertext, alice_secret) = api::pq_encapsulate(&bob_pub).unwrap();
    assert_eq!(alice_secret.len(), 32, "ML-KEM shared secret is 32 bytes");

    // Bob decapsulates and recovers the same secret.
    let bob_secret = bob_prekey.decapsulate(&ciphertext).unwrap();
    assert_eq!(alice_secret, bob_secret, "both sides derive the same PQ secret");
}

/// A garbage / wrong-length public key is rejected.
#[test]
fn bad_public_key_rejected() {
    assert!(api::pq_encapsulate("not-a-real-key").is_err());
    assert!(api::pq_encapsulate("AAAA").is_err());
}

/// A garbage ciphertext is rejected by decapsulation.
#[test]
fn bad_ciphertext_rejected() {
    let prekey = api::generate_pq_prekey();
    assert!(prekey.decapsulate("AAAA").is_err());
    assert!(prekey.decapsulate("not-base64!!").is_err());
}

/// Two independent prekeys produce different public keys (fresh randomness).
#[test]
fn distinct_prekeys_distinct_keys() {
    let a = api::generate_pq_prekey().public_key_b64();
    let b = api::generate_pq_prekey().public_key_b64();
    assert_ne!(a, b);
}
