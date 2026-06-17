//! The flat, binding-friendly public surface.
//!
//! Swift / Kotlin / Node bindings should map onto THESE functions. Keep this
//! surface small and stable — every platform mirrors it, so changes here are
//! changes in three places.
//!
//! This is a Rust-level facade. The actual FFI export layer (uniffi / C ABI /
//! napi) lives under `bindings/` and calls into this module. Keeping the facade
//! separate from the FFI plumbing keeps the core testable in plain Rust.

use crate::call::{CallSecret, SrtpKeys};
use crate::error::E2eError;
use crate::group::{GroupMember, GroupSession};
use crate::keys::{IdentityKeys, PublicBundle};
use crate::media::{EncryptedMedia, MediaKey};
use crate::session::{Session, WireMessage};

/// Create a fresh device identity. Returns an opaque handle the caller stores.
pub fn create_identity() -> IdentityKeys {
    IdentityKeys::generate()
}

/// The device's stable fingerprint (base64 Ed25519 key) for safety-number
/// verification.
pub fn identity_fingerprint(identity: &IdentityKeys) -> String {
    identity.fingerprint()
}

/// Compute the safety number two users compare out-of-band to confirm there is
/// no man-in-the-middle. Binds each party's stable identifier to their key.
/// Symmetric: both sides get the same value.
pub fn safety_number(
    our_id: &[u8],
    our_fingerprint: &str,
    their_id: &[u8],
    their_fingerprint: &str,
) -> String {
    crate::verify::safety_number(our_id, our_fingerprint, their_id, their_fingerprint)
}

/// Produce the public bundle to upload to the backend so peers can reach us.
pub fn publish_bundle(identity: &mut IdentityKeys, one_time_key_count: usize) -> PublicBundle {
    identity.public_bundle(one_time_key_count)
}

/// Generate and publish additional one-time keys when the server reports our
/// supply is running low. Returns only the new keys to upload.
pub fn replenish_prekeys(identity: &mut IdentityKeys, count: usize) -> PublicBundle {
    identity.replenish(count)
}

/// Maximum one-time keys this device can hold at once.
pub fn max_one_time_keys(identity: &IdentityKeys) -> usize {
    identity.max_one_time_keys()
}

// --- Post-quantum 1:1 prekeys (GATED scaffold; see src/pqxdh.rs) ---

/// Generate a post-quantum (ML-KEM-768) prekey. The public half is published in
/// the bundle; the private half stays on the device.
///
/// NOTE: this provides PQ PREKEY material only. Mixing the resulting shared
/// secret into the live 1:1 handshake is gated behind external cryptographic
/// review (`pq-1to1-activate`). See SPEC_NOTES.md.
#[cfg(feature = "pq-1to1-prekeys")]
pub fn generate_pq_prekey() -> crate::pqxdh::PqPrekey {
    crate::pqxdh::PqPrekey::generate()
}

/// Encapsulate a PQ shared secret to a peer's published PQ prekey. Returns the
/// KEM ciphertext to send and the shared secret (not yet wired into the
/// handshake — see the gate).
#[cfg(feature = "pq-1to1-prekeys")]
pub fn pq_encapsulate(peer_pq_public_key_b64: &str) -> Result<(String, Vec<u8>), E2eError> {
    crate::pqxdh::encapsulate_to(peer_pq_public_key_b64)
}

/// Begin a session as the sender of the first message.
pub fn start_session(
    identity: &IdentityKeys,
    their_identity_key: &str,
    their_one_time_key: &str,
) -> Result<Session, E2eError> {
    Session::initiate(identity, their_identity_key, their_one_time_key)
}

/// Accept a session from an inbound first message, returning the plaintext too.
pub fn accept_session(
    identity: &mut IdentityKeys,
    their_identity_key: &str,
    first_message: &WireMessage,
) -> Result<(Session, Vec<u8>), E2eError> {
    Session::from_first_message(identity, their_identity_key, first_message)
}

pub fn encrypt(session: &mut Session, plaintext: &[u8]) -> Result<WireMessage, E2eError> {
    session.encrypt(plaintext)
}

pub fn decrypt(session: &mut Session, message: &WireMessage) -> Result<Vec<u8>, E2eError> {
    session.decrypt(message)
}

// --- Phase 2: media (images / video / audio files) ---

/// Encrypt an attachment. Upload `ciphertext` to blob storage and send
/// `media_key` over a Phase-1 E2EE message.
pub fn encrypt_media(plaintext: &[u8]) -> Result<EncryptedMedia, E2eError> {
    crate::media::encrypt_media(plaintext)
}

/// Decrypt a downloaded blob using the media key received over the ratchet.
pub fn decrypt_media(media_key: &MediaKey, ciphertext: &[u8]) -> Result<Vec<u8>, E2eError> {
    crate::media::decrypt_media(media_key, ciphertext)
}

// --- Phase 4: calls (SRTP key derivation) ---

/// Generate a fresh 1:1 call secret. Send it to the peer over a Phase-1 E2EE
/// message; both sides then call `srtp_keys_for_1to1`.
pub fn new_call_secret() -> CallSecret {
    crate::call::new_call_secret()
}

/// Derive SRTP keys for a 1:1 call from the exchanged call secret.
pub fn srtp_keys_for_1to1(call_secret: &CallSecret) -> Result<SrtpKeys, E2eError> {
    crate::call::srtp_keys_for_1to1(call_secret)
}

/// Derive SRTP keys for a group call from the group's exporter secret. All
/// members derive the same keys; they rotate on every membership change.
pub fn srtp_keys_for_group(
    group: &GroupSession,
    member: &GroupMember,
) -> Result<SrtpKeys, E2eError> {
    // 32-byte root secret from MLS, then HKDF into SRTP key + salt.
    let root = group.export_call_key(member, 32)?;
    crate::call::derive_srtp_keys(&root)
}
