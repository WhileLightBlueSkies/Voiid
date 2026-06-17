use thiserror::Error;

/// All errors surfaced across the FFI boundary.
///
/// IMPORTANT: error messages must never contain plaintext, private keys, or
/// other user secrets — error strings can end up in logs.
#[derive(Debug, Error)]
pub enum E2eError {
    #[error("no session established for this peer")]
    NoSession,

    #[error("failed to decrypt message")]
    DecryptionFailed,

    #[error("malformed key material")]
    InvalidKey,

    #[error("serialization error")]
    Serialization,
}
