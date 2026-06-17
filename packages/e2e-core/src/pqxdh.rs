//! Post-quantum 1:1 — GATED scaffold.
//!
//! Goal: add post-quantum (harvest-now-decrypt-later) protection to the 1:1
//! handshake the way Signal's PQXDH does — by mixing an **ML-KEM** shared secret
//! into the session key derivation alongside the classic X25519 secret.
//!
//! ## What is implemented here (safe, default-on `pq-1to1-prekeys`)
//!
//! - ML-KEM-768 (FIPS 203, RustCrypto `ml-kem`, Apache/MIT) **prekey** generation,
//!   encoding/transport, and the KEM encapsulate/decapsulate round-trip.
//! - This lets a device publish a PQ prekey in its bundle and lets a sender
//!   encapsulate a PQ shared secret to it. NO bespoke handshake crypto runs.
//!
//! ## What is deliberately NOT active (the `pq-1to1-activate` gate)
//!
//! Mixing the KEM secret INTO the live handshake means writing a KEM/DH
//! **combiner** + transcript binding + KDF labeling + downgrade protection.
//! vodozemac's Olm handshake has no extension point for this, so doing it means
//! a bespoke construction — exactly the footgun that breaks real PQ deployments.
//! That path is gated behind the `pq-1to1-activate` feature, which `compile_error!`s
//! until an external cryptographic review signs off (see bottom of this file).
//!
//! Reference: https://signal.org/docs/specifications/pqxdh/

#![cfg(feature = "pq-1to1-prekeys")]

use ml_kem::kem::{Encapsulate, Kem, KeyExport, TryDecapsulate};
use ml_kem::MlKem768;

use crate::error::E2eError;

type Ek = ml_kem::EncapsulationKey<MlKem768>;
type Dk = ml_kem::DecapsulationKey<MlKem768>;

/// A device's post-quantum prekey. The public half goes in the published bundle
/// (alongside the classic identity/one-time keys); the private half stays on the
/// device. Like classic prekeys, a PQ prekey may be one-time or rotated.
pub struct PqPrekey {
    decapsulation_key: Dk,
    encapsulation_key: Ek,
}

impl PqPrekey {
    /// Generate a fresh ML-KEM-768 prekey pair (system CSPRNG via getrandom).
    pub fn generate() -> Self {
        let (dk, ek) = MlKem768::generate_keypair();
        Self {
            decapsulation_key: dk,
            encapsulation_key: ek,
        }
    }

    /// The public encapsulation key (base64) to publish in the bundle.
    pub fn public_key_b64(&self) -> String {
        vodozemac::base64_encode(self.encapsulation_key.to_bytes())
    }

    /// Decapsulate the shared secret from a sender's KEM ciphertext.
    /// Returns the 32-byte ML-KEM shared secret.
    pub fn decapsulate(&self, ciphertext_b64: &str) -> Result<Vec<u8>, E2eError> {
        let ct_bytes =
            vodozemac::base64_decode(ciphertext_b64).map_err(|_| E2eError::InvalidKey)?;
        let ct = ml_kem::Ciphertext::<MlKem768>::try_from(ct_bytes.as_slice())
            .map_err(|_| E2eError::InvalidKey)?;
        let shared = self
            .decapsulation_key
            .try_decapsulate(&ct)
            .map_err(|_| E2eError::DecryptionFailed)?;
        Ok(shared.to_vec())
    }
}

/// A sender encapsulates a PQ shared secret to a peer's published PQ prekey.
/// Returns the KEM ciphertext (base64, to send to the peer) and the 32-byte
/// shared secret (to be mixed into the handshake — see the gate below).
pub fn encapsulate_to(peer_public_key_b64: &str) -> Result<(String, Vec<u8>), E2eError> {
    let ek_bytes =
        vodozemac::base64_decode(peer_public_key_b64).map_err(|_| E2eError::InvalidKey)?;
    let key = ml_kem::Key::<Ek>::try_from(ek_bytes.as_slice()).map_err(|_| E2eError::InvalidKey)?;
    let ek = Ek::new(&key).map_err(|_| E2eError::InvalidKey)?;

    let (ct, shared) = ek.encapsulate();
    Ok((vodozemac::base64_encode(ct.as_slice()), shared.to_vec()))
}

// ---------------------------------------------------------------------------
// THE GATE: the live handshake combiner is intentionally not buildable yet.
// ---------------------------------------------------------------------------
//
// Activating `pq-1to1-activate` would compile the combiner that mixes the
// ML-KEM secret into the Olm session keys. That construction is bespoke and
// MUST NOT ship without an external cryptographic review. The compile_error
// below makes it impossible to enable by accident.
#[cfg(feature = "pq-1to1-activate")]
compile_error!(
    "pq-1to1-activate is gated: the 1:1 PQ handshake combiner is a bespoke \
     construction over vodozemac's Olm handshake and has NOT been reviewed by a \
     cryptographer. Do not enable this feature until that review signs off. \
     See src/pqxdh.rs and SPEC_NOTES.md."
);
