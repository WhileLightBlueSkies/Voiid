//! uniffi FFI layer — the surface iOS (Swift) and Android (Kotlin) call.
//!
//! This is the ONLY place that knows about FFI. It wraps the clean Rust core
//! (`api`, `keys`, `session`, ...) in uniffi-compatible shapes:
//!   - long-lived stateful things become `Object`s behind a `Mutex` (uniffi
//!     hands them out as `Arc<T>` and calls take `&self`, so we need interior
//!     mutability for the ratchet/group state that mutates on each message);
//!   - value types become `Record`s;
//!   - errors become a flat `Error` enum.
//!
//! Keep this thin: logic stays in the core, this just adapts types.

use std::sync::Mutex;

use crate::{api, call, group, keys, media, recovery, session};

// ---- Errors ----

/// Flat error surfaced to Swift/Kotlin. No secrets in any variant.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum E2eFfiError {
    #[error("no session established for this peer")]
    NoSession,
    #[error("failed to decrypt message")]
    DecryptionFailed,
    #[error("malformed key material")]
    InvalidKey,
    #[error("serialization error")]
    Serialization,
}

impl From<crate::E2eError> for E2eFfiError {
    fn from(e: crate::E2eError) -> Self {
        match e {
            crate::E2eError::NoSession => Self::NoSession,
            crate::E2eError::DecryptionFailed => Self::DecryptionFailed,
            crate::E2eError::InvalidKey => Self::InvalidKey,
            crate::E2eError::Serialization => Self::Serialization,
        }
    }
}

type FfiResult<T> = Result<T, E2eFfiError>;

// ---- Records (value types) ----

#[derive(uniffi::Record)]
pub struct PublicBundle {
    pub identity_key: String,
    pub signing_key: String,
    pub one_time_keys: Vec<String>,
    /// The X3DH "signed prekey" — used when one-time keys are exhausted.
    /// `None` means no NEW fallback key to upload; the published one stands.
    pub fallback_key: Option<String>,
}

impl From<keys::PublicBundle> for PublicBundle {
    fn from(b: keys::PublicBundle) -> Self {
        Self {
            identity_key: b.identity_key,
            signing_key: b.signing_key,
            one_time_keys: b.one_time_keys,
            fallback_key: b.fallback_key,
        }
    }
}

#[derive(uniffi::Record)]
pub struct WireMessage {
    pub msg_type: u64,
    pub body: String,
}

impl From<session::WireMessage> for WireMessage {
    fn from(m: session::WireMessage) -> Self {
        Self {
            msg_type: m.msg_type as u64,
            body: m.body,
        }
    }
}

impl From<WireMessage> for session::WireMessage {
    fn from(m: WireMessage) -> Self {
        Self {
            msg_type: m.msg_type as usize,
            body: m.body,
        }
    }
}

#[derive(uniffi::Record)]
pub struct MediaKey {
    pub key: String,
    pub nonce: String,
    pub ciphertext_sha256: String,
}

impl From<media::MediaKey> for MediaKey {
    fn from(k: media::MediaKey) -> Self {
        Self {
            key: k.key,
            nonce: k.nonce,
            ciphertext_sha256: k.ciphertext_sha256,
        }
    }
}
impl From<MediaKey> for media::MediaKey {
    fn from(k: MediaKey) -> Self {
        Self {
            key: k.key,
            nonce: k.nonce,
            ciphertext_sha256: k.ciphertext_sha256,
        }
    }
}

/// Encrypting media returns the blob to upload + the key to send over a message.
#[derive(uniffi::Record)]
pub struct EncryptedMedia {
    pub ciphertext: Vec<u8>,
    pub media_key: MediaKey,
}

#[derive(uniffi::Record)]
pub struct CallSecret {
    pub secret: String,
}
impl From<call::CallSecret> for CallSecret {
    fn from(c: call::CallSecret) -> Self {
        Self { secret: c.secret }
    }
}
impl From<CallSecret> for call::CallSecret {
    fn from(c: CallSecret) -> Self {
        Self { secret: c.secret }
    }
}

#[derive(uniffi::Record)]
pub struct SrtpKeys {
    pub master_key: Vec<u8>,
    pub master_salt: Vec<u8>,
}
impl From<call::SrtpKeys> for SrtpKeys {
    fn from(k: call::SrtpKeys) -> Self {
        Self {
            master_key: k.master_key,
            master_salt: k.master_salt,
        }
    }
}

