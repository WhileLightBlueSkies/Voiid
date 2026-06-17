# Voiid E2EE — Spec-Driven Implementation Plan

This is the build guide for Voiid's end-to-end encryption. Everything here is
implemented **from public specifications and permissively-licensed libraries**.

## Provenance rules (read first)

- ✅ Learn from: the public specs linked below + the chosen libraries' own docs.
- 🚫 Do **not** read libsignal's source as a reference for Voiid. The flow we
  need is fully described in the public specs — that is what makes the result
  truly E2EE, not anyone's source code.
- ✅ Our own code, permissive deps only → closed-source is clean and defensible.

## Library choices (all permissive — no AGPL, no libsignal)

| Concern | Library | License |
|---|---|---|
| 1:1 double ratchet | `vodozemac` | Apache-2.0 |
| Group messaging/calls (MLS) | `openmls` | Apache-2.0 |
| Symmetric blob crypto (media) | `aes-gcm` / libsodium | Apache-2.0 / ISC |
| Live media transport | WebRTC (SRTP) | BSD |

---

## Phase 1 — 1:1 messages  (✅ scaffolded)

**Specs:**
- X3DH — https://signal.org/docs/specifications/x3dh/
- PQXDH (post-quantum X3DH) — https://signal.org/docs/specifications/pqxdh/
- Double Ratchet — https://signal.org/docs/specifications/doubleratchet/

**Maps to:** `src/keys.rs`, `src/session.rs`, `src/api.rs` (vodozemac).

**Flow:**
1. Each device `create_identity()` → uploads `publish_bundle()` (public only).
2. Sender fetches peer bundle → `start_session()` → `encrypt()`.
3. Receiver `accept_session()` on first message → `encrypt()/decrypt()` after.

### Post-quantum status (1:1)  — ⚠️ classic, by design

vodozemac (≤0.10) implements the **classic** X25519 double ratchet, **not**
PQXDH. There is no upstream PQ effort in vodozemac to wait for, and hand-rolling
a PQXDH-equivalent handshake into Olm is the single biggest crypto footgun for a
small team (Signal's PQXDH needed formal analysis to validate).

**Decision:** ship classic 1:1 now; do **not** hand-roll PQXDH. The exposure is
"harvest-now-decrypt-later" against *recorded* 1:1 traffic — a future threat to
today's ciphertext, not an active-attack risk. When we add PQ to 1:1, we will
adopt an **already-analyzed** construction (X-Wing-as-KEM combined into the
handshake, or the published PQXDH spec implemented faithfully) built on a
permissive, FIPS-203 ML-KEM crate (`ml-kem` RustCrypto, Apache/MIT) or the
formally-verified `libcrux-ml-kem` (Apache-2.0) — and budget an external review
of that specific handshake. The wire format (`WireMessage`) already carries a
type tag, leaving room for a future versioned PQ handshake message.

> Note: **groups already have post-quantum protection today** (see Phase 3) via
> MLS's hybrid X-Wing ciphersuite. The gap is 1:1 only.

**Scaffold status (`src/pqxdh.rs`):** ML-KEM-768 (FIPS 203, RustCrypto `ml-kem`,
Apache/MIT) **prekey** generation + encapsulate/decapsulate round-trip are
implemented and tested behind the default-on `pq-1to1-prekeys` feature. A device
can publish a PQ prekey and a sender can derive a PQ shared secret to it. The
live handshake **combiner** (mixing that secret into Olm's session keys) is
behind the `pq-1to1-activate` feature, which `compile_error!`s until an external
cryptographic review signs off — so the bespoke part cannot ship by accident.

---

## Phase 2 — Media (images / video / audio files)  (✅ implemented — `src/media.rs`)

**You never ratchet large blobs.** Pattern (same as Signal/WhatsApp):

1. Generate a random **AES-256-GCM** key per attachment.
2. Encrypt the file locally → upload **ciphertext** to storage. Backend never
   sees plaintext.
3. Send `{ blobKey, nonce, sha256, url }` as a normal Phase-1 E2EE message.
4. Recipient fetches blob, verifies hash, decrypts.

**Maps to:** new `src/media.rs` (AES-GCM). Keys travel over the ratchet; blobs
travel as opaque ciphertext.

---

## Phase 3 — Groups (messages + group media) — **MLS / OpenMLS**  (✅ implemented — `src/group.rs`)

**Spec:** RFC 9420 (Messaging Layer Security) —
https://www.rfc-editor.org/rfc/rfc9420.html
**Library:** `openmls` 0.8 (Apache-2.0) + `openmls_libcrux_crypto` provider.

**Why MLS:** scales to large/dynamic groups, post-compromise security, and
exposes an **exporter secret** we reuse to key group calls (Phase 4).

**Post-quantum (✅ active for groups):** we use the hybrid
`MLS_256_XWING_CHACHA20POLY1305_SHA256_Ed25519` ciphersuite — X25519 + ML-KEM-768
(X-Wing) — so group key agreement resists harvest-now-decrypt-later. The ML-KEM
comes from Cryspen's formally-verified **libcrux** (we hand-roll no PQ crypto).
This requires the **libcrux provider** — the RustCrypto provider does NOT support
X-Wing. CAVEAT: codepoint `0x004D` is provisional (no assigned IANA codepoint;
X-Wing draft not finalized). Safe here because Voiid controls both endpoints, but
a future codepoint/draft change may require a migration.

**Flow:**
1. Each device publishes an MLS **KeyPackage** (public) to the backend.
2. Group creator builds a group, adds members via their KeyPackages.
3. Application messages encrypted to the group via MLS; media uses the Phase-2
   blob pattern but with the blob key sent over MLS instead of the ratchet.
4. Membership changes (add/remove) rekey the group automatically.

**Maps to:** new `src/group.rs` wrapping openmls. Keep `api.rs` additions flat:
`create_key_package`, `create_group`, `add_member`, `group_encrypt`,
`group_decrypt`, `process_commit`.

---

## Phase 4 — Calls & group calls (live audio/video)  (✅ key derivation implemented — `src/call.rs`; WebRTC wiring lives in the app)

**Transport:** WebRTC; live media encrypted with **SRTP**. "E2EE" = *we* own
the SRTP key, not a server.

**Keying:**
- 1:1 call: derive the SRTP master key from a Phase-1 ratchet message
  (exchange a random call key over the encrypted channel).
- Group call: derive per-call keys from the **MLS exporter secret** (Phase 3),
  so call membership == group membership and rekeys on membership change.
- For browsers later: WebRTC **Insertable Streams / SFrame** lets you E2EE media
  even through an SFU (server forwards encrypted frames it cannot read).

**Maps to:** mostly app/native + signaling layer (`backend/signaling`), with
`e2e-core` providing the key-derivation helpers.

> Group-call E2EE is the hardest piece even for mature apps. MLS exporter
> secrets give a clean key source; budget real time for the SFrame/SFU work.

---

## Cross-cutting rules

- **Private keys never cross the FFI boundary toward the backend.** Backend is a
  relay: ciphertext + public bundles/KeyPackages only.
- **Persist ratchet/group state** (encrypted pickles) so sessions survive
  restarts.
- **Add identity verification** (safety numbers / key fingerprints) before
  shipping — encryption without verification is open to MITM.
- **Primary tests in Rust**, smoke tests per binding.

## ⚠️ Before production

Independent security audit of: key management, the verification flow,
persistence keys, media blob handling, and group/call keying. Crypto fails
silently — do not ship to real users unaudited.
