# VOIID — Phased Build Plan

> Working plan derived from `VOIID_MASTER_SPEC_COMPLETE.md` (v2.0).
> Source of truth for *what we build, in what order*. Track progress in `CHECKLIST.md`.
> Last updated: 2026-06-15

---

## Guiding principles (apply to every phase)

- **E2E is foundational from day 1.** The server only ever stores/relays **ciphertext**. We build the device + prekey + key-distribution infrastructure starting Phase 0. The libsignal crypto layer is **wired in Phase 2** — and only after the AGPL licensing block is cleared (see below). Until then, Phase 0/1 use placeholder ciphertext payloads, but the data model and relay treat everything as opaque bytes — never plaintext.
- **Layer by layer.** 1:1 before group. Messaging solid before modules. Stop at every review gate.
- **Portability.** Every external dependency sits behind an interface (DB, storage, realtime, SMS/OTP, compute). "Migrate at scale" = swap one implementation.
- **Boundaries.** Supabase = Postgres host only (NOT Supabase Auth, NOT Supabase Realtime). Firebase = OTP sender only (NOT identity). Auth + JWT + identity are ours.
- **Design first.** Tokens in `packages/design-tokens` → codegen to all platforms. No hand-synced hex.

---

## 🔴 Blocking pre-conditions (resolve before the named phase)

| # | Blocker | Gate | Status |
|---|---|---|---|
| 1 | **libsignal AGPL-3.0 licensing** — confirm linking/distribution terms for closed commercial use with a lawyer, OR pick a permissive Signal Protocol impl, OR get alternative terms from Signal Foundation. | **BEFORE PHASE 2** (E2E crypto layer) | ⛔ OPEN |
| 2 | **Design tokens / Figma** — confirm "derived → confirm" tokens (Section 6); link Figma if it exists. | BEFORE PHASE 1 client | ⛔ OPEN |
| 3 | **OTP cost** — confirm Firebase India SMS pricing/quota; line up MSG91 as swap. | BEFORE PHASE 1 | ⛔ OPEN |
| 4 | **Font licensing** — confirm SF Pro distribution rights (Android/Web); pick fallback. | BEFORE PHASE 1 client | ⛔ OPEN |

---

## Phase 0 — Backend Foundation  *(no UI)*
**Goal:** Running backend on Vultr; Supabase Postgres + Redis live; ciphertext relay backbone working; minimal ops.

**Services (`backend/`):** `api` (HTTP), `websocket` (realtime relay), `signaling` (stub for now), `workers`, `admin-api` (stub). All Dockerized.

**Build sub-steps:**
1. Monorepo + Docker Compose (api, websocket, redis) + env strategy (dev/staging/prod).
2. DB migrations `001…009` (users, devices, prekey_bundles, otp_sessions, conversations, conversation_members, messages, message_read_receipts, contact_sync) — run via Supabase CLI.
3. Auth: OTP request/verify (Firebase sender behind swappable SMS interface) → our user upsert in Supabase → our JWT. OTP stored as **hash only**.
4. Devices + prekeys: register device, upload public prekey bundle, distribute (consume one-time prekey), refresh.
5. Messaging relay: store ciphertext → PUBLISH to recipient Redis channel → push down WS; offline → DB → `GET /messages/pending`.
6. Redis: presence (TTL+heartbeat), last_seen, typing (TTL 5s), pub/sub `channel:user:{id}` / `channel:conversation:{id}`, rate-limit + cache keys.
7. Ops: health endpoints, Sentry, Uptime Kuma.

**Done = Phase 0 review gate in `CHECKLIST.md` fully checked.**

---

## Phase 1 — Onboarding & Auth  *(design system live)*
Splash → Permissions (all upfront) → Login (phone, +91 default) → OTP (6-field) → Profile (full name + email) → Contact sync (local match, never upload) → Chat list.
Per platform: iOS (SwiftUI/Keychain/PHPicker/Contacts), Android (Compose/Keystore/MediaStore/ContentResolver), Web (React/secure token/Permissions API).
`packages/design-tokens` consumed natively on all platforms.

---

## Phase 2 — 1:1 Messaging (Core)  *(libsignal wired — licensing must be cleared)*
Sub-layers, built in order, NOT all at once:
1. E2E text **+ on-device encrypted local store** (UI reads local DB, never server directly).
2. Real-time status (online/offline, last seen, typing, read receipts).
3. Media (photos + voice notes, E2E via R2).
4. Documents (reuse media pipeline).
5. In-chat profile card.
Plus **push wake**: content-free APNs/FCM → fetch ciphertext → decrypt on-device → render.

**Hard problems to spec, not hand-wave:** E2E push wake; prekey rotation (signed every 30 days).

---

## Phase 3 — Group Messaging
Group create/name/photo, membership, admin/member, add/remove/leave. **E2E via Sender Keys with rekeying on membership change** (forward secrecy). Same media/typing/status/receipts. **Begin multi-device history-sync design.**

---

## Phase 4 — Calling (1:1)
WebRTC native + signaling on Vultr + **coturn (STUN+TURN), dedicated India instance**. E2E from DTLS-SRTP. Fallback: STUN → P2P → TURN (mandatory; ~15–20% need relay on CGNAT). CallKit (iOS) / ConnectionService (Android). TURN creds time-limited + TLS.

## Phase 5 — Calling (Group)
SFU + per-frame E2E (Insertable Streams / SFrame) + group key distribution. Ship 1:1 first.

## Phase 6 — Clips & Short Episodes
Native video feed (AVPlayer/ExoPlayer), upload → transcode → CDN. Decide DRM before build.

## Phase 7 — Communities · Phase 8 — Shopping (Razorpay, Postgres ACID, not E2E) · Phase 9 — Profile & Settings (true delete-account purge per DPDP).

**Admin platform (Section 8):** minimal ops only in Phase 0; full dashboards/moderation/release-center built incrementally from Phase 3 onward.

---

## Pre-launch gates (Section 4.12 / 4.13)
External security audit · pen test · dependency review · OWASP · Signal Protocol review · DPDP compliance (consent, residency, erasure, breach process, privacy policy) · user-backup sign-off (v1 = lose-device-lose-history).