/// A master backup secret sealed under a PIN. Opaque to the server; store as-is
/// and pass back to `unwrap_master_secret_with_pin` with the PIN to recover.
#[derive(uniffi::Record)]
pub struct PinWrappedSecret {
    pub version: u8,
    pub salt: String,
    pub nonce: String,
    pub ciphertext: String,
}
impl From<recovery::PinWrappedSecret> for PinWrappedSecret {
    fn from(w: recovery::PinWrappedSecret) -> Self {
        Self {
            version: w.version,
            salt: w.salt,
            nonce: w.nonce,
            ciphertext: w.ciphertext,
        }
    }
}
impl From<PinWrappedSecret> for recovery::PinWrappedSecret {
    fn from(w: PinWrappedSecret) -> Self {
        Self {
            version: w.version,
            salt: w.salt,
            nonce: w.nonce,
            ciphertext: w.ciphertext,
        }
    }
}

/// Bytes produced when adding a group member.
#[derive(uniffi::Record)]
pub struct AddMemberOutput {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
    pub ratchet_tree: Vec<u8>,
}

// ---- Objects (stateful, behind a Mutex) ----

/// A device's 1:1 identity (Phase 1).
#[derive(uniffi::Object)]
pub struct Identity {
    inner: Mutex<keys::IdentityKeys>,
}

#[uniffi::export]
impl Identity {
    /// Generate a brand-new device identity.
    #[uniffi::constructor]
    pub fn create() -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self {
            inner: Mutex::new(keys::IdentityKeys::generate()),
        })
    }

    /// Restore from an encrypted pickle saved in device storage.
    #[uniffi::constructor]
    pub fn restore(pickle: String, pickle_key: Vec<u8>) -> FfiResult<std::sync::Arc<Self>> {
        let key = to_key32(&pickle_key)?;
        let inner = keys::IdentityKeys::from_pickle(&pickle, &key)?;
        Ok(std::sync::Arc::new(Self {
            inner: Mutex::new(inner),
        }))
    }

    /// Stable Ed25519 fingerprint (base64) for safety-number verification.
    pub fn fingerprint(&self) -> String {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .fingerprint()
    }

    /// Public bundle to upload so peers can start a session with us.
    pub fn publish_bundle(&self, one_time_key_count: u32) -> PublicBundle {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .public_bundle(one_time_key_count as usize)
            .into()
    }

    /// Generate and publish additional one-time keys when supply runs low.
    /// Returns only the new keys to upload.
    pub fn replenish_prekeys(&self, count: u32) -> PublicBundle {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .replenish(count as usize)
            .into()
    }

    /// Rotate the fallback key (X3DH "signed prekey"). Call ~weekly. Returns the
    /// bundle to upload; peers use it once our one-time keys run out.
    pub fn rotate_fallback_key(&self) -> PublicBundle {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .rotate_fallback_key()
            .into()
    }

    /// The fallback key currently published for this device, if any.
    pub fn current_fallback_key(&self) -> Option<String> {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .current_fallback_key()
    }

    /// Drop the previous fallback key, one rotation after `rotate_fallback_key`.
    pub fn forget_previous_fallback_key(&self) -> bool {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .forget_previous_fallback_key()
    }

    /// Re-attach a published fallback key after restoring from a pickle.
    pub fn restore_fallback_key(&self, fallback_key: String) {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .restore_fallback_key(&fallback_key)
    }

    /// Maximum one-time keys this device can hold at once.
    pub fn max_one_time_keys(&self) -> u32 {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .max_one_time_keys() as u32
    }

    /// Encrypted pickle to persist this identity in device storage.
    pub fn to_pickle(&self, pickle_key: Vec<u8>) -> FfiResult<String> {
        let key = to_key32(&pickle_key)?;
        Ok(self
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .to_pickle(&key))
    }

    /// Start a 1:1 session as the sender of the first message.
    pub fn start_session(
        &self,
        their_identity_key: String,
        their_one_time_key: String,
    ) -> FfiResult<std::sync::Arc<Session>> {
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let s = session::Session::initiate(&inner, &their_identity_key, &their_one_time_key)?;
        Ok(std::sync::Arc::new(Session {
            inner: Mutex::new(s),
        }))
    }

    /// Accept a 1:1 session from an inbound first message. Returns the new
    /// session and the decrypted first plaintext.
    pub fn accept_session(
        &self,
        their_identity_key: String,
        first_message: WireMessage,
    ) -> FfiResult<AcceptedSession> {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let (s, plaintext) = session::Session::from_first_message(
            &mut inner,
            &their_identity_key,
            &first_message.into(),
        )?;
        Ok(AcceptedSession {
            session: std::sync::Arc::new(Session {
                inner: Mutex::new(s),
            }),
            plaintext,
        })
    }
}

