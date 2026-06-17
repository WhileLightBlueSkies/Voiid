//! Phase 3 — group messaging via MLS (RFC 9420), using OpenMLS (Apache-2.0).
//!
//! The double ratchet doesn't scale to groups, so groups use MLS instead:
//!   - Each device publishes an MLS **KeyPackage** (public) to the backend.
//!   - A creator builds a group and adds members by their KeyPackages,
//!     producing a **Welcome** the new member uses to join.
//!   - Application messages are encrypted to the whole group.
//!   - The group's **exporter secret** is reused to key group calls (Phase 4).
//!
//! Group media reuses the Phase-2 blob pattern: the blob key is sent as a group
//! application message instead of over the pairwise ratchet.

use openmls::prelude::{tls_codec::*, *};
use openmls_basic_credential::SignatureKeyPair;
use openmls_libcrux_crypto::Provider as LibcruxProvider;

use crate::error::E2eError;

/// Ciphersuite used across Voiid groups.
///
/// We use the **hybrid post-quantum** X-Wing suite (X25519 + ML-KEM-768), so
/// group key agreement resists "harvest-now-decrypt-later" attacks. The PQ KEM
/// comes from Cryspen's formally-verified libcrux via OpenMLS — we are not
/// hand-rolling any post-quantum crypto.
///
/// CAVEAT: codepoint `0x004D` is provisional — there is no assigned IANA
/// codepoint for X-Wing yet, and the underlying X-Wing draft is not finalized.
/// This is safe because Voiid controls both endpoints, but a future codepoint
/// assignment or draft change may require a migration. See SPEC_NOTES.md.
const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519;

/// A device's MLS identity: its credential, signing keys, and crypto/storage
/// provider. Created once per device (alongside the Phase-1 `IdentityKeys`).
pub struct GroupMember {
    provider: LibcruxProvider,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
}

impl GroupMember {
    /// Create a fresh MLS identity for this device. `identity` is an opaque
    /// label (e.g. the user/device id) — it is NOT secret.
    pub fn new(identity: &[u8]) -> Result<Self, E2eError> {
        let provider = LibcruxProvider::new().map_err(|_| E2eError::Serialization)?;
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
            .map_err(|_| E2eError::InvalidKey)?;
        signer
            .store(provider.storage())
            .map_err(|_| E2eError::Serialization)?;

        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity.to_vec()).into(),
            signature_key: signer.public().into(),
        };

        Ok(Self {
            provider,
            signer,
            credential,
        })
    }

    /// Produce a public KeyPackage to upload to the backend so others can add
    /// this device to a group. Returns the TLS-serialized bytes.
    pub fn key_package(&self) -> Result<Vec<u8>, E2eError> {
        let bundle = KeyPackage::builder()
            .build(CIPHERSUITE, &self.provider, &self.signer, self.credential.clone())
            .map_err(|_| E2eError::InvalidKey)?;
        bundle
            .key_package()
            .tls_serialize_detached()
            .map_err(|_| E2eError::Serialization)
    }

    /// Create a brand-new group with just this member in it. The group uses our
    /// post-quantum X-Wing ciphersuite — `MlsGroupCreateConfig::default()` would
    /// otherwise pick the classic suite and reject our PQ key packages.
    pub fn create_group(&self) -> Result<GroupSession, E2eError> {
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .build();
        let group = MlsGroup::new(&self.provider, &self.signer, &config, self.credential.clone())
            .map_err(|_| E2eError::Serialization)?;
        Ok(GroupSession { group })
    }

    /// Join an existing group from a Welcome message (TLS bytes) received after
    /// someone added us. `ratchet_tree` is the group's public tree, delivered
    /// out of band alongside the Welcome.
    ///
    /// One `GroupMember` joins one group once. If you leave a group and are
    /// re-added later, join with a FRESH `GroupMember` (same stable identity
    /// label is fine) — its per-group key state must be clean. Reusing a member
    /// that already holds state for this group will fail to join.
    pub fn join_group(
        &self,
        welcome_bytes: &[u8],
        ratchet_tree: &[u8],
    ) -> Result<GroupSession, E2eError> {
        let msg = MlsMessageIn::tls_deserialize(&mut &welcome_bytes[..])
            .map_err(|_| E2eError::DecryptionFailed)?;
        let welcome = match msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err(E2eError::DecryptionFailed),
        };
        let tree = RatchetTreeIn::tls_deserialize(&mut &ratchet_tree[..])
            .map_err(|_| E2eError::DecryptionFailed)?;

        let staged = StagedWelcome::new_from_welcome(
            &self.provider,
            &MlsGroupJoinConfig::default(),
            welcome,
            Some(tree),
        )
        .map_err(|_| E2eError::DecryptionFailed)?;
        let group = staged
            .into_group(&self.provider)
            .map_err(|_| E2eError::DecryptionFailed)?;
        Ok(GroupSession { group })
    }

    pub(crate) fn provider(&self) -> &LibcruxProvider {
        &self.provider
    }

    pub(crate) fn signer(&self) -> &SignatureKeyPair {
        &self.signer
    }
}

