//! Account recovery — protect the master backup secret so a user can restore it
//! on a new device.
//!
//! The `master secret` is a 32-byte root that later encrypts the user's backups.
//! It never leaves the device in the clear. This module offers two independent
//! ways to recover it:
//!
//! - **Recovery phrase (BIP39):** the secret is rendered as a 24-word English
//!   mnemonic the user writes down. `phrase_to_master_secret` validates the
//!   BIP39 checksum, so a mistyped word is rejected rather than silently
//!   producing the wrong secret.
//! - **PIN wrap:** the secret is encrypted under a key stretched from the user's
//!   PIN with Argon2id, then sealed with AES-256-GCM. The resulting
//!   [`PinWrappedSecret`] is OPAQUE to the server — it holds only a random salt,
//!   a random nonce, and ciphertext, and can be stored server-side so a PIN
//!   alone recovers the secret on a new device. The server never sees the PIN or
//!   the secret, and a wrong PIN fails the GCM tag check (it cannot yield a
//!   wrong-but-plausible secret).
//!
//! ## SECURITY — this module is security-sensitive and PENDING EXTERNAL REVIEW.
//!
//! It composes only standard, widely-reviewed primitives — Argon2id (RFC 9106)
//! for the PIN KDF, AES-256-GCM (`aes-gcm`) for the wrap, and BIP39 for the
//! phrase — with NO bespoke construction. This mirrors the caution around the
//! gated combiner in `src/pqxdh.rs`: the same "no home-grown crypto" rule
//! applies here. Any change to the KDF parameters, the wrap layout, or the
//! phrase encoding MUST go through cryptographic review before shipping. Do not
//! substitute custom primitives.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use argon2::{Algorithm, Argon2, Params, Version};
use bip39::Mnemonic;
use rand::RngCore;
use serde::{Deserialize, Serialize};

use crate::error::E2eError;

/// Length of the master backup secret, in bytes (256 bits -> a 24-word phrase).
pub const MASTER_SECRET_LEN: usize = 32;

/// Argon2id salt length, in bytes. A fresh random salt is drawn per wrap.
const SALT_LEN: usize = 16;
/// AES-256-GCM nonce length, in bytes. A fresh random nonce is drawn per wrap.
const NONCE_LEN: usize = 12;

// Argon2id parameters. These match the OWASP-recommended "second option"
// (m = 19 MiB, t = 2, p = 1) and the `argon2` crate defaults. The derived key is
// 32 bytes — the AES-256 key. Changing any of these is a review-gated change and
// also breaks existing wraps, so it would need a versioned migration.
/// Memory cost, in kibibytes (19 MiB).
const ARGON2_M_COST_KIB: u32 = 19 * 1024;
/// Time cost (iterations).
const ARGON2_T_COST: u32 = 2;
/// Parallelism (lanes).
const ARGON2_P_COST: u32 = 1;

/// Current wrap format version, stamped into every [`PinWrappedSecret`] by
/// [`wrap_with_pin`] and checked by [`unwrap_with_pin`]. The Argon2id parameters
/// above are hardcoded constants, so if they ever change, previously-stored
/// wraps must be unwrapped with the parameters they were created with. This
/// version tag lets `unwrap_with_pin` dispatch to the right params (instead of
/// locking users out of recovery). Bump it and branch on it here whenever the
/// KDF params or wrap layout change.
const WRAP_VERSION: u8 = 1;

/// A master secret sealed under a PIN, safe to hand to the server for storage.
///
/// Every field is opaque: `salt`/`nonce` are random public parameters and
/// `ciphertext` is the AES-256-GCM sealing of the 32-byte secret (with its
/// authentication tag appended). All three are base64, matching how the other
/// value types in this crate cross the FFI boundary. Holding this reveals
/// nothing about the secret or the PIN without brute-forcing the Argon2id KDF.
#[derive(Clone, Serialize, Deserialize)]
pub struct PinWrappedSecret {
    /// Wrap format version (see [`WRAP_VERSION`]). Identifies which Argon2id
    /// params / layout produced this wrap, so `unwrap_with_pin` can stay
    /// backward-compatible if the params ever change.
    pub version: u8,
    /// Random Argon2id salt (base64, 16 bytes).
    pub salt: String,
    /// Random AES-256-GCM nonce (base64, 12 bytes).
    pub nonce: String,
    /// AES-256-GCM ciphertext of the master secret + tag (base64).
    pub ciphertext: String,
}

/// Generate a fresh, cryptographically-random master backup secret.
///
/// Uses the same system CSPRNG (`rand::thread_rng`) the rest of the crate uses
/// for key material.
pub fn generate_master_secret() -> [u8; MASTER_SECRET_LEN] {
    let mut secret = [0u8; MASTER_SECRET_LEN];
    rand::thread_rng().fill_bytes(&mut secret);
    secret
}