/// Result of accepting a session: the session plus the first message's bytes.
#[derive(uniffi::Record)]
pub struct AcceptedSession {
    pub session: std::sync::Arc<Session>,
    pub plaintext: Vec<u8>,
}

/// An established 1:1 session (Phase 1).
#[derive(uniffi::Object)]
pub struct Session {
    inner: Mutex<session::Session>,
}

#[uniffi::export]
impl Session {
    /// Globally-unique session id (equal on both peers; matches the establishing
    /// PreKey message's `prekey_session_id`). Used by clients to dedup candidate
    /// sessions and avoid re-accepting a PreKey for a session they already hold.
    pub fn session_id(&self) -> String {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .session_id()
    }

    pub fn encrypt(&self, plaintext: Vec<u8>) -> FfiResult<WireMessage> {
        Ok(self
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .encrypt(&plaintext)?
            .into())
    }

    pub fn decrypt(&self, message: WireMessage) -> FfiResult<Vec<u8>> {
        Ok(self
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .decrypt(&message.into())?)
    }

    pub fn to_pickle(&self, pickle_key: Vec<u8>) -> FfiResult<String> {
        let key = to_key32(&pickle_key)?;
        Ok(self
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .to_pickle(&key))
    }

    #[uniffi::constructor]
    pub fn restore(pickle: String, pickle_key: Vec<u8>) -> FfiResult<std::sync::Arc<Self>> {
        let key = to_key32(&pickle_key)?;
        let s = session::Session::from_pickle(&pickle, &key)?;
        Ok(std::sync::Arc::new(Self {
            inner: Mutex::new(s),
        }))
    }
}

/// A device's MLS identity for groups (Phase 3).
#[derive(uniffi::Object)]
pub struct GroupMember {
    inner: group::GroupMember,
}

#[uniffi::export]
impl GroupMember {
    #[uniffi::constructor]
    pub fn create(identity: Vec<u8>) -> FfiResult<std::sync::Arc<Self>> {
        Ok(std::sync::Arc::new(Self {
            inner: group::GroupMember::new(&identity)?,
        }))
    }

    /// Public KeyPackage (TLS bytes) to upload so others can add us to groups.
    pub fn key_package(&self) -> FfiResult<Vec<u8>> {
        Ok(self.inner.key_package()?)
    }

    /// Create a new group containing just this member.
    pub fn create_group(&self) -> FfiResult<std::sync::Arc<GroupSession>> {
        Ok(std::sync::Arc::new(GroupSession {
            inner: Mutex::new(self.inner.create_group()?),
        }))
    }

    /// Join an existing group from a Welcome + ratchet tree.
    pub fn join_group(
        &self,
        welcome: Vec<u8>,
        ratchet_tree: Vec<u8>,
    ) -> FfiResult<std::sync::Arc<GroupSession>> {
        Ok(std::sync::Arc::new(GroupSession {
            inner: Mutex::new(self.inner.join_group(&welcome, &ratchet_tree)?),
        }))
    }

    /// Serialize this member and ALL its MLS state (signer + KeyPackage privates +
    /// every group it belongs to) to an opaque blob. Persist it encrypted
    /// on-device and restore it on the next launch with `restore`. MLS state is
    /// in-memory only, so WITHOUT persisting this, groups are lost on app restart.
    /// Re-serialize after every state-changing call (create/join/add/remove/
    /// encrypt/decrypt).
    pub fn serialize(&self) -> FfiResult<Vec<u8>> {
        Ok(self.inner.serialize()?)
    }

    /// Reconstruct a member (and its full MLS storage) from a `serialize` blob.
    #[uniffi::constructor]
    pub fn restore(blob: Vec<u8>) -> FfiResult<std::sync::Arc<Self>> {
        Ok(std::sync::Arc::new(Self {
            inner: group::GroupMember::restore(&blob)?,
        }))
    }

    /// Re-open a group this member belongs to, by its `group_id`, after restoring.
    pub fn load_group(&self, group_id: Vec<u8>) -> FfiResult<std::sync::Arc<GroupSession>> {
        Ok(std::sync::Arc::new(GroupSession {
            inner: Mutex::new(self.inner.load_group(&group_id)?),
        }))
    }
}

/// Membership in one MLS group (Phase 3).
#[derive(uniffi::Object)]
pub struct GroupSession {
    inner: Mutex<group::GroupSession>,
}

#[uniffi::export]
impl GroupSession {
    /// Add a member by their KeyPackage. Broadcast `commit` to existing members
    /// and send `welcome`+`ratchet_tree` to the new member.
    pub fn add_member(
        &self,
        member: &GroupMember,
        their_key_package: Vec<u8>,
    ) -> FfiResult<AddMemberOutput> {
        let out = self
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .add_member(&member.inner, &their_key_package)?;
        Ok(AddMemberOutput {
            commit: out.commit,
            welcome: out.welcome,
            ratchet_tree: out.ratchet_tree,
        })
    }