/// Bytes produced when adding a member: the `commit` to broadcast to existing
/// members, and the `welcome` to send to the new member (with `ratchet_tree`).
pub struct AddMemberOutput {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
    pub ratchet_tree: Vec<u8>,
}

/// An active membership in one MLS group.
pub struct GroupSession {
    group: MlsGroup,
}

impl GroupSession {
    /// Add a new member by their published KeyPackage (TLS bytes). Returns the
    /// commit (for existing members), the welcome (for the new member), and the
    /// group's ratchet tree. The commit is merged into our local state here, so
    /// the exported tree matches the state the welcome expects.
    pub fn add_member(
        &mut self,
        member: &GroupMember,
        their_key_package: &[u8],
    ) -> Result<AddMemberOutput, E2eError> {
        // Deserialize and verify the peer's KeyPackage signature before use.
        let kp_in = KeyPackageIn::tls_deserialize(&mut &their_key_package[..])
            .map_err(|_| E2eError::InvalidKey)?;
        let kp = kp_in
            .validate(member.provider().crypto(), ProtocolVersion::Mls10)
            .map_err(|_| E2eError::InvalidKey)?;

        let (commit, welcome, _group_info) = self
            .group
            .add_members(member.provider(), member.signer(), &[kp])
            .map_err(|_| E2eError::Serialization)?;

        // Merge BEFORE exporting the tree, so the tree reflects the post-add
        // state. Exporting beforehand yields a TreeHashMismatch on join.
        self.group
            .merge_pending_commit(member.provider())
            .map_err(|_| E2eError::Serialization)?;

        let ratchet_tree = self
            .group
            .export_ratchet_tree()
            .tls_serialize_detached()
            .map_err(|_| E2eError::Serialization)?;

        Ok(AddMemberOutput {
            commit: commit
                .tls_serialize_detached()
                .map_err(|_| E2eError::Serialization)?,
            welcome: welcome
                .tls_serialize_detached()
                .map_err(|_| E2eError::Serialization)?,
            ratchet_tree,
        })
    }

    /// Apply our own pending commit to local state. `add_member` already does
    /// this internally; this is exposed for other commit-producing operations
    /// that follow the same pattern.
    pub fn merge_pending(&mut self, member: &GroupMember) -> Result<(), E2eError> {
        self.group
            .merge_pending_commit(member.provider())
            .map_err(|_| E2eError::Serialization)
    }

