//! Test-only JSON bridge to the unmodified native modules used by iOS and Android.
#[path = "../../../src/error.rs"]
mod error;
#[path = "../../../src/keys.rs"]
mod keys;
#[path = "../../../src/media.rs"]
mod media;
#[path = "../../../src/session.rs"]
mod session;
use keys::IdentityKeys;
use serde_json::{json, Value};
use session::{Session, WireMessage};
use std::io::{self, Read};
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let v: Value = serde_json::from_str(&input).unwrap();
    let key = [7u8; 32];
    let s = |name: &str| v[name].as_str().unwrap();
    let output = match s("op") {
        "new" => {
            let mut id = IdentityKeys::generate();
            let bundle = id.public_bundle(3);
            json!({"identity": id.to_pickle(&key), "bundle": bundle})
        }
        "accept" => {
            let mut id = IdentityKeys::from_pickle(s("identity"), &key).unwrap();
            let wire: WireMessage = serde_json::from_str(s("wire")).unwrap();
            let (mut session, text) =
                Session::from_first_message(&mut id, s("peer"), &wire).unwrap();
            let reply = session.encrypt(s("reply").as_bytes()).unwrap();
            json!({"text": String::from_utf8(text).unwrap(), "wire": serde_json::to_string(&reply).unwrap(), "session": session.to_pickle(&key), "identity": id.to_pickle(&key)})
        }
        "initiate" => {
            let id = IdentityKeys::from_pickle(s("identity"), &key).unwrap();
            let mut session = Session::initiate(&id, s("peer"), s("prekey")).unwrap();
            let wire = session.encrypt(s("text").as_bytes()).unwrap();
            json!({"wire": serde_json::to_string(&wire).unwrap(), "session": session.to_pickle(&key)})
        }
        "decrypt" => {
            let mut session = Session::from_pickle(s("session"), &key).unwrap();
            let text = session
                .decrypt(&serde_json::from_str(s("wire")).unwrap())
                .unwrap();
            json!({"text": String::from_utf8(text).unwrap(), "session": session.to_pickle(&key)})
        }
        "media-decrypt" => {
            let bytes: Vec<u8> = serde_json::from_value(v["ciphertext"].clone()).unwrap();
            let key = serde_json::from_value(v["media_key"].clone()).unwrap();
            json!({"plaintext": media::decrypt_media(&key, &bytes).unwrap()})
        }
        "media-encrypt" => {
            let value = media::encrypt_media(s("text").as_bytes()).unwrap();
            json!({"ciphertext": value.ciphertext, "media_key": value.media_key})
        }
        _ => panic!("unknown test operation"),
    };
    println!("{}", output);
}
