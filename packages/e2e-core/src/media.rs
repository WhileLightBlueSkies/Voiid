//! Phase 2 — media (images / video / audio files).
//!
//! Large blobs are NOT pushed through the double ratchet. Instead:
//!   1. Generate a random AES-256-GCM key per attachment.
//!   2. Encrypt the file locally -> upload the CIPHERTEXT to storage. The
//!      backend never sees plaintext.
//!   3. Send the small [`MediaKey`] (key + nonce + hash) as a normal Phase-1
//!      E2EE message over the ratchet.
//!   4. The recipient fetches the blob, verifies the hash, and decrypts.
//!
//! This is the same approach Signal/WhatsApp use for attachments.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::E2eError;

/// The small secret that travels over the ratchet so the recipient can fetch
/// and decrypt the blob. Everything here is sent inside an E2EE message — it is
/// NEVER given to the backend in the clear.
#[derive(Clone, Serialize, Deserialize)]
pub struct MediaKey {
    /// AES-256 key (base64), 32 bytes.
    pub key: String,
    /// 96-bit GCM nonce (base64), 12 bytes.
    pub nonce: String,
    /// SHA-256 of the CIPHERTEXT (base64) — lets the recipient verify the blob
    /// it downloaded wasn't swapped or truncated before decrypting.
    pub ciphertext_sha256: String,
}

/// Result of encrypting a file: the opaque blob to upload, plus the [`MediaKey`]
/// to send over the ratchet.
pub struct EncryptedMedia {
    /// Upload this to blob storage. The backend sees only this.
    pub ciphertext: Vec<u8>,
    /// Send this over a Phase-1 E2EE message.
    pub media_key: MediaKey,
}

/// Encrypt an attachment. Generates a fresh random key + nonce every call —
/// keys are single-use per attachment.
pub fn encrypt_media(plaintext: &[u8]) -> Result<EncryptedMedia, E2eError> {
    let mut key_bytes = [0u8; 32];
    let mut rng = rand::thread_rng();
    rng.fill_bytes(&mut key_bytes);
    encrypt_media_with_key_bytes(&key_bytes, plaintext)
}

/// A long-lived key that encrypts a user's PROFILE PHOTO.
///
/// Avatars cannot use [`encrypt_media`]'s per-attachment key. A chat photo has one known
/// audience — the people in that conversation — so a fresh key can ride the ratchet with the
/// message. An avatar has NO fixed audience: it is shown to anyone who might contact you,
/// including someone who found your @username and has never had a session with you. There is
/// no single message to attach a key to.
///
/// So the key is per-USER and long-lived, wrapped to each contact over the ratchet as you talk
/// to them (the Signal "profile key" model). Rotating it re-encrypts the avatar and re-wraps to
/// every current contact, which is what makes revocation possible at all.
///
/// Returned base64, matching [`MediaKey::key`], so the same 32-byte format flows everywhere.
pub fn generate_profile_key() -> String {
    let mut key_bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut key_bytes);
    vodozemac::base64_encode(key_bytes)
}

/// Encrypt with a key the CALLER already holds, rather than minting a new one.
///
/// This is the primitive avatars need and [`encrypt_media`] cannot provide: that function
/// always generates a fresh key, which is correct for single-use attachments and useless for
/// anything long-lived.
///
/// A FRESH NONCE IS STILL GENERATED on every call, and that is not optional. AES-GCM catastro-
/// phically fails on nonce reuse under the same key — two messages sharing a (key, nonce) pair
/// leak the XOR of their plaintexts and allow forgery. Since a profile key is reused across
/// every re-upload, the nonce is the only thing keeping each encryption distinct.
///
/// `key_b64` must be a base64 32-byte key (see [`generate_profile_key`]).
pub fn encrypt_media_with_key(key_b64: &str, plaintext: &[u8]) -> Result<EncryptedMedia, E2eError> {
    let key_bytes = vodozemac::base64_decode(key_b64).map_err(|_| E2eError::InvalidKey)?;
    if key_bytes.len() != 32 {
        return Err(E2eError::InvalidKey);
    }
    encrypt_media_with_key_bytes(&key_bytes, plaintext)
}