    /// Remove the member whose stable identifier is `identity` (the bytes passed
    /// to `GroupMember::new`). Returns the `commit` to broadcast to remaining
    /// members; the commit is merged into our local state here, which rekeys the
    /// group so the removed member cannot read subsequent messages.
    ///
    /// Re-adding later is simply `add_member` again with a fresh KeyPackage from
    /// that member.
    pub fn remove_member(
        &mut self,
        member: &GroupMember,
        identity: &[u8],
    ) -> Result<Vec<u8>, E2eError> {
        // Find the target's leaf index by matching credential identity.
        let leaf = self
            .group
            .members()
            .find(|m| m.credential.serialized_content() == identity)
            .map(|m| m.index)
            .ok_or(E2eError::NoSession)?;

        let (commit, _welcome, _group_info) = self
            .group
            .remove_members(member.provider(), member.signer(), &[leaf])
            .map_err(|_| E2eError::Serialization)?;

        // Merge so our state reflects the removal + rekey.
        self.group
            .merge_pending_commit(member.provider())
            .map_err(|_| E2eError::Serialization)?;

        commit
            .tls_serialize_detached()
            .map_err(|_| E2eError::Serialization)
    }

    /// Number of members currently in the group (from our view of the state).
    pub fn member_count(&self) -> usize {
        self.group.members().count()
    }

    /// The current epoch number. Two commits built against the same epoch are
    /// "concurrent"; the relay/server must pick one winner and the losers must
    /// discard their pending commit and process the winner instead.
    pub fn epoch(&self) -> u64 {
        self.group.epoch().as_u64()
    }

    /// Discard a pending commit we built but that LOST a concurrency race (the
    /// server accepted someone else's commit for our epoch first). After this,
    /// process the winning commit with `decrypt`.
    ///
    /// NOTE: `add_member`/`remove_member` in this wrapper merge their commit
    /// locally for the simple single-committer case. For groups with concurrent
    /// committers, the app must instead detect a lost race (it sees another
    /// member's commit for the epoch it just committed against) and reconcile.
    /// `clear_pending` is the building block for that reconciliation.
    pub fn clear_pending(&mut self, member: &GroupMember) -> Result<(), E2eError> {
        self.group
            .clear_pending_commit(member.provider().storage())
            .map_err(|_| E2eError::Serialization)?;
        self.group
            .clear_pending_proposals(member.provider().storage())
            .map_err(|_| E2eError::Serialization)
    }

    /// Encrypt an application message to the whole group. Returns TLS bytes safe
    /// for the relay.
    pub fn encrypt(&mut self, member: &GroupMember, plaintext: &[u8]) -> Result<Vec<u8>, E2eError> {
        self.group
            .create_message(member.provider(), member.signer(), plaintext)
            .map_err(|_| E2eError::Serialization)?
            .tls_serialize_detached()
            .map_err(|_| E2eError::Serialization)
    }

    /// Process an incoming group message. Returns the plaintext for application
    /// messages; commits/proposals are applied to group state and return `None`.
    pub fn decrypt(
        &mut self,
        member: &GroupMember,
        message: &[u8],
    ) -> Result<Option<Vec<u8>>, E2eError> {
        let msg = MlsMessageIn::tls_deserialize(&mut &message[..])
            .map_err(|_| E2eError::DecryptionFailed)?;
        let protocol = match msg.try_into_protocol_message() {
            Ok(p) => p,
            Err(_) => return Err(E2eError::DecryptionFailed),
        };

        let processed = self
            .group
            .process_message(member.provider(), protocol)
            .map_err(|_| E2eError::DecryptionFailed)?;

        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app) => Ok(Some(app.into_bytes())),
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                self.group
                    .merge_staged_commit(member.provider(), *staged)
                    .map_err(|_| E2eError::Serialization)?;
                Ok(None)
            }
            _ => Ok(None),
        }
    }

    /// Derive a key for a group call (Phase 4) from the group's exporter secret.
    /// All members with the same group state derive the same key; it rotates
    /// automatically whenever membership changes (every commit).
    pub fn export_call_key(
        &self,
        member: &GroupMember,
        length: usize,
    ) -> Result<Vec<u8>, E2eError> {
        self.group
            .export_secret(
                member.provider().crypto(),
                "voiid-group-call",
                b"srtp",
                length,
            )
            .map_err(|_| E2eError::Serialization)
    }
}
