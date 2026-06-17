//! Multi-device tests: a user with several devices, fan-out send.

use voiid_e2e_core::{api, DeviceFanout};

/// Bob has two devices. Alice fans a message out to both; each device decrypts
/// it independently with its own session.
#[test]
fn fan_out_to_two_devices() {
    // Bob's two devices, each its own identity + bundle.
    let mut bob_phone = api::create_identity();
    let phone_bundle = api::publish_bundle(&mut bob_phone, 1);
    let mut bob_laptop = api::create_identity();
    let laptop_bundle = api::publish_bundle(&mut bob_laptop, 1);

    // Alice establishes a session with each device and registers them.
    let mut alice = api::create_identity();
    let alice_bundle = api::publish_bundle(&mut alice, 1);

    let phone_session =
        api::start_session(&alice, &phone_bundle.identity_key, &phone_bundle.one_time_keys[0])
            .unwrap();
    let laptop_session =
        api::start_session(&alice, &laptop_bundle.identity_key, &laptop_bundle.one_time_keys[0])
            .unwrap();

    let mut fanout = DeviceFanout::new();
    fanout.add_device("bob-phone", phone_session);
    fanout.add_device("bob-laptop", laptop_session);
    assert_eq!(fanout.device_count(), 2);

    // One logical send -> two ciphertexts, one per device.
    let outgoing = fanout.encrypt(b"hello all your devices").unwrap();
    assert_eq!(outgoing.len(), 2);

    // Route each ciphertext to the right device; both decrypt the same plaintext.
    for dm in &outgoing {
        let (mut device, pt) = match dm.device_id.as_str() {
            "bob-phone" => {
                api::accept_session(&mut bob_phone, &alice_bundle.identity_key, &dm.message).unwrap()
            }
            "bob-laptop" => {
                api::accept_session(&mut bob_laptop, &alice_bundle.identity_key, &dm.message)
                    .unwrap()
            }
            other => panic!("unexpected device {other}"),
        };
        assert_eq!(pt, b"hello all your devices");
        let _ = &mut device;
    }
}

/// Decrypting for an unknown device id fails rather than silently misrouting.
#[test]
fn unknown_device_errors() {
    let mut bob = api::create_identity();
    let bob_bundle = api::publish_bundle(&mut bob, 1);
    let mut alice = api::create_identity();
    let _ = api::publish_bundle(&mut alice, 1);
    let session =
        api::start_session(&alice, &bob_bundle.identity_key, &bob_bundle.one_time_keys[0]).unwrap();

    let mut fanout = DeviceFanout::new();
    fanout.add_device("known", session);
    let msgs = fanout.encrypt(b"x").unwrap();

    assert!(fanout.decrypt("unknown-device", &msgs[0].message).is_err());
}
