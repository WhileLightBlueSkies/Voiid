# Voiid E2E Core — Security Notes & Pre-Audit Checklist

This crate is a tested, working foundation — **not** an audited messenger. Crypto
fails silently: code can pass every test and still be insecure. Get an
independent cryptographic review before real users depend on it. This document
states the threat model, what is and isn't covered, and what an auditor should
examine.

## What this provides

| Capability | Mechanism | Library |
|---|---|---|
| 1:1 messages | Double Ratchet (classic X25519) | vodozemac 0.10 (Apache-2.0) |
| Media (image/video/audio) | per-file AES-256-GCM blob, key over ratchet | aes-gcm |
| Group messages | MLS / RFC 9420 | openmls 0.8 (Apache-2.0) |
| Group PQ key agreement | **hybrid X-Wing (X25519 + ML-KEM-768)** | openmls_libcrux_crypto |
| Calls (1:1 + group) | SRTP keys via HKDF from ratchet / MLS exporter | hkdf |
| Identity verification | safety numbers (anti-MITM) | sha2 |

All dependencies are permissively licensed. No AGPL, no libsignal code.

## Threat model

**In scope (defended):**
- A malicious or compromised **relay/backend**: it sees only ciphertext, public
  bundles, and public KeyPackages. It never receives plaintext or private keys.
- Message tampering / forgery: AEAD + MLS authentication reject it.
- Replay of a captured message: ratchet/MLS state rejects it.
- Harvest-now-decrypt-later against **group** traffic: X-Wing PQ KEM.

**Out of scope / NOT defended (must be handled by the app or accepted):**
- **Compromised endpoint device** (malware, stolen unlocked phone). E2EE cannot
  help once the plaintext or private keys are in attacker hands.
- **Unverified identities.** A safety number exists, but the app MUST surface it
  and users MUST compare it. Without verification, a malicious server can MITM.
- **Harvest-now-decrypt-later against 1:1 traffic** — 1:1 is classic X25519 by
  design (see SPEC_NOTES Phase 1). Recorded 1:1 ciphertext is exposed to a
  future quantum adversary.
- **Metadata** (who talks to whom, when, message sizes/timing). This crate
  encrypts content, not metadata.
- **Traffic analysis, denial of service.**

## Known limitations (track these)

1. **1:1 is not post-quantum.** Documented decision; do not hand-roll PQXDH.
2. **X-Wing codepoint `0x004D` is provisional** (no IANA assignment; draft not
   final). Fine because Voiid controls both ends; plan for a migration.
3. **Pickle keys are the app's responsibility.** This crate encrypts session and
   identity state with a 32-byte key the caller supplies. That key MUST be
   stored in the platform secure enclave (iOS Keychain / Android Keystore),
   never on disk in plaintext, never logged.
4. **No signed prekeys / prekey rotation policy** is enforced here — the app must
   rotate and replenish one-time keys and not reuse them.
5. **No forward-secrecy guarantee for media blobs at rest** beyond the per-file
   key; deleting the key (delivered over the ratchet) is what makes a blob
   unrecoverable.
6. **1:1 sessions use Olm `SessionConfig::version_1`**, which truncates the
   per-message MAC to 64 bits (legacy libolm behavior). vodozemac's untruncated
   `version_2` is gated behind the `experimental-session-config` feature and is
   not yet stable. Move to v2 once it stabilizes if libolm interop is not
   required. (Found in adversarial review; tracked, not yet changed.)

## Logging / data-handling rules (enforced in code, verify in review)

- Error types carry **no secrets** — variants are fixed strings, no key material
  or plaintext. (`src/error.rs`, `src/ffi.rs::E2eFfiError`.)
- No `println!`/logging of plaintext, keys, or ciphertext anywhere in `src/`.

## Pre-audit checklist (for the external reviewer)

- [ ] **Nonce uniqueness** in `media.rs`: confirm a fresh random 96-bit nonce
      per encryption and that key+nonce are never reused across blobs.
- [ ] **RNG**: confirm `rand::thread_rng()` is a CSPRNG on every target platform
      (iOS/Android) and that key/nonce/secret generation uses it.
- [ ] **WireMessage type handling** (`session.rs`): confirm a forged/mismatched
      `msg_type` cannot cause type confusion or a bogus session.
- [ ] **KeyPackage validation** (`group.rs::add_member`): we call
      `KeyPackageIn::validate` before adding — confirm this is sufficient and
      that signature/credential checks aren't bypassable.
- [ ] **Ciphersuite pinning**: confirm group, key package, and create-config all
      agree on X-Wing and that a downgrade to classic can't be forced by a peer.
- [ ] **Safety number** (`verify.rs`): review the iterated-hash construction,
      symmetry, and decimal encoding for collisions / truncation bias. Consider
      replacing with a vetted fingerprint library before production.
- [ ] **Pickle round-trip**: confirm wrong-key restore fails closed (tested) and
      that pickles contain no unencrypted secrets.
- [ ] **FFI boundary** (`ffi.rs`): confirm `Mutex` poisoning, `Arc` sharing, and
      the `unwrap()`s on lock acquisition can't be triggered into a panic that
      crosses the boundary unsafely.
- [ ] **Group exporter → SRTP** (`call.rs`): review the HKDF labels/lengths and
      that the same key can't be derived by a non-member.
- [ ] **Memory hygiene**: consider zeroizing key material (`zeroize`) — currently
      relies on the underlying libraries' own zeroization.

## Test coverage today

47 unit/integration tests + 3 soak tests (`--ignored`). Coverage: messaging
round-trips, media, groups (PQ), calls, verification; negative cases (tampering,
replay, bad keys, wrong pickle key, non-prekey bootstrap rejection); protocol
edge cases (out-of-order delivery, prekey exhaustion/replenishment, multi-device
fan-out, group remove/re-add + lockout, concurrent commits / stale-commit
rejection); PQ prekey round-trip; ~17k-input randomized robustness (no-panic)
sweep across all decrypt entry points; and soak runs (20k 1:1 msgs, 10k group
msgs with churn, 2k media blobs). Plus libFuzzer targets under `fuzz/`.

These demonstrate correct behavior and correct *failure* under load and hostile
input — but do NOT substitute for an independent cryptographic audit.
