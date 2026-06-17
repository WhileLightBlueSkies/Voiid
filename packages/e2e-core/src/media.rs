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
    let mut nonce_bytes = [0u8; 12];
    let mut rng = rand::thread_rng();
    rng.fill_bytes(&mut key_bytes);
    rng.fill_bytes(&mut nonce_bytes);

    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key_bytes));
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
    let expected = vodozemac::base64_decode(&media_key.ciphertext_sha256)
        .map_err(|_| E2eError::InvalidKey)?;
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
