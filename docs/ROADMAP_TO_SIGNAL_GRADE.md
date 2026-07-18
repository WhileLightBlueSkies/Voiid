# VOIID — roadmap to Signal-grade

**Repo:** `voiid` (the clean-room app — vodozemac + MLS, **no Signal code**)
**Date:** 2026-07-17 · **Owner:** Nehal

> **Strategic note.** There are two repos. `Voiid-Main` is a de-Signaled *fork* of Signal —
> it carries a permanent decompile-attribution risk (the crypto structure is exposed by JNI and
> recognizable to Signal's engineers). **This repo (`voiid`) is the real product**: built from
> scratch on `vodozemac` (Apache-2.0) + OpenMLS (Apache-2.0), it contains **no Signal code**, so
> a decompile reveals nothing to attribute. All forward effort goes here.

---

## 0. The ladder

| Milestone | What it takes |
|---|---|
| **Better than WhatsApp** | Ship Phase 1 (below) + external audit. No SGX needed. |
| **Signal-grade** | Add the Phase 3 enclave layer (SGX CDSI + SVR). |

You can be *better than WhatsApp* first, then climb to *Signal-grade*. WhatsApp's weakness is
metadata / address-book upload / opt-in backups / Meta — all of which Phase 1 already beats.

---

## 1. Locked design decisions

| Area | Decision |
|---|---|
| **1:1 crypto** | `vodozemac` Double Ratchet (Apache-2.0). Keep — don't force MLS into 1:1. |
| **Group crypto** | OpenMLS (RFC 9420) + hybrid post-quantum **X-Wing** ciphersuite (libcrux). |
| **Post-quantum 1:1** | ML-KEM prekeys present; handshake combiner **gated OFF** until external crypto review. Activate post-audit. |
| **Contact discovery** | **Username / link / QR** (Signal-grade private, ships now) **+ phone-number** (WhatsApp-grade now). **SGX CDSI upgrades phone → private in Phase 3.** |
| **PIN recovery** | **PIN (Argon2id + server rate-limit) + mandatory recovery phrase** now. Recovery-phrase = the strong guarantee. **SGX SVR upgrades weak-PIN protection in Phase 3.** |
| **Backups** | E2EE **by default** — server + Google Drive + iCloud, encrypted with a key derived from the master secret. |
| **Enclaves (Phase 3)** | Multi-TEE (SGX + AWS Nitro), not SGX-only — matches Signal's current SVR3. On owned bare-metal (verify SGX-enabled + EPC size first). |

### The recovery/backup key model (how it all ties together)
```
master secret (per account)
   ├── derives message/session keys
   ├── derives backup key ──► encrypts backups (server + Google Drive + iCloud)
   └── recovered by:
         • device has it            → normal case, just decrypt
         • PIN  (Argon2 + rate-limit / later SGX SVR)  → convenience
         • recovery phrase (~128-bit)                  → strong, zero-trust
```

---

## 2. Current state (what exists in this repo)

**Crypto core (`packages/e2e-core`, Rust + uniffi → Swift/Kotlin):** ✅ solid
- `vodozemac` + OpenMLS + `ml-kem`; API: identity, prekeys, sessions, encrypt/decrypt, media, groups, safety numbers.
- PQ 1:1 combiner deliberately unbuildable pending review (responsible).

**Backend (Node, deployed on Vultr `api-dev.voiid.app`):** ✅ substantial
- Routes: `auth, contacts, conversations, devices, linking, media, messages, mls, prekeys, receipts, users`.
- 11 migrations (users, devices, prekeys, otp, conversations, messages, receipts, contact_sync, security_events, username, mls).

**Native apps:** 🟡 `apps/android` (Kotlin) + `apps/ios` (Swift), UI through the 1:1 chat screen; `ChatEngine` wired to e2e-core.

**Known-broken / missing:**
- 🔴 1:1 messaging **buggy** — prekey-count counted per-user not per-device → 2nd device uploads 0 keys → peers hit 409; multidevice receive issues. (Registration base64 hang already fixed, PR #24.)
- 🔴 **No recovery module** in e2e-core (PIN/phrase not built).
- 🔴 **No Google Drive / iCloud backup.**
- 🟡 Groups: MLS in crypto + `mls.ts` route, **app wiring unfinished**.

---

## 3. Phased roadmap

### Phase 0 — make 1:1 rock-solid *(foundation; everything sits on this)*
- Fix **prekey-count per-device** (each device tracks/uploads its own unconsumed keys).
- Fix **multidevice receive** / decryption failures.
- End-to-end test: 2 accounts × 2 devices each, offline delivery, key exhaustion → replenish.
- **Exit:** reliable 1:1 across multi-device, zero 409s, no dropped/undecryptable messages.

### Phase 1 — MVP (**"better than WhatsApp"**)
- **1:1** solid (Phase 0) + read receipts, typing, media/attachments complete.
- **Discovery:** username/link/QR (private) **+** phone-number (hashed, rate-limited — WhatsApp-grade, clearly the convenience path).
- **Recovery:** master secret + PIN (Argon2id + server rate-limit) + **mandatory recovery phrase**.
- **Backups:** E2EE server-side backup (encrypted with backup key), restore-on-new-device flow.
- **Groups:** finish wiring MLS to the app (create/add/remove/message).
- **Exit:** a private, reliable messenger that beats WhatsApp on discovery + backups + business model.

### Phase 2 — cloud backups + calls
- **Google Drive + iCloud** encrypted backups (E2EE by default — beats WhatsApp's opt-in).
- **Voice/video calls** — WebRTC + SFU (LiveKit/mediasoup) + your Cloudflare TURN; signaling backend already exists.
- Media/group polish, disappearing messages, reactions.

### Phase 3 — enclave layer (**"Signal-grade"**)
- **SGX CDSI** — private phone-number discovery (upgrades Phase-1 phone discovery to private).
- **SGX SVR** — makes a *weak* PIN safe against a compromised server.
- **Multi-TEE** (SGX + Nitro), not SGX-only. On owned bare-metal — **first verify** SGX enabled in BIOS + EPC size; CDSI-at-scale may need large-EPC Xeon Scalable.

### Cross-cutting (start now, runs in parallel)
- 🔴 **External crypto audit** — of the e2e-core *integration*. **Book early — long lead times.** This is the single biggest gap between "works" and "Signal-grade."
- **Activate PQ 1:1** (the gated combiner) *after* the audit signs off.
- **Sealed sender** (hide sender from your own server) — optional, would beat both WhatsApp *and* match Signal on metadata.

---

## 4. Security posture

| Dimension | vs WhatsApp | vs Signal |
|---|---|---|
| Message content E2EE | equal | equal |
| Groups | **better** (MLS vs sender keys) | **better** (MLS scaling) |
| Post-quantum | **ahead** (groups; 1:1 after activation) | ahead on PQ groups |
| Contact discovery | **better** (username) / equal (phone, pre-SGX) | equal after Phase 3 |
| Backups | **better** (E2EE default) | equal |
| Metadata / business model | **better** (no Meta, no ad graph) | equal |
| Recovery (weak PIN vs compromised server) | equal | **weaker until Phase 3 SGX** |
| Maturity + external audit | behind (until audit + hardening) | behind (until audit + hardening) |

**Summary:** more private than WhatsApp *by design* today; Signal-grade after the audit + Phase 3 enclaves. The design gap favors VOIID; the maturity/audit gap is the work.

---

## 5. Immediate next step
**Phase 0 — diagnose and fix the exact 1:1 bugs** (prekey-count-per-device + multidevice receive). Everything else is built on reliable 1:1, so it's the first thing. Then Phase 1.
