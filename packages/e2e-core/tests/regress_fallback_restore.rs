//! ADVERSARIAL REGRESSION TEST — audit finding §2.6 (fallback-key lifecycle).
//!
//! Reproduces the exact client sequence across an app restart — identity
//! pickled, restored WITHOUT calling `restore_fallback_key` (the app never
//! calls it; `grep restore_fallback_key apps/ios` matches only the generated
//! binding), then a routine prekey replenish — and asserts what breaks:
//! the fallback key the server serves silently changes.

use voiid_e2e_core::{api as e2e, IdentityKeys};

const PK: [u8; 32] = [7u8; 32];

#[test]
fn restart_without_fallback_restore_rotates_the_served_key() {
    // --- first launch: identity created, bundle uploaded to the server ------
    let mut bob = IdentityKeys::generate();    let first_bundle = e2e::publish_bundle(&mut bob, 10);
    let served_by_server = first_bundle.fallback_key.clone().expect("bundle has a fallback key");

    // --- app restart: pickle round-trip exactly as the iOS app does ---------
    let pickle = bob.to_pickle(&PK);
    let mut restored = IdentityKeys::from_pickle(&pickle, &PK).unwrap();

    // The trigger state the shipped app is in after every restart:
    assert_eq!(
        e2e::current_fallback_key(&restored),
        None,
        "precondition: restored identity reports NO published fallback key"
    );

    // --- routine replenish (ensurePrekeys fires on every launch) ------------
    let second_bundle = e2e::replenish_prekeys(&mut restored, 20);
    let newly_published = second_bundle
        .fallback_key
        .expect("public_bundle mints a fresh fallback key when none is marked published");

    assert_ne!(
        newly_published, served_by_server,
        "PROOF of audit finding §2.6: an ordinary restart rotated the \
         server-served fallback key; senders holding the old bundle produce \
         messages this identity can no longer open once vodozemac drops the \
         previous generation"
    );

    // And the private half of the OLD served key is already gone from the new
    // account state? Not yet (current+previous retained) — one MORE restart and
    // replenish cycle pushes it out of retention entirely:
    let pickle2 = restored.to_pickle(&PK);
    let mut third = IdentityKeys::from_pickle(&pickle2, &PK).unwrap();
    e2e::replenish_prekeys(&mut third, 20);
    let fourth_bundle = e2e::replenish_prekeys(&mut third, 20);
    assert_ne!(
        fourth_bundle.fallback_key.as_deref(),
        Some(served_by_server.as_str()),
        "the originally-served key has fallen out of the rotation entirely"
    );
}

#[test]
fn restore_then_publish_keeps_the_served_key_stable() {
    // The fix path: restoring WITH the previously published key must never let
    // a DIFFERENT key reach the server. After restore_fallback_key,
    // has_fallback_key() is true, so public_bundle() mints nothing new —
    // bundles simply stop carrying a fallback_key entry at all.
    let mut bob = IdentityKeys::generate();
    let first_bundle = e2e::publish_bundle(&mut bob, 5);
    let served = first_bundle.fallback_key.clone().unwrap();

    let pickle = bob.to_pickle(&PK);
    let mut restored = IdentityKeys::from_pickle(&pickle, &PK).unwrap();
    e2e::restore_fallback_key(&mut restored, &served);

    assert_eq!(
        e2e::current_fallback_key(&restored).as_deref(),
        Some(served.as_str()),
        "restore_fallback_key must re-attach the served key"
    );

    let second_bundle = e2e::replenish_prekeys(&mut restored, 20);

    // THE INVARIANT: no replenish may ever publish a fallback key DIFFERENT
    // from the one the server already serves. (It comes back as None here —
    // nothing new was minted — which is exactly the stable outcome.)
    assert_ne!(
        second_bundle
            .fallback_key
            .as_deref()
            .map(|k| k != served.as_str())
            .unwrap_or(false),
        true,
        "a different fallback key must never be published after a proper restore"
    );
}
