//! Phase 4 — call & group-call key derivation.
//!
//! Live audio/video rides WebRTC, which encrypts media with **SRTP**. A call is
//! "E2EE" when *we* own the SRTP key instead of a server. This module only
//! produces the key material; the actual WebRTC/SRTP wiring lives in the app +
//! signaling layers.
//!
//! - **1:1 call:** the caller generates a random [`CallSecret`], sends it to the
//!   peer as a normal Phase-1 ratchet message, and both sides derive the same
//!   SRTP keys from it.
//! - **Group call:** the shared secret is the group's exporter secret (see
//!   `GroupSession::export_call_key`), so every member derives the same keys and
//!   they rotate automatically on membership change.
//!
//! Both paths funnel through [`derive_srtp_keys`] so 1:1 and group calls use the
//! same KDF, just with a different root secret.

use hkdf::Hkdf;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::error::E2eError;

/// AES-128 SRTP master key length (bytes).
const SRTP_KEY_LEN: usize = 16;
/// SRTP master salt length (bytes).
const SRTP_SALT_LEN: usize = 14;

/// A fresh per-call secret for a 1:1 call. Sent to the peer over the ratchet;
/// never given to the server in the clear.
#[derive(Clone, Serialize, Deserialize)]
pub struct CallSecret {
    /// 32 random bytes (base64).
    pub secret: String,
}

/// SRTP master key + salt, ready to hand to WebRTC. Both call participants
/// derive identical values from the same root secret.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SrtpKeys {
    pub master_key: Vec<u8>,
    pub master_salt: Vec<u8>,
}

/// Generate a fresh 1:1 call secret. The caller sends this to the peer as a
/// Phase-1 E2EE message, then both sides call [`srtp_keys_for_1to1`].
pub fn new_call_secret() -> CallSecret {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    CallSecret {
        secret: vodozemac::base64_encode(bytes),
    }
}

/// Derive SRTP keys for a 1:1 call from the exchanged [`CallSecret`].
pub fn srtp_keys_for_1to1(call_secret: &CallSecret) -> Result<SrtpKeys, E2eError> {
    let root =
        vodozemac::base64_decode(&call_secret.secret).map_err(|_| E2eError::InvalidKey)?;
    derive_srtp_keys(&root)
}

/// Derive SRTP keys from an arbitrary shared root secret. For group calls, pass
/// the value from `GroupSession::export_call_key`.
pub fn derive_srtp_keys(root_secret: &[u8]) -> Result<SrtpKeys, E2eError> {
    let hk = Hkdf::<Sha256>::new(Some(b"voiid-srtp-v1"), root_secret);

    let mut master_key = vec![0u8; SRTP_KEY_LEN];
    let mut master_salt = vec![0u8; SRTP_SALT_LEN];
    hk.expand(b"srtp-master-key", &mut master_key)
        .map_err(|_| E2eError::Serialization)?;
    hk.expand(b"srtp-master-salt", &mut master_salt)
        .map_err(|_| E2eError::Serialization)?;

    Ok(SrtpKeys {
        master_key,
        master_salt,
    })
}
