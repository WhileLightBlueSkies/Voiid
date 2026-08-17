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
    assert_eq!(
        alice_secret, bob_secret,
        "both sides derive the same PQ secret"
    );
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

// ---------------------------------------------------------------------------
// Persistence.
//
// A PQ prekey that cannot survive an app restart is unusable. The sender
// encapsulates to the PUBLISHED public half and its ciphertext may arrive minutes
// or days later; if the private half died with the process, the recipient can
// never decapsulate. That is not a degraded session — it is a shared secret only
// one side can compute, and no retry recovers it.
// ---------------------------------------------------------------------------

/// THE PROPERTY PERSISTENCE EXISTS FOR: a secret encapsulated to the published key
/// is still recoverable after a restart.
#[test]
fn a_restored_prekey_decapsulates_what_the_original_published_key_sealed() {
    let original = api::generate_pq_prekey();
    let published = original.public_key_b64();
    let seed = original.to_seed_b64();

    // The sender only ever sees the published public half.
    let (ciphertext, sender_secret) = api::pq_encapsulate(&published).unwrap();

    // App restart: the original is gone, only the seed was on disk.
    drop(original);
    let restored = voiid_e2e_core::PqPrekey::from_seed_b64(&seed).expect("restore prekey");

    let recipient_secret = restored.decapsulate(&ciphertext).expect("decapsulate");
    assert_eq!(
        sender_secret, recipient_secret,
        "both sides must derive the SAME secret across a restart"
    );
}

/// The restored public key must be byte-identical, or a bundle already published
/// advertises a key whose private half no longer matches — unrecoverable for every
/// sender who fetched it.
#[test]
fn restoring_reproduces_the_same_public_key() {
    let original = api::generate_pq_prekey();
    let published = original.public_key_b64();
    let restored = voiid_e2e_core::PqPrekey::from_seed_b64(&original.to_seed_b64()).unwrap();
    assert_eq!(published, restored.public_key_b64());
}

/// Two prekeys must not collide. If generation were deterministic, every device would
/// publish the same PQ prekey and the KEM would contribute nothing.
#[test]
fn two_generated_prekeys_differ() {
    let a = api::generate_pq_prekey();
    let b = api::generate_pq_prekey();
    assert_ne!(a.public_key_b64(), b.public_key_b64());
    assert_ne!(a.to_seed_b64(), b.to_seed_b64());
}

/// A malformed seed must fail closed rather than panic. A hostile or corrupted store
/// must not be able to take the app down.
#[test]
fn a_malformed_seed_fails_closed() {
    assert!(voiid_e2e_core::PqPrekey::from_seed_b64("!!! not base64 !!!").is_err());
    assert!(voiid_e2e_core::PqPrekey::from_seed_b64("").is_err());
    // Valid base64, WRONG LENGTH — 32 bytes where the seed is 64. This is the case a
    // length check has to catch: it decodes cleanly and would otherwise reach the KEM.
    let short = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=";
    assert!(voiid_e2e_core::PqPrekey::from_seed_b64(short).is_err());
}
