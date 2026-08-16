//! Account-recovery tests: PIN wrap/unwrap and BIP39 recovery phrase.
//!
//! These are the proof that the master backup secret survives a round-trip
//! through both recovery paths, and that the failure paths (wrong PIN, tampered
//! wrap, corrupt phrase) error cleanly instead of panicking or leaking a
//! wrong-but-plausible secret.

use voiid_e2e_core::api;
use voiid_e2e_core::PinWrappedSecret;

/// Flip the first base64 character of `s` to a different valid one, so the
/// decoded bytes change (breaking a GCM tag) while staying valid base64.
fn tamper_b64(s: &str) -> String {
    let mut chars: Vec<char> = s.chars().collect();
    let first = chars[0];
    chars[0] = if first == 'A' { 'B' } else { 'A' };
    chars.into_iter().collect()
}

/// A PIN-wrapped secret round-trips back to the exact same secret.
#[test]
fn pin_wrap_roundtrip() {
    let secret = api::generate_master_secret();
    let wrapped = api::wrap_master_secret_with_pin(&secret, "1234").expect("wrap");

    let recovered = api::unwrap_master_secret_with_pin(&wrapped, "1234").expect("unwrap");
    assert_eq!(recovered, secret, "unwrap must return the original secret");
}

/// The wrong PIN fails with an error — no panic, and no wrong secret returned.
#[test]
fn wrong_pin_fails() {
    let secret = api::generate_master_secret();
    let wrapped = api::wrap_master_secret_with_pin(&secret, "correct-horse").expect("wrap");

    let result = api::unwrap_master_secret_with_pin(&wrapped, "wrong-pin");
    assert!(result.is_err(), "a wrong PIN must not unwrap the secret");
}

/// Each wrap of the same secret uses a fresh random salt and nonce, so two
/// wraps of the same secret differ — yet both unwrap to the same secret.
#[test]
fn each_wrap_is_randomized() {
    let secret = api::generate_master_secret();
    let a = api::wrap_master_secret_with_pin(&secret, "1234").expect("wrap a");
    let b = api::wrap_master_secret_with_pin(&secret, "1234").expect("wrap b");

    assert_ne!(a.salt, b.salt, "salt must be random per wrap");
    assert_ne!(a.nonce, b.nonce, "nonce must be random per wrap");
    assert_ne!(
        a.ciphertext, b.ciphertext,
        "ciphertext must differ per wrap"
    );

    assert_eq!(
        api::unwrap_master_secret_with_pin(&a, "1234").unwrap(),
        secret
    );
    assert_eq!(
        api::unwrap_master_secret_with_pin(&b, "1234").unwrap(),
        secret
    );
}

/// Tampering with the ciphertext is caught by AES-GCM authentication.
#[test]
fn tampered_ciphertext_fails() {
    let secret = api::generate_master_secret();
    let wrapped = api::wrap_master_secret_with_pin(&secret, "1234").expect("wrap");

    let tampered = PinWrappedSecret {
        ciphertext: tamper_b64(&wrapped.ciphertext),
        ..wrapped.clone()
    };
    assert!(
        api::unwrap_master_secret_with_pin(&tampered, "1234").is_err(),
        "a tampered ciphertext must fail the GCM auth check"
    );
}

/// Tampering with the nonce is caught by AES-GCM authentication.
#[test]
fn tampered_nonce_fails() {
    let secret = api::generate_master_secret();
    let wrapped = api::wrap_master_secret_with_pin(&secret, "1234").expect("wrap");

    let tampered = PinWrappedSecret {
        nonce: tamper_b64(&wrapped.nonce),
        ..wrapped.clone()
    };
    assert!(
        api::unwrap_master_secret_with_pin(&tampered, "1234").is_err(),
        "a tampered nonce must fail the GCM auth check"
    );
}