    /// Remove the member with stable identifier `identity`. Returns the commit
    /// to broadcast to remaining members; rekeys so the removed member can't
    /// read later messages.
    pub fn remove_member(&self, member: &GroupMember, identity: Vec<u8>) -> FfiResult<Vec<u8>> {
        Ok(self
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove_member(&member.inner, &identity)?)
    }

    /// The current epoch number.
    ///
    /// Two commits built against the SAME epoch are concurrent: the server accepts one and
    /// the losers must discard their pending commit and process the winner instead. Without
    /// this on the FFI surface an app cannot even detect that it lost — it has no way to
    /// compare the epoch it committed against with the one a arriving commit belongs to.
    ///
    /// This matters now rather than theoretically: a group may have up to 50 admins
    /// (036_group_roles.sql), so concurrent adds and removes are expected, not exotic.
    pub fn epoch(&self) -> u64 {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).epoch()
    }

    /// Discard a pending commit that LOST a concurrency race, so the winning commit can be
    /// processed instead.
    ///
    /// The other half of lost-race reconciliation, and useless without `epoch()` — which is
    /// why both were missing together and neither could be used alone. The sequence an app
    /// implements with these two is: commit, see a foreign commit for the epoch you built
    /// against, call this, then `decrypt` the winner and retry your own change.
    ///
    /// Idempotent in effect: clearing when nothing is pending is not an error.
    pub fn clear_pending(&self, member: &GroupMember) -> FfiResult<()> {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear_pending(&member.inner)?;
        Ok(())
    }

    /// Current member count from our view of the group state.
    pub fn member_count(&self) -> u32 {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .member_count() as u32
    }

    /// This group's stable id — persist it and pass it to `GroupMember.load_group`
    /// after a restart to re-open this exact group.
    pub fn group_id(&self) -> Vec<u8> {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .group_id()
    }

    pub fn encrypt(&self, member: &GroupMember, plaintext: Vec<u8>) -> FfiResult<Vec<u8>> {
        Ok(self
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .encrypt(&member.inner, &plaintext)?)
    }

    /// Process an incoming group message. Application messages return their
    /// plaintext; commits/proposals are applied and return null.
    pub fn decrypt(&self, member: &GroupMember, message: Vec<u8>) -> FfiResult<Option<Vec<u8>>> {
        Ok(self
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .decrypt(&member.inner, &message)?)
    }

    /// Derive SRTP keys for a group call from the group's exporter secret.
    pub fn call_keys(&self, member: &GroupMember) -> FfiResult<SrtpKeys> {
        let root = self
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .export_call_key(&member.inner, 32)?;
        Ok(call::derive_srtp_keys(&root)?.into())
    }
}

// ---- Free functions ----

/// Compute the safety number two users compare out-of-band (anti-MITM). Pass
/// each party's stable identifier plus their fingerprint.
#[uniffi::export]
pub fn safety_number(
    our_id: Vec<u8>,
    our_fingerprint: String,
    their_id: Vec<u8>,
    their_fingerprint: String,
) -> String {
    api::safety_number(&our_id, &our_fingerprint, &their_id, &their_fingerprint)
}

/// The session id a PreKey (session-establishing) message would create, or `None`
/// for a Normal message. Equals the `Session::session_id()` of the matching session,
/// so a receiver can check "do I already have this session?" before accepting a new
/// one — avoiding a redundant accept that would consume another one-time key. Mirrors
/// libsignal's base-key dedup (`promote_matching_session`).
#[uniffi::export]
pub fn prekey_session_id(message: WireMessage) -> Option<String> {
    let m: session::WireMessage = message.into();
    m.prekey_session_id()
}

/// Encrypt an attachment. Upload `ciphertext`; send `media_key` over a message.
#[uniffi::export]
pub fn encrypt_media(plaintext: Vec<u8>) -> FfiResult<EncryptedMedia> {
    let enc = media::encrypt_media(&plaintext)?;
    Ok(EncryptedMedia {
        ciphertext: enc.ciphertext,
        media_key: enc.media_key.into(),
    })
}

/// Decrypt a downloaded blob using the media key received over a message.
#[uniffi::export]
pub fn decrypt_media(media_key: MediaKey, ciphertext: Vec<u8>) -> FfiResult<Vec<u8>> {
    Ok(media::decrypt_media(&media_key.into(), &ciphertext)?)
}

