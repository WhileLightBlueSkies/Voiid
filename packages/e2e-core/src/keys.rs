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
    /// The current fallback key (base64) as last handed out in a bundle.
    ///
    /// vodozemac's `Account::fallback_key()` returns only keys that are still
    /// UNPUBLISHED, so it goes empty as soon as we mark the bundle published —
    /// even though the key is live and the backend is serving it. We keep our
    /// own copy so `current_fallback_key` reflects what peers can actually fetch.
    /// Public material only; the private half stays inside `account`.
    published_fallback_key: Option<String>,
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
    /// The current **fallback key** (base64), if one is unpublished.
    ///
    /// This is the X3DH "signed prekey" role: unlike a one-time key it is NOT
    /// consumed by use, so a sender can always start a session even when every
    /// one-time key has been claimed. `None` means there is no NEW fallback key
    /// to upload — the previously published one is still current, not that the
    /// device has none. See [`IdentityKeys::rotate_fallback_key`].
    pub fallback_key: Option<String>,
}

impl IdentityKeys {
    /// Generate a brand-new identity. Call once per device install.
    pub fn generate() -> Self {
        Self {
            account: Account::new(),
            published_fallback_key: None,
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

        // Ensure a fallback key exists on first publish. Without one, a peer
        // whose one-time keys are all consumed simply cannot reach us.
        if !self.has_fallback_key() {
            self.account.generate_fallback_key();
        }

        let identity_key = self.account.curve25519_key().to_base64();
        let signing_key = self.account.ed25519_key().to_base64();
        let one_time_keys = self
            .account
            .one_time_keys()
            .values()
            .map(|k| k.to_base64())
            .collect();
        let fallback_key = self
            .account
            .fallback_key()
            .values()
            .next()
            .map(|k| k.to_base64());

        self.account.mark_keys_as_published();
        if fallback_key.is_some() {
            self.published_fallback_key = fallback_key.clone();
        }

        PublicBundle {
            identity_key,
            signing_key,
            one_time_keys,
            fallback_key,
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

    /// Rotate the **fallback key** (the X3DH "signed prekey" role) and return the
    /// bundle carrying the new one.
    ///
    /// The fallback key is what a sender uses when all of our published one-time
    /// keys have been consumed. It is NOT consumed by use, so it keeps us
    /// reachable indefinitely — but because many senders may share it, it gives
    /// weaker forward secrecy than a one-time key. That trade is why it is a
    /// *fallback*: the server should hand out a one-time key whenever it has one
    /// and only fall back to this when the supply is empty.
    ///
    /// Rotate on a schedule (Signal rotates roughly weekly). vodozemac retains
    /// the PREVIOUS fallback key as well as the current one, so sessions started
    /// against the old key still open while it is in flight. Call
    /// [`forget_previous_fallback_key`](Self::forget_previous_fallback_key) one
    /// full rotation later to drop it for forward secrecy.
    pub fn rotate_fallback_key(&mut self) -> PublicBundle {
        self.account.generate_fallback_key();

        let identity_key = self.account.curve25519_key().to_base64();
        let signing_key = self.account.ed25519_key().to_base64();
        let fallback_key = self
            .account
            .fallback_key()
            .values()
            .next()
            .map(|k| k.to_base64());

        self.account.mark_keys_as_published();
        self.published_fallback_key = fallback_key.clone();

        PublicBundle {
            identity_key,
            signing_key,
            // Rotation publishes only the fallback key; one-time key supply is
            // managed separately by `replenish`.
            one_time_keys: Vec::new(),
            fallback_key,
        }
    }

    /// Whether this device currently holds a usable fallback key.
    ///
    /// True once the key exists, whether or not it is still unpublished — a
    /// published fallback key is the normal steady state.
    pub fn has_fallback_key(&self) -> bool {
        self.current_fallback_key().is_some()
    }

    /// The current fallback key (base64), published or not. `None` before the
    /// first `public_bundle`/`rotate_fallback_key` call.
    pub fn current_fallback_key(&self) -> Option<String> {
        self.account
            .fallback_key()
            .values()
            .next()
            .map(|k| k.to_base64())
            .or_else(|| self.published_fallback_key.clone())
    }

    /// Drop the PREVIOUS fallback key, so sessions can no longer be established
    /// against it.
    ///
    /// Call this one full rotation interval after `rotate_fallback_key` — early
    /// enough to bound the window, late enough that in-flight first messages
    /// against the old key still open. Returns whether a key was actually
    /// forgotten.
    pub fn forget_previous_fallback_key(&mut self) -> bool {
        self.account.forget_fallback_key()
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
            // Restored identities re-publish on next bundle; see `restore_fallback_key`.
            published_fallback_key: None,
        })
    }

    /// Re-attach the fallback key this device previously published, after
    /// restoring from a pickle.
    ///
    /// The private half survives the pickle automatically — vodozemac stores it
    /// — so sessions against it already open without this call. This only
    /// restores the PUBLIC value that `current_fallback_key` reports, for apps
    /// that persist the published bundle alongside the pickle. Without it, the
    /// next `public_bundle` call generates a fresh fallback key, which is safe
    /// but rotates earlier than the schedule intends.
    pub fn restore_fallback_key(&mut self, fallback_key_b64: &str) {
        self.published_fallback_key = Some(fallback_key_b64.to_string());
    }

    pub(crate) fn account(&self) -> &Account {
        &self.account
    }

    pub(crate) fn account_mut(&mut self) -> &mut Account {
        &mut self.account
    }
}