/// Tampering with the salt changes the derived key, so the GCM tag fails too.
#[test]
fn tampered_salt_fails() {
    let secret = api::generate_master_secret();
    let wrapped = api::wrap_master_secret_with_pin(&secret, "1234").expect("wrap");

    let tampered = PinWrappedSecret {
        salt: tamper_b64(&wrapped.salt),
        ..wrapped.clone()
    };
    assert!(
        api::unwrap_master_secret_with_pin(&tampered, "1234").is_err(),
        "a tampered salt derives a different key and must fail to unwrap"
    );
}

/// A garbage (non-base64) wrapped field is rejected cleanly, not panicked on.
#[test]
fn garbage_wrap_fields_error() {
    let secret = api::generate_master_secret();
    let wrapped = api::wrap_master_secret_with_pin(&secret, "1234").expect("wrap");

    let garbage = PinWrappedSecret {
        salt: "not base64 !!!".to_string(),
        ..wrapped
    };
    assert!(api::unwrap_master_secret_with_pin(&garbage, "1234").is_err());
}

/// A wrap with an unknown format version is rejected cleanly (forward-compat:
/// lets a future `unwrap` dispatch old params instead of locking users out).
#[test]
fn unknown_version_rejected() {
    let secret = api::generate_master_secret();
    let wrapped = api::wrap_master_secret_with_pin(&secret, "1234").expect("wrap");
    assert_eq!(wrapped.version, 1, "current wraps are version 1");

    // Same valid material, but tagged with a version this build doesn't know.
    let future = PinWrappedSecret {
        version: 2,
        ..wrapped
    };
    assert!(
        api::unwrap_master_secret_with_pin(&future, "1234").is_err(),
        "an unknown wrap version must error, not attempt to unwrap"
    );
}

/// A secret round-trips through its 24-word BIP39 recovery phrase.
#[test]
fn phrase_roundtrip() {
    let secret = api::generate_master_secret();

    let phrase = api::master_secret_to_phrase(&secret);
    assert_eq!(
        phrase.split_whitespace().count(),
        24,
        "a 32-byte secret encodes to a 24-word phrase"
    );

    let recovered = api::phrase_to_master_secret(&phrase).expect("parse phrase");
    assert_eq!(
        recovered, secret,
        "phrase must decode to the original secret"
    );
}

/// The phrase is deterministic: the same secret always yields the same phrase.
#[test]
fn phrase_is_deterministic() {
    let secret = api::generate_master_secret();
    assert_eq!(
        api::master_secret_to_phrase(&secret),
        api::master_secret_to_phrase(&secret),
    );
}

/// A phrase built from valid BIP39 words but with a wrong checksum errors
/// cleanly. 24x "abandon" is all-valid-words but an invalid checksum (the real
/// all-zero-entropy phrase ends in "art"), so this deterministically exercises
/// the checksum validation without a 1-in-256 collision flake.
#[test]
fn bad_checksum_phrase_errors() {
    let bad_checksum = "abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon";
    assert_eq!(bad_checksum.split_whitespace().count(), 24);
    assert!(
        api::phrase_to_master_secret(bad_checksum).is_err(),
        "a bad-checksum phrase must error, not return a wrong secret"
    );
}

/// A non-word / gibberish phrase errors cleanly (no panic).
#[test]
fn gibberish_phrase_errors() {
    assert!(api::phrase_to_master_secret("this is definitely not a valid mnemonic").is_err());
    assert!(api::phrase_to_master_secret("").is_err());
    assert!(api::phrase_to_master_secret("zzz zzz zzz").is_err());
}

/// A valid but wrong-length (12-word) phrase is rejected: it is not one of ours.
#[test]
fn wrong_length_phrase_rejected() {
    // A canonical valid 12-word BIP39 mnemonic (128-bit entropy).
    let twelve = "abandon abandon abandon abandon abandon abandon \
                  abandon abandon abandon abandon abandon about";
    assert!(
        api::phrase_to_master_secret(twelve).is_err(),
        "a 12-word phrase decodes to 16 bytes, not our 32-byte secret"
    );
}

