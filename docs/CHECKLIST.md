# VOIID — Build Checklist

> Living checklist tracking every feature against the spec. Check items as completed.
> Review gates are **hard stops** — do not proceed to the next phase until the current gate is fully checked and human-approved.
> Last updated: 2026-06-15

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked

---

## 🔴 Blocking pre-conditions
- [!] **#1 libsignal AGPL licensing cleared** (BEFORE PHASE 2)
- [!] **#2 Design tokens "derived → confirm" + Figma link** (BEFORE PHASE 1 client)
- [!] **#3 Firebase India OTP pricing confirmed + MSG91 swap lined up** (BEFORE PHASE 1)
- [!] **#4 SF Pro font licensing confirmed (Android/Web) + fallback chosen** (BEFORE PHASE 1 client)

---

## Cross-cutting (must hold at ALL times)
- [ ] Server **never** stores plaintext messages (ciphertext only) — verified
- [ ] Server **never** stores private keys (public keys only)
- [ ] No custom crypto; all crypto via libsignal (once wired)
- [ ] Contact books never uploaded (local match only)
- [ ] Media always encrypted before upload to R2
- [ ] Hardware-backed key storage on every client (Keychain/Keystore)
- [ ] Separate dev/staging/prod (DB, Redis, keys, URLs) — no hardcoded endpoints
- [ ] Every external dep behind a swappable interface

---

## Phase 0 — Backend Foundation
**Build**
- [ ] Monorepo structure created
- [ ] Docker Compose: api + websocket + redis run locally
- [ ] Env strategy: dev/staging/prod configs, separate secrets, `.env.example`
- [x] Migrations 001–009 authored, run via Supabase CLI
- [ ] SMS/OTP behind swappable interface (Firebase impl; MSG91/Twilio swappable)
- [ ] OTP stored as **hash only**; expiry 5 min; max 3 attempts; rate-limited
- [ ] Auth flow: Firebase OTP → verified phone → our user upsert (Supabase) → our JWT
- [ ] Device register + public prekey bundle upload + distribution (consume one-time prekey) + refresh
- [ ] Message relay: store ciphertext → Redis pub/sub → WS push; offline → `GET /messages/pending`
- [ ] Redis: presence (TTL+heartbeat), last_seen, typing (TTL 5s), pub/sub channels, rate-limit/cache keys
- [ ] Health endpoints + Sentry + Uptime Kuma

**Review gate (Section 10)**
- [x] Supabase Postgres live, all tables created; migrations run via deploy
- [ ] Redis live, pub-sub verified
- [ ] Vultr API + WebSocket deployed; WS authenticates + routes via Redis
- [ ] OTP verify end-to-end (Firebase → verified phone → our user → our JWT)
- [ ] SMS provider swappable; Supabase Auth/Realtime NOT used
- [ ] Device registration, prekey upload/distribution work
- [ ] Message store + relay + offline fetch work (placeholder payloads)
- [ ] Single instance handles 100+ concurrent WS connections
- [ ] Health + Sentry + Uptime Kuma live
- [ ] Dev environment separate from staging/prod
- [ ] ✅ **Human approval to proceed to Phase 1**

---

## Phase 1 — Onboarding & Auth
- [ ] Splash routing (JWT present → skip to chat list)
- [ ] All 5 permissions upfront via native dialogs (mic, camera, gallery, contacts, notifications)
- [ ] Phone validation; OTP send/verify on all platforms
- [ ] JWT stored securely; logout clears; re-login works
- [ ] Profile persists name/email/photo
- [ ] Contact sync matches locally (iOS/Android); raw book never uploaded
- [ ] Reaches chat list; error handling (invalid OTP, network, rate limit)
- [ ] Screens match design system (Section 6) on every platform
- [ ] ✅ **Human approval to proceed to Phase 2**

---

## Phase 2 — 1:1 Messaging (Core)   *(requires blocker #1 cleared)*
- [ ] Layer 1: E2E text send/receive + delivery state; on-device encrypted store; UI reads local DB
- [ ] Airplane-mode: history loads instantly; composed messages queue → send on reconnect
- [ ] Local message DB encrypted at rest (hardware-backed key)
- [ ] Push wake works without leaking content (decrypt on-device)
- [ ] Layer 2: real-time status (online/offline, last seen, typing, read receipts)
- [ ] Layer 3: media (photos + voice notes, E2E, offline-viewable)
- [ ] Layer 4: documents (reuse media pipeline)
- [ ] Layer 5: in-chat profile card
- [ ] Saved-contact name via local match; history paginates; offline sync on reconnect
- [ ] Prekey rotation (signed every 30 days; one-time auto-replenish)
- [ ] Server only ever stores ciphertext (verified); design-system parity
- [ ] ✅ **Human approval to proceed to Phase 3**

---

## Phase 3 — Group Messaging
- [ ] Group create/name/photo; membership; admin vs member; add/remove/leave
- [ ] E2E via Sender Keys + **rekey on member add/remove** verified
- [ ] Media/typing/status/receipts in groups; member profile cards
- [ ] Multi-device history-sync model documented
- [ ] Design parity
- [ ] ✅ **Human approval to proceed**

---

## Phase 4 — Calling (1:1)
- [ ] 1:1 voice + video reliable; all call states
- [ ] Call logs persist locally + load offline
- [ ] STUN → P2P works; coturn TURN fallback verified on restrictive/CGNAT
- [ ] TURN creds time-limited + TLS
- [ ] CallKit (iOS) / ConnectionService (Android)
- [ ] E2E (DTLS-SRTP) verified through TURN; design parity
- [ ] ✅ **Human approval to proceed**

## Phase 5 — Calling (Group)
- [ ] Group calls connect at target size; E2E preserved through SFU (verified)
- [ ] Key distribution; group UI; design parity

## Phase 6 — Clips & Short Episodes
- [ ] Clip upload + transcode + CDN playback; smooth scroll feed; 2-min episode format; DRM decision; design parity

## Phase 7 — Communities
- [ ] Membership + posting + feed + moderation basics; design parity

## Phase 8 — Shopping
- [ ] Browse → cart → checkout → order → payment (Razorpay); design parity

## Phase 9 — Profile & Settings
- [ ] Profile view/edit; all settings; privacy policy + support; logout/delete-account (true DPDP purge); design parity

---

## Pre-launch (Section 4.12 / 4.13)
- [ ] External security audit · pen test · dependency review · OWASP · Signal Protocol review
- [ ] DPDP: consent capture, data residency (India), user rights/erasure, breach process, published privacy policy
- [ ] User-backup sign-off (v1 = lose-device-lose-history)
