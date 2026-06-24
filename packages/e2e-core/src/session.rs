use serde::{Deserialize, Serialize};
use vodozemac::olm::{OlmMessage, Session as OlmSession, SessionConfig, SessionPickle};
use vodozemac::Curve25519PublicKey;

use crate::error::E2eError;
use crate::keys::IdentityKeys;

/// A message as it travels over the wire (through the backend relay).
///
/// vodozemac messages are typed: the first message in a session is a `PreKey`
/// message (type 0) and carries the material the receiver needs to build their
/// side of the session; subsequent messages are `Normal` (type 1). We carry the
/// type tag explicitly so the receiver never has to guess.
#[derive(Clone, Serialize, Deserialize)]
pub struct WireMessage {
    /// 0 = PreKey (session-establishing), 1 = Normal.
    pub msg_type: usize,
    /// Base64-encoded ciphertext body.
    pub body: String,
}

impl WireMessage {
    fn from_olm(msg: OlmMessage) -> Self {
        let (msg_type, bytes) = msg.to_parts();
        Self {
            msg_type,
            body: vodozemac::base64_encode(bytes),
        }
    }

    fn to_olm(&self) -> Result<OlmMessage, E2eError> {
        let bytes = vodozemac::base64_decode(&self.body).map_err(|_| E2eError::DecryptionFailed)?;
        OlmMessage::from_parts(self.msg_type, &bytes).map_err(|_| E2eError::DecryptionFailed)
    }

    /// The globally-unique session id of a PreKey (session-establishing) message,
    /// or `None` for a Normal message / on decode error. Derived from the message's
    /// SessionKeys (identity + base + one-time key), this EQUALS the `session_id()` of
    /// the `Session` it would establish — so the receiver can detect "I already have a
    /// session for this PreKey" and reuse it instead of re-accepting (which would
    /// consume another one-time key). This is the same dedup libsignal performs via
    /// `promote_matching_session` keyed on the base key.
    pub fn prekey_session_id(&self) -> Option<String> {
        match self.to_olm().ok()? {
            OlmMessage::PreKey(m) => Some(m.session_id()),
            OlmMessage::Normal(_) => None,
        }
    }
}

/// An established 1:1 encrypted session with one peer device.
///
/// Wraps a vodozemac double-ratchet session. The ratchet state must be persisted
/// (see `to_pickle`) so the session survives app restarts.
pub struct Session {
    inner: OlmSession,
}

impl Session {
    /// Start a session with a peer using the public bundle we fetched for them
    /// from the backend. Used by the side sending the FIRST message.
    pub fn initiate(
        our_identity: &IdentityKeys,
        their_identity_key: &str,
        their_one_time_key: &str,
    ) -> Result<Self, E2eError> {
        let identity_key = Curve25519PublicKey::from_base64(their_identity_key)
            .map_err(|_| E2eError::InvalidKey)?;
        let one_time_key = Curve25519PublicKey::from_base64(their_one_time_key)
            .map_err(|_| E2eError::InvalidKey)?;

        let inner = our_identity
            .account()
            .create_outbound_session(SessionConfig::version_1(), identity_key, one_time_key)
            .map_err(|_| E2eError::InvalidKey)?;
        Ok(Self { inner })
    }

    /// Create a session from the first inbound (pre-key) message. Used by the
    /// side RECEIVING the first message. Returns the session and the decrypted
    /// plaintext.
    pub fn from_first_message(
        our_identity: &mut IdentityKeys,
        their_identity_key: &str,
        message: &WireMessage,
    ) -> Result<(Self, Vec<u8>), E2eError> {
        let identity_key = Curve25519PublicKey::from_base64(their_identity_key)
            .map_err(|_| E2eError::InvalidKey)?;

        let OlmMessage::PreKey(prekey) = message.to_olm()? else {
            // A normal message can't establish a session — caller has no session.
            return Err(E2eError::NoSession);
        };

        let result = our_identity
            .account_mut()
            .create_inbound_session(SessionConfig::version_1(), identity_key, &prekey)
            .map_err(|_| E2eError::DecryptionFailed)?;

        Ok((
            Self {
                inner: result.session,
            },
            result.plaintext,
        ))
    }

    /// Globally-unique id of this session. Two devices that share a session compute
    /// the SAME id, and it matches the `prekey_session_id()` of the PreKey message that
    /// established it — used to dedup candidate sessions and avoid re-accepting.
    pub fn session_id(&self) -> String {
        self.inner.session_id()
    }

    /// Encrypt a plaintext message for the peer. The returned `WireMessage` is
    /// safe to hand to the backend relay.
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<WireMessage, E2eError> {
        let msg = self
            .inner
            .encrypt(plaintext)
            .map_err(|_| E2eError::Serialization)?;
        Ok(WireMessage::from_olm(msg))
    }

    /// Decrypt a message received from the peer (via the relay).
    pub fn decrypt(&mut self, message: &WireMessage) -> Result<Vec<u8>, E2eError> {
        let olm = message.to_olm()?;
        self.inner
            .decrypt(&olm)
            .map_err(|_| E2eError::DecryptionFailed)
    }

    /// Persist ratchet state (encrypted) for restoring after restart.
    pub fn to_pickle(&self, pickle_key: &[u8; 32]) -> String {
        self.inner.pickle().encrypt(pickle_key)
    }

    /// Restore a persisted session.
    pub fn from_pickle(pickle: &str, pickle_key: &[u8; 32]) -> Result<Self, E2eError> {
        let pickle =
            SessionPickle::from_encrypted(pickle, pickle_key).map_err(|_| E2eError::InvalidKey)?;
        Ok(Self {
            inner: OlmSession::from_pickle(pickle),
        })
    }
}
