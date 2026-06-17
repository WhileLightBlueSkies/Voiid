# @voiid/e2e-core

The **single** end-to-end encryption implementation for Voiid. iOS, Android, and
(later) the web client all call into this one Rust crate via thin bindings, so
encrypt/decrypt logic exists exactly once and cannot drift between platforms.

## Why this design

- **One core, three bindings.** The classic multi-platform E2E failure is three
  separate crypto implementations drifting apart until a message encrypted on
  iOS won't decrypt on Android. A shared core makes that impossible.
- **Permissively licensed.** Built on [`vodozemac`](https://crates.io/crates/vodozemac)
  (Apache-2.0), a Signal-style double-ratchet library. Voiid therefore carries
  **no AGPL obligations and contains no libsignal code** — it can stay closed
  source. We copy the public *Signal Protocol design*, not anyone's source.
- **Keys stay on device.** Private keys never cross the FFI boundary toward the
  backend. The backend is a **relay**: it stores/forwards ciphertext and
  distributes *public* bundles. It never sees plaintext or private keys.

## Layout

```
e2e-core/
├── Cargo.toml
├── src/
│   ├── lib.rs        module wiring + public re-exports
│   ├── error.rs      FFI-safe errors (no secrets in messages)
│   ├── keys.rs       device identity + public bundle (Phase 1)
│   ├── session.rs    1:1 double-ratchet session (Phase 1)
│   ├── media.rs      attachment encryption, AES-256-GCM blobs (Phase 2)
│   ├── group.rs      MLS group messaging via OpenMLS (Phase 3)
│   ├── call.rs       SRTP key derivation for calls (Phase 4)
│   ├── verify.rs     safety-number / MITM verification
│   └── api.rs        flat, binding-friendly facade  ← bindings map onto this
├── tests/            primary E2E tests (Rust) — 13 passing
└── bindings/
    ├── swift/        → apps/ios   (uniffi or C ABI)
    ├── kotlin/       → apps/android
    └── node/         → backend + apps/web (build when web work starts)
```

## What's implemented (all tested, all green)

| Phase | Capability | Built on |
|---|---|---|
| 1 | 1:1 messages (double ratchet) + session persistence | vodozemac 0.10 |
| 2 | Media (images/video/audio) via AES-256-GCM blob + key-over-ratchet | aes-gcm |
| 3 | Group messages (MLS, RFC 9420) + group key export | openmls 0.7 |
| 4 | 1:1 + group call SRTP key derivation | hkdf |
| — | Safety-number identity verification (anti-MITM) | sha2 |

## Public API (what each platform exposes)

Identity & verify: `create_identity` · `identity_fingerprint` · `publish_bundle`
· `safety_number`
1:1 messaging: `start_session` · `accept_session` · `encrypt` · `decrypt`
Media: `encrypt_media` · `decrypt_media`
Calls: `new_call_secret` · `srtp_keys_for_1to1` · `srtp_keys_for_group`
Groups: `GroupMember::{new, key_package, create_group, join_group}` ·
`GroupSession::{add_member, encrypt, decrypt, export_call_key}`

Keep this surface small — a change here is a change in three places.

## Build & test

```bash
cd packages/e2e-core
cargo test     # 13 tests across messaging, media, groups, calls, verification
cargo clippy   # clean
```

## Next steps

1. Pick an FFI generator. [`uniffi`](https://mozilla.github.io/uniffi-rs/) is the
   smoothest for Swift + Kotlin from one definition; `napi-rs` for the Node
   binding later.
2. Generate Swift bindings into `bindings/swift/`, wire into `apps/ios`.
3. Generate Kotlin bindings into `bindings/kotlin/`, wire into `apps/android`.
4. Wire WebRTC: feed `SrtpKeys` into the SRTP layer; for browsers later use
   Insertable Streams / SFrame so an SFU forwards frames it cannot read.
5. Add post-quantum (PQXDH) — see the gap note in `SPEC_NOTES.md`.

## ⚠️ Before production

This is a working skeleton, not an audited messenger. Crypto is unforgiving:
get an independent security review of key management, the verification flow, and
the persistence (pickle) keys before real users rely on it.
