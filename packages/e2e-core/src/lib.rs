//! Voiid E2E core.
//!
//! This crate is the single source of truth for Voiid's end-to-end encryption.
//! iOS, Android, and (later) the web client all call into THIS code via thin
//! bindings, so encrypt/decrypt logic exists exactly once and cannot drift
//! between platforms.
//!
//! Design notes:
//! - Built on `vodozemac` (Apache-2.0), so Voiid carries no AGPL obligations
//!   and contains no libsignal code.
//! - The architecture mirrors the public Signal Protocol spec (double ratchet
//!   + prekeys). The *design* is public; this *implementation* is our own.
//! - Private keys live only on the device. Nothing here serializes a private
//!   key for transmission to the backend; the backend only ever relays
//!   ciphertext and distributes PUBLIC keys.

mod call;
mod error;
mod group;
mod keys;
mod media;
mod multidevice;
#[cfg(feature = "pq-1to1-prekeys")]
mod pqxdh;
mod session;
mod verify;

pub mod api;
pub mod ffi;

pub use call::{CallSecret, SrtpKeys};
pub use error::E2eError;
pub use group::{AddMemberOutput, GroupMember, GroupSession};
pub use keys::{IdentityKeys, PublicBundle};
pub use media::{EncryptedMedia, MediaKey};
pub use multidevice::{DeviceFanout, DeviceMessage};
#[cfg(feature = "pq-1to1-prekeys")]
pub use pqxdh::PqPrekey;
pub use session::{Session, WireMessage};

// Sets up the uniffi scaffolding for the Swift/Kotlin bindings (UDL-less mode).
uniffi::setup_scaffolding!("voiid");
