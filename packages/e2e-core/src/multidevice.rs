//! Multi-device support (1:1).
//!
//! In the Signal model there is no "user key" — each **device** has its own
//! identity and its own pairwise sessions. A user with N devices is N
//! identities, each publishing its own bundle. To message a user you hold one
//! [`Session`](crate::Session) per recipient device and **fan out**: encrypt the
//! same plaintext once per device session, producing one ciphertext per device.
//! Your own other devices are just additional recipients (so they stay in sync).
//!
//! The crypto core already makes each session independent; this is a thin
//! convenience layer for addressing a set of device sessions at once. The app
//! owns the device list / session storage and routes each ciphertext to the
//! right device via the relay.

use crate::error::E2eError;
use crate::session::{Session, WireMessage};

/// One outbound ciphertext addressed to a specific recipient device.
pub struct DeviceMessage {
    /// Opaque device identifier the app uses for routing (e.g. device id).
    pub device_id: String,
    pub message: WireMessage,
}

/// A set of established sessions, one per recipient device. Encrypting fans the
/// plaintext out to every device.
#[derive(Default)]
pub struct DeviceFanout {
    devices: Vec<(String, Session)>,
}

impl DeviceFanout {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register an established session for one recipient device.
    pub fn add_device(&mut self, device_id: impl Into<String>, session: Session) {
        self.devices.push((device_id.into(), session));
    }

    /// Number of devices currently addressed.
    pub fn device_count(&self) -> usize {
        self.devices.len()
    }

    /// Encrypt `plaintext` once per device, yielding one ciphertext per device.
    /// If any single device fails to encrypt, the whole fan-out errors (so the
    /// caller never sends a partial set that would desync some devices).
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<DeviceMessage>, E2eError> {
        let mut out = Vec::with_capacity(self.devices.len());
        for (device_id, session) in &mut self.devices {
            let message = session.encrypt(plaintext)?;
            out.push(DeviceMessage {
                device_id: device_id.clone(),
                message,
            });
        }
        Ok(out)
    }

    /// Decrypt a message that arrived for a specific device session.
    pub fn decrypt(&mut self, device_id: &str, message: &WireMessage) -> Result<Vec<u8>, E2eError> {
        let session = self
            .devices
            .iter_mut()
            .find(|(id, _)| id == device_id)
            .map(|(_, s)| s)
            .ok_or(E2eError::NoSession)?;
        session.decrypt(message)
    }
}
