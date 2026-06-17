use serde::{Deserialize, Serialize};
use vodozemac::olm::{Account, AccountPickle};

use crate::error::E2eError;

/// A device's long-term identity plus its one-time prekeys.
///
/// The private half NEVER leaves the device. `public_bundle()` returns only the
/// public material that the backend distributes so other devices can start a
/// session with us.
pub struct IdentityKeys {
    account: Account,
}

/// Public-only material published to the backend for others to fetch.
/// Contains NO private keys.
#[derive(Clone, Serialize, Deserialize)]
pub struct PublicBundle {
    /// Long-term Curve25519 identity key (base64).
    pub identity_key: String,
    /// Ed25519 signing key (base64) — used to verify the bundle / safety number.
    pub signing_key: String,
    /// Unpublished one-time prekeys (base64), each consumed by one new session.
    pub one_time_keys: Vec<String>,
}

impl IdentityKeys {
    /// Generate a brand-new identity. Call once per device install.
    pub fn generate() -> Self {
        Self {
            account: Account::new(),
        }
    }

    /// The stable Ed25519 fingerprint (base64) used for safety-number / identity
    /// verification. Safe to log and display.
    pub fn fingerprint(&self) -> String {
        self.account.ed25519_key().to_base64()
    }

    /// Top up one-time prekeys and return the public bundle to upload.
    ///
    /// After uploading, the caller should treat these keys as published; we call
    /// `mark_keys_as_published` so the same keys aren't handed out twice.
    pub fn public_bundle(&mut self, count: usize) -> PublicBundle {
        self.account.generate_one_time_keys(count);

        let identity_key = self.account.curve25519_key().to_base64();
        let signing_key = self.account.ed25519_key().to_base64();
        let one_time_keys = self
            .account
            .one_time_keys()
            .values()
            .map(|k| k.to_base64())
            .collect();

        self.account.mark_keys_as_published();

        PublicBundle {
            identity_key,
            signing_key,
            one_time_keys,
        }
    }

    /// Generate and publish `count` ADDITIONAL one-time keys, returning a bundle
    /// containing only the newly-created keys to upload.
    ///
    /// Each inbound session a peer establishes with us consumes one published
    /// one-time key on our device. If they all get consumed, new senders can't
    /// start a session until we replenish — so the app should call this
    /// periodically (e.g. when the server reports our remaining count is low,
    /// or on a schedule). Identity/signing keys are unchanged across calls.
    pub fn replenish(&mut self, count: usize) -> PublicBundle {
        // public_bundle already generates `count` new keys, returns only the
        // unpublished (i.e. new) ones, and marks them published.
        self.public_bundle(count)
    }

    /// The maximum number of one-time keys this device can hold at once. The app
    /// should keep the server-side published+unconsumed count comfortably below
    /// this and replenish toward it, never request more than this in one call.
    pub fn max_one_time_keys(&self) -> usize {
        self.account.max_number_of_one_time_keys()
    }

    /// Persist this identity to encrypted device storage (e.g. Keychain /
    /// Keystore). The pickle is itself encrypted with a device-held key.
    pub fn to_pickle(&self, pickle_key: &[u8; 32]) -> String {
        self.account.pickle().encrypt(pickle_key)
    }

    /// Restore a previously persisted identity.
    pub fn from_pickle(pickle: &str, pickle_key: &[u8; 32]) -> Result<Self, E2eError> {
        let pickle =
            AccountPickle::from_encrypted(pickle, pickle_key).map_err(|_| E2eError::InvalidKey)?;
        Ok(Self {
            account: Account::from_pickle(pickle),
        })
    }

    pub(crate) fn account(&self) -> &Account {
        &self.account
    }

    pub(crate) fn account_mut(&mut self) -> &mut Account {
        &mut self.account
    }
}