/// A newly generated secret is 32 bytes and not all-zero (sanity on the CSPRNG).
#[test]
fn generated_secret_is_nonzero_32_bytes() {
    let secret = api::generate_master_secret();
    assert_eq!(secret.len(), 32);
    assert_ne!(secret, [0u8; 32], "a random secret must not be all zeros");
    assert_ne!(
        api::generate_master_secret(),
        api::generate_master_secret(),
        "two generated secrets must differ"
    );
}

// ---- Backup-blob encryption (encrypt_backup / decrypt_backup) ----

/// A backup blob round-trips back to the exact same plaintext under the same secret.
#[test]
fn backup_roundtrip() {
    let secret = api::generate_master_secret();
    let plaintext = b"{\"conversations\":[{\"id\":\"c1\",\"messages\":[\"hi\"]}]}";
    let blob = api::encrypt_backup(&secret, plaintext).expect("encrypt");
    let out = api::decrypt_backup(&secret, &blob).expect("decrypt");
    assert_eq!(out, plaintext, "decrypt must return the original plaintext");
}

/// The sealed blob is not the plaintext (it is actually encrypted) and carries the
/// version byte + a 12-byte nonce ahead of the ciphertext.
#[test]
fn backup_blob_is_encrypted_and_framed() {
    let secret = api::generate_master_secret();
    let plaintext = b"top secret history";
    let blob = api::encrypt_backup(&secret, plaintext).expect("encrypt");
    assert_eq!(blob[0], 1, "first byte is the blob version");
    assert!(
        blob.len() > 1 + 12 + plaintext.len(),
        "version+nonce+ciphertext+tag"
    );
    assert!(
        !blob.windows(plaintext.len()).any(|w| w == plaintext),
        "plaintext must not appear in the sealed blob"
    );
}

/// Each encryption uses a fresh nonce, so two seals of the same plaintext differ.
#[test]
fn backup_each_seal_is_randomized() {
    let secret = api::generate_master_secret();
    let a = api::encrypt_backup(&secret, b"same").expect("a");
    let b = api::encrypt_backup(&secret, b"same").expect("b");
    assert_ne!(a, b, "fresh nonce per seal must produce distinct blobs");
}

/// A different master secret cannot open the blob (GCM auth fails).
#[test]
fn backup_wrong_secret_fails() {
    let secret = api::generate_master_secret();
    let other = api::generate_master_secret();
    let blob = api::encrypt_backup(&secret, b"history").expect("encrypt");
    assert!(
        api::decrypt_backup(&other, &blob).is_err(),
        "a wrong secret must fail the GCM tag, not return wrong plaintext"
    );
}

/// A tampered blob (flipped ciphertext byte) fails instead of returning plaintext.
#[test]
fn backup_tampered_blob_fails() {
    let secret = api::generate_master_secret();
    let mut blob = api::encrypt_backup(&secret, b"history").expect("encrypt");
    let last = blob.len() - 1;
    blob[last] ^= 0xFF;
    assert!(
        api::decrypt_backup(&secret, &blob).is_err(),
        "tamper must fail"
    );
}

/// An unknown version byte or a truncated blob is rejected cleanly.
#[test]
fn backup_bad_frame_rejected() {
    let secret = api::generate_master_secret();
    assert!(api::decrypt_backup(&secret, &[]).is_err(), "empty blob");
    assert!(
        api::decrypt_backup(&secret, &[9, 0, 0]).is_err(),
        "unknown version"
    );
    let short = vec![1u8; 8]; // version + partial nonce, no ciphertext
    assert!(
        api::decrypt_backup(&secret, &short).is_err(),
        "truncated blob"
    );
}

/// A backup restores across "devices": a secret recovered from its phrase opens a
/// blob sealed under the original secret (the real cross-device restore path).
#[test]
fn backup_restores_via_recovery_phrase() {
    let secret = api::generate_master_secret();
    let blob = api::encrypt_backup(&secret, b"cross-device history").expect("encrypt");
    let phrase = api::master_secret_to_phrase(&secret);
    let recovered = api::phrase_to_master_secret(&phrase).expect("recover");
    let out = api::decrypt_backup(&recovered, &blob).expect("decrypt on new device");
    assert_eq!(out, b"cross-device history");
}
