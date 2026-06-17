//! Phase 2 tests: attachment encryption + the key-over-ratchet flow.

use voiid_e2e_core::api;

/// A file encrypts to an opaque blob and decrypts back to the original bytes.
#[test]
fn media_roundtrip() {
    let original = b"pretend this is a 4MB JPEG".repeat(1000);

    let enc = api::encrypt_media(&original).expect("encrypt media");
    // The blob handed to storage must not equal the plaintext.
    assert_ne!(enc.ciphertext, original);

    let decrypted = api::decrypt_media(&enc.media_key, &enc.ciphertext).expect("decrypt media");
    assert_eq!(decrypted, original);
}

/// A swapped/corrupted blob is rejected by the hash check before decryption.
#[test]
fn corrupted_blob_is_rejected() {
    let enc = api::encrypt_media(b"secret photo").unwrap();
    let mut tampered = enc.ciphertext.clone();
    *tampered.last_mut().unwrap() ^= 0xFF;

    assert!(api::decrypt_media(&enc.media_key, &tampered).is_err());
}

/// The full flow: the MediaKey travels over the Phase-1 ratchet, then the
/// recipient uses it to decrypt the separately-fetched blob.
#[test]
fn media_key_over_ratchet() {
    // Establish a 1:1 session (Phase 1).
    let mut alice = api::create_identity();
    let mut bob = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);
    let bob_bundle = api::publish_bundle(&mut bob, 1);
    let otk = bob_bundle.one_time_keys.first().unwrap();
    let mut alice_session = api::start_session(&alice, &bob_bundle.identity_key, otk).unwrap();

    // Alice encrypts a file and sends the MediaKey (as JSON) over the ratchet.
    let enc = api::encrypt_media(b"hello in a file").unwrap();
    let key_json = serde_json::to_vec(&enc.media_key).unwrap();
    let wire = api::encrypt(&mut alice_session, &key_json).unwrap();

    // Bob receives the message, recovers the MediaKey, fetches the blob, decrypts.
    let (mut _bob_session, received_json) =
        api::accept_session(&mut bob, &alice_bundle.identity_key, &wire).unwrap();
    let media_key: voiid_e2e_core::MediaKey = serde_json::from_slice(&received_json).unwrap();

    let file = api::decrypt_media(&media_key, &enc.ciphertext).unwrap();
    assert_eq!(file, b"hello in a file");
}