/// Shared body for both public entry points, so the AEAD is written once.
fn encrypt_media_with_key_bytes(
    key_bytes: &[u8],
    plaintext: &[u8],
) -> Result<EncryptedMedia, E2eError> {
    let mut nonce_bytes = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);

    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key_bytes));
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|_| E2eError::Serialization)?;

    let ciphertext_sha256 = {
        let mut hasher = Sha256::new();
        hasher.update(&ciphertext);
        vodozemac::base64_encode(hasher.finalize())
    };

    Ok(EncryptedMedia {
        media_key: MediaKey {
            key: vodozemac::base64_encode(key_bytes),
            nonce: vodozemac::base64_encode(nonce_bytes),
            ciphertext_sha256,
        },
        ciphertext,
    })
}

/// Decrypt a downloaded blob using the [`MediaKey`] received over the ratchet.
/// Verifies the ciphertext hash before decrypting.
pub fn decrypt_media(media_key: &MediaKey, ciphertext: &[u8]) -> Result<Vec<u8>, E2eError> {
    // Verify integrity of the downloaded blob first.
    let expected =
        vodozemac::base64_decode(&media_key.ciphertext_sha256).map_err(|_| E2eError::InvalidKey)?;
    let actual = {
        let mut hasher = Sha256::new();
        hasher.update(ciphertext);
        hasher.finalize().to_vec()
    };
    if actual != expected {
        return Err(E2eError::DecryptionFailed);
    }

    let key_bytes = vodozemac::base64_decode(&media_key.key).map_err(|_| E2eError::InvalidKey)?;
    let nonce_bytes =
        vodozemac::base64_decode(&media_key.nonce).map_err(|_| E2eError::InvalidKey)?;
    if key_bytes.len() != 32 || nonce_bytes.len() != 12 {
        return Err(E2eError::InvalidKey);
    }

    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key_bytes));
    let nonce = Nonce::from_slice(&nonce_bytes);
    cipher
        .decrypt(nonce, ciphertext.as_ref())
        .map_err(|_| E2eError::DecryptionFailed)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The property avatars depend on: a key generated once can encrypt LATER, and the
    /// resulting blob decrypts with that same key. `encrypt_media` cannot do this — it mints a
    /// new key per call — which is precisely why this primitive exists.
    #[test]
    fn profile_key_round_trips_across_separate_encryptions() {
        let key = generate_profile_key();
        let first = encrypt_media_with_key(&key, b"avatar v1").unwrap();
        let second = encrypt_media_with_key(&key, b"avatar v2").unwrap();

        assert_eq!(
            decrypt_media(&first.media_key, &first.ciphertext).unwrap(),
            b"avatar v1"
        );
        assert_eq!(
            decrypt_media(&second.media_key, &second.ciphertext).unwrap(),
            b"avatar v2"
        );

        // Same key both times — that is the whole point of a long-lived profile key.
        assert_eq!(first.media_key.key, second.media_key.key);
        assert_eq!(first.media_key.key, key);
    }

    /// NONCE REUSE IS THE ONE FATAL MISTAKE HERE. A profile key is reused on every re-upload,
    /// so if the nonce were fixed, two avatars under one key would leak the XOR of their
    /// plaintexts and allow forgery. This asserts a fresh nonce per call.
    #[test]
    fn each_encryption_uses_a_fresh_nonce() {
        let key = generate_profile_key();
        let a = encrypt_media_with_key(&key, b"same bytes").unwrap();
        let b = encrypt_media_with_key(&key, b"same bytes").unwrap();

        assert_ne!(
            a.media_key.nonce, b.media_key.nonce,
            "nonce MUST differ per encryption"
        );
        // Identical plaintext under one key must still produce different ciphertext.
        assert_ne!(a.ciphertext, b.ciphertext);
    }

    /// A wrong key must fail closed, not return garbage bytes.
    #[test]
    fn wrong_key_fails_to_decrypt() {
        let key = generate_profile_key();
        let other = generate_profile_key();
        let enc = encrypt_media_with_key(&key, b"secret").unwrap();

        let mut forged = enc.media_key.clone();
        forged.key = other;
        assert!(decrypt_media(&forged, &enc.ciphertext).is_err());
    }

    /// A key that is not 32 bytes is rejected before any AEAD work happens.
    #[test]
    fn malformed_key_is_rejected() {
        assert!(encrypt_media_with_key("not-base64!!", b"x").is_err());
        assert!(encrypt_media_with_key(&vodozemac::base64_encode([0u8; 16]), b"x").is_err());
    }
}