/// A fresh long-lived PROFILE KEY, for encrypting a user's avatar.
///
/// Avatars cannot use `encrypt_media`'s per-attachment key: a chat photo has one known
/// audience and its key rides the ratchet with the message, but an avatar is shown to anyone
/// who might contact you — including someone who found your @username and has never had a
/// session with you. There is no single message to attach a key to, so the key is per-USER,
/// long-lived, and wrapped to each contact over the ratchet as you talk to them.
#[uniffi::export]
pub fn generate_profile_key() -> String {
    media::generate_profile_key()
}

/// Encrypt with a key the caller ALREADY HOLDS, instead of minting a fresh one.
///
/// This is the primitive avatars need and `encrypt_media` cannot provide — that function
/// always generates a new key, which is right for single-use attachments and useless for
/// anything long-lived.
///
/// A fresh nonce is still generated internally on every call, which is not optional: AES-GCM
/// fails catastrophically on nonce reuse under one key, and a profile key is reused on every
/// re-upload.
#[uniffi::export]
pub fn encrypt_media_with_key(key_b64: String, plaintext: Vec<u8>) -> FfiResult<EncryptedMedia> {
    let enc = media::encrypt_media_with_key(&key_b64, &plaintext)?;
    Ok(EncryptedMedia {
        ciphertext: enc.ciphertext,
        media_key: enc.media_key.into(),
    })
}

// ---- Account recovery ----

/// Generate a fresh, random 32-byte master backup secret.
#[uniffi::export]
pub fn generate_master_secret() -> Vec<u8> {
    api::generate_master_secret().to_vec()
}

/// Render a master secret as a 24-word BIP39 recovery phrase.
#[uniffi::export]
pub fn master_secret_to_phrase(secret: Vec<u8>) -> FfiResult<String> {
    let secret = to_key32(&secret)?;
    Ok(api::master_secret_to_phrase(&secret))
}

/// Recover a master secret from a BIP39 recovery phrase. Errors on a bad phrase.
#[uniffi::export]
pub fn phrase_to_master_secret(phrase: String) -> FfiResult<Vec<u8>> {
    Ok(api::phrase_to_master_secret(&phrase)?.to_vec())
}

/// Seal a master secret under a PIN. The result is opaque to the server.
#[uniffi::export]
pub fn wrap_master_secret_with_pin(secret: Vec<u8>, pin: String) -> FfiResult<PinWrappedSecret> {
    let secret = to_key32(&secret)?;
    Ok(api::wrap_master_secret_with_pin(&secret, &pin)?.into())
}

/// Recover a master secret from a PIN-wrapped secret using the PIN. A wrong PIN
/// or tampered wrap errors (GCM auth) rather than returning a wrong secret.
#[uniffi::export]
pub fn unwrap_master_secret_with_pin(wrapped: PinWrappedSecret, pin: String) -> FfiResult<Vec<u8>> {
    Ok(api::unwrap_master_secret_with_pin(&wrapped.into(), &pin)?.to_vec())
}

/// Seal a backup blob (client-serialized message history) under a key derived from
/// the master secret. Returns a self-describing byte string to upload as-is; the
/// server never sees the key or the plaintext.
#[uniffi::export]
pub fn encrypt_backup(secret: Vec<u8>, plaintext: Vec<u8>) -> FfiResult<Vec<u8>> {
    let secret = to_key32(&secret)?;
    Ok(api::encrypt_backup(&secret, &plaintext)?)
}

/// Open a backup blob produced by `encrypt_backup` using the master secret. A
/// wrong secret or tampered blob errors (GCM auth) rather than returning wrong
/// plaintext.
#[uniffi::export]
pub fn decrypt_backup(secret: Vec<u8>, blob: Vec<u8>) -> FfiResult<Vec<u8>> {
    let secret = to_key32(&secret)?;
    Ok(api::decrypt_backup(&secret, &blob)?)
}

/// Generate a fresh 1:1 call secret to send to the peer over a message.
#[uniffi::export]
pub fn new_call_secret() -> CallSecret {
    call::new_call_secret().into()
}

/// Derive SRTP keys for a 1:1 call from the exchanged call secret.
#[uniffi::export]
pub fn srtp_keys_for_1to1(call_secret: CallSecret) -> FfiResult<SrtpKeys> {
    Ok(call::srtp_keys_for_1to1(&call_secret.into())?.into())
}

// ---- helpers ----

/// Convert a caller-provided byte vec into a 32-byte pickle key.
fn to_key32(bytes: &[u8]) -> FfiResult<[u8; 32]> {
    bytes.try_into().map_err(|_| E2eFfiError::InvalidKey)
}
