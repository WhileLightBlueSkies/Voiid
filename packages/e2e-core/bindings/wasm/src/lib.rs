//! Browser bindings over the SAME Olm/media sources shipped on iOS and Android.
//! No native UniFFI, recovery/PIN or call APIs are exposed to the companion.
#[path = "../../../src/error.rs"]
mod error;
#[path = "../../../src/keys.rs"]
mod keys;
#[path = "../../../src/media.rs"]
mod media;
#[path = "../../../src/session.rs"]
mod session;

use keys::IdentityKeys;
use session::{Session, WireMessage};
use wasm_bindgen::prelude::*;

fn failure(_: impl std::fmt::Display) -> JsValue {
    JsValue::from_str("Encryption operation failed")
}
fn key(bytes: &[u8]) -> Result<[u8; 32], JsValue> {
    bytes
        .try_into()
        .map_err(|_| JsValue::from_str("Invalid storage key"))
}
fn wire(text: &str) -> Result<WireMessage, JsValue> {
    if text.len() > 2 * 1024 * 1024 {
        return Err(failure("size"));
    }
    let message: WireMessage = serde_json::from_str(text).map_err(failure)?;
    if message.msg_type > 1 {
        return Err(failure("type"));
    }
    Ok(message)
}

#[wasm_bindgen]
pub struct WebIdentity {
    inner: IdentityKeys,
}
#[wasm_bindgen]
impl WebIdentity {
    #[wasm_bindgen(constructor)]
    pub fn new() -> Self {
        Self {
            inner: IdentityKeys::generate(),
        }
    }
    pub fn restore(pickle: &str, storage_key: &[u8]) -> Result<WebIdentity, JsValue> {
        if pickle.len() > 2 * 1024 * 1024 {
            return Err(failure("size"));
        }
        Ok(Self {
            inner: IdentityKeys::from_pickle(pickle, &key(storage_key)?).map_err(failure)?,
        })
    }
    pub fn export_encrypted(&self, storage_key: &[u8]) -> Result<String, JsValue> {
        Ok(self.inner.to_pickle(&key(storage_key)?))
    }
    pub fn publish_bundle(&mut self, count: u32) -> Result<String, JsValue> {
        if count > 100 {
            return Err(failure("count"));
        }
        serde_json::to_string(&self.inner.public_bundle(count as usize)).map_err(failure)
    }
    pub fn fingerprint(&self) -> String {
        self.inner.fingerprint()
    }
    pub fn initiate(&self, identity_key: &str, prekey: &str) -> Result<WebSession, JsValue> {
        Ok(WebSession {
            inner: Session::initiate(&self.inner, identity_key, prekey).map_err(failure)?,
        })
    }
    pub fn accept(
        &mut self,
        identity_key: &str,
        message: &str,
    ) -> Result<AcceptedSession, JsValue> {
        let (session, plaintext) =
            Session::from_first_message(&mut self.inner, identity_key, &wire(message)?)
                .map_err(failure)?;
        Ok(AcceptedSession {
            session: Some(WebSession { inner: session }),
            plaintext,
        })
    }
}

#[wasm_bindgen]
pub struct WebSession {
    inner: Session,
}
#[wasm_bindgen]
impl WebSession {
    pub fn restore(pickle: &str, storage_key: &[u8]) -> Result<WebSession, JsValue> {
        if pickle.len() > 2 * 1024 * 1024 {
            return Err(failure("size"));
        }
        Ok(Self {
            inner: Session::from_pickle(pickle, &key(storage_key)?).map_err(failure)?,
        })
    }
    pub fn export_encrypted(&self, storage_key: &[u8]) -> Result<String, JsValue> {
        Ok(self.inner.to_pickle(&key(storage_key)?))
    }
    pub fn id(&self) -> String {
        self.inner.session_id()
    }
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<String, JsValue> {
        if plaintext.len() > 1024 * 1024 {
            return Err(failure("size"));
        }
        serde_json::to_string(&self.inner.encrypt(plaintext).map_err(failure)?).map_err(failure)
    }
    pub fn decrypt(&mut self, message: &str) -> Result<Vec<u8>, JsValue> {
        self.inner.decrypt(&wire(message)?).map_err(failure)
    }
}

#[wasm_bindgen]
pub struct AcceptedSession {
    session: Option<WebSession>,
    plaintext: Vec<u8>,
}
#[wasm_bindgen]
impl AcceptedSession {
    pub fn take_session(&mut self) -> Result<WebSession, JsValue> {
        self.session.take().ok_or_else(|| failure("consumed"))
    }
    pub fn plaintext(&self) -> Vec<u8> {
        self.plaintext.clone()
    }
}

#[wasm_bindgen]
pub fn prekey_session_id(message: &str) -> Result<Option<String>, JsValue> {
    Ok(wire(message)?.prekey_session_id())
}

#[wasm_bindgen]
pub fn encrypt_media(plaintext: &[u8]) -> Result<String, JsValue> {
    if plaintext.len() > 32 * 1024 * 1024 {
        return Err(failure("size"));
    }
    let encrypted = media::encrypt_media(plaintext).map_err(failure)?;
    serde_json::to_string(&serde_json::json!({
        "ciphertext": encrypted.ciphertext, "media_key": encrypted.media_key
    }))
    .map_err(failure)
}
#[wasm_bindgen]
pub fn decrypt_media(media_key: &str, ciphertext: &[u8]) -> Result<Vec<u8>, JsValue> {
    if ciphertext.len() > 32 * 1024 * 1024 + 64 {
        return Err(failure("size"));
    }
    media::decrypt_media(
        &serde_json::from_str(media_key).map_err(failure)?,
        ciphertext,
    )
    .map_err(failure)
}