/// Render a master secret as a 24-word BIP39 (English) recovery phrase.
///
/// The 32-byte secret is used directly as BIP39 entropy, so the same secret
/// always yields the same phrase and the phrase carries a checksum.
pub fn master_secret_to_phrase(secret: &[u8; MASTER_SECRET_LEN]) -> String {
    // `from_entropy` only fails on an invalid entropy length; 32 bytes is always
    // valid (256 bits -> 24 words), so this cannot fail.
    Mnemonic::from_entropy(secret)
        .expect("32 bytes is always valid BIP39 entropy")
        .to_string()
}

/// Recover a master secret from a BIP39 recovery phrase.
///
/// Validates the mnemonic (known words + BIP39 checksum); a mistyped or
/// otherwise corrupt phrase returns [`E2eError::InvalidKey`] instead of a wrong
/// secret. Only 24-word (256-bit) phrases are accepted, since that is what
/// [`master_secret_to_phrase`] produces.
pub fn phrase_to_master_secret(phrase: &str) -> Result<[u8; MASTER_SECRET_LEN], E2eError> {
    let mnemonic = Mnemonic::parse(phrase.trim()).map_err(|_| E2eError::InvalidKey)?;

    let (entropy, len) = mnemonic.to_entropy_array();
    if len != MASTER_SECRET_LEN {
        // Wrong word count (e.g. a valid 12-word phrase) — not one of ours.
        return Err(E2eError::InvalidKey);
    }

    let mut secret = [0u8; MASTER_SECRET_LEN];
    secret.copy_from_slice(&entropy[..MASTER_SECRET_LEN]);
    Ok(secret)
}

/// Seal a master secret under a PIN, returning an opaque [`PinWrappedSecret`].
///
/// Draws a fresh random salt and nonce, stretches the PIN with Argon2id into a
/// 32-byte key, and encrypts the secret with AES-256-GCM under that key.
pub fn wrap_with_pin(
    secret: &[u8; MASTER_SECRET_LEN],
    pin: &str,
) -> Result<PinWrappedSecret, E2eError> {
    let mut salt = [0u8; SALT_LEN];
    let mut nonce_bytes = [0u8; NONCE_LEN];
    let mut rng = rand::thread_rng();
    rng.fill_bytes(&mut salt);
    rng.fill_bytes(&mut nonce_bytes);

    let key = derive_pin_key(pin, &salt)?;

    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, secret.as_slice())
        .map_err(|_| E2eError::Serialization)?;

    Ok(PinWrappedSecret {
        version: WRAP_VERSION,
        salt: vodozemac::base64_encode(salt),
        nonce: vodozemac::base64_encode(nonce_bytes),
        ciphertext: vodozemac::base64_encode(ciphertext),
    })
}

/// Recover the master secret from a [`PinWrappedSecret`] using the PIN.
///
/// Rejects an unknown wrap `version` with [`E2eError::InvalidKey`], then
/// re-derives the Argon2id key from the stored salt and the PIN and opens the
/// AES-256-GCM ciphertext. A wrong PIN (or tampered salt/nonce/ciphertext) fails
/// the GCM authentication tag and returns [`E2eError::DecryptionFailed`] — never
/// a wrong secret, never a panic.
pub fn unwrap_with_pin(
    wrapped: &PinWrappedSecret,
    pin: &str,
) -> Result<[u8; MASTER_SECRET_LEN], E2eError> {
    // Reject wraps we don't know how to interpret. Today only version 1 exists;
    // when the KDF params change, add the old params under their version here
    // rather than failing.
    if wrapped.version != WRAP_VERSION {
        return Err(E2eError::InvalidKey);
    }

    let salt = vodozemac::base64_decode(&wrapped.salt).map_err(|_| E2eError::InvalidKey)?;
    let nonce_bytes = vodozemac::base64_decode(&wrapped.nonce).map_err(|_| E2eError::InvalidKey)?;
    let ciphertext =
        vodozemac::base64_decode(&wrapped.ciphertext).map_err(|_| E2eError::InvalidKey)?;
    if salt.len() != SALT_LEN || nonce_bytes.len() != NONCE_LEN {
        return Err(E2eError::InvalidKey);
    }

    let key = derive_pin_key(pin, &salt)?;

    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
    let nonce = Nonce::from_slice(&nonce_bytes);
    let plaintext = cipher
        .decrypt(nonce, ciphertext.as_slice())
        .map_err(|_| E2eError::DecryptionFailed)?;

    // A correct GCM tag guarantees this is our 32-byte secret; anything else is
    // treated as malformed rather than returned.
    plaintext
        .as_slice()
        .try_into()
        .map_err(|_| E2eError::InvalidKey)
}

/// Stretch a PIN into a 32-byte AES key with Argon2id over the given salt.
fn derive_pin_key(pin: &str, salt: &[u8]) -> Result<[u8; 32], E2eError> {
    let params = Params::new(
        ARGON2_M_COST_KIB,
        ARGON2_T_COST,
        ARGON2_P_COST,
        Some(32), // 32-byte output = the AES-256 key.
    )
    .map_err(|_| E2eError::Serialization)?;

    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut key = [0u8; 32];
    argon2
        .hash_password_into(pin.as_bytes(), salt, &mut key)
        .map_err(|_| E2eError::Serialization)?;
    Ok(key)
}
