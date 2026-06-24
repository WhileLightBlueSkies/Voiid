# VOIID — Roadmap

> High-level roadmap with progress checkboxes. For the exhaustive feature list see
> [CHECKLIST.md](CHECKLIST.md); for build order/rationale see [PHASE_PLAN.md](PHASE_PLAN.md).
> Last updated: 2026-06-24

**Legend:** `[x]` done · `[~]` in progress · `[ ]` not started · `[!]` blocked

---

## 🎯 Now — Stabilize 1:1 E2EE messaging (WhatsApp-level)
The current focus. Core crypto + relay work; we are hardening real-device delivery.

- [x] Clean-room E2E core (`packages/e2e-core`: vodozemac Olm, X3DH/PQXDH, OpenMLS) — no AGPL/libsignal
- [x] Device + prekey infra (register, publish bundle, consume OTK, replenish, per-device count)
- [x] Ciphertext-only relay (HTTP send + Redis pub/sub + WebSocket push + offline pending)
- [x] On-device decrypt-once persistent message store (survives restart)
- [x] Identity stability — stop Android Auto-Backup wiping the encrypted identity
- [x] Sender-device resolution + per-(peer,device) TOFU identity pinning
- [x] Session self-heal protocol (`session_reset` over WS)
- [x] WS reconnect on screen entry + open-chat polling fallback (delivery without push)
- [x] Tombstone + retry undecryptable messages once the session heals
- [x] Decrypt success/failure logging (`✅ decrypted inbound` / `❌ inbound decrypt FAILED`)
- [x] Keep send **pending+retry** when peer has no prekeys (not "failed")
- [x] **Serialize sync per conversation** — fix concurrent `acceptSession` race (PR #39)
- [ ] **Verify on a clean wipe+install:** every fresh message decrypts both directions (no `❌`)
- [ ] **Read receipts round-trip:** sender shows Sent → Delivered → **Seen**
- [ ] Last-seen / online presence accurate on both platforms
- [ ] Media (photo + voice note) E2E send/receive live-tested on device

**Gate:** a clean 2-device session exchanges 10+ messages each way, all decrypt, status reaches Seen.

---

## 1:1 Messaging — remaining features
- [ ] Documents (reuse media pipeline)
- [ ] Message delete / edit
- [ ] Reply / quote
- [ ] Reactions
- [ ] Forwarding
- [ ] Typing indicator polish
- [ ] Safety-number (key verification) UI

---

## Delivery infrastructure
- [ ] Push notifications (FCM Android / APNs iOS) — deliver while app is closed
- [ ] Background message sync
- [ ] Multi-device sync for a single user (sent-message recoverability)
- [ ] Note-to-self conversation

---

## Groups (Phase 3)
- [ ] `e2e-core` group session persistence (OpenMLS GroupMember/GroupSession) in Rust
- [ ] Group create / membership management
- [ ] Group E2E messaging (MLS)
- [ ] Group media

---

## Profile & social
- [x] Profile page wired (realtime)
- [ ] Profile editing (name, avatar, status) live-tested
- [ ] Contact sync — local match only, never upload
- [ ] Blocking / privacy controls

---

## Platform & API
- [x] API versioning (`/v1`, additive evolution, `/config`, force-update gate)
- [x] Feature flags + force-update automated via remote config
- [ ] iOS Firebase package resolves cleanly (local SPM ref) on fresh checkout
- [ ] Android/iOS UI parity pass (see [ANDROID_IOS_PARITY.md](ANDROID_IOS_PARITY.md))

---

## Infrastructure & ops
- [x] Supabase Postgres + Redis live; deploy = merge to `dev` (CI → SSH → pm2)
- [ ] Vultr production box provisioned
- [ ] GitHub Actions deploy pipeline (Docker later)
- [ ] Separate dev / staging / prod (DB, Redis, keys, URLs)
- [ ] Health endpoints + Sentry + Uptime monitoring
- [ ] Firebase In-App Messaging / App Check APIs enabled (or noise suppressed)

---

## Pre-production gates (hard stops before launch)
- [!] Lawyer sign-off on E2E crypto licensing ([LEGAL_QUESTIONS.md](LEGAL_QUESTIONS.md) #1)
- [ ] External cryptography audit of `e2e-core` (incl. the bespoke PQXDH combiner)
- [!] Design tokens "derived → confirm" + Figma link
- [!] SF Pro font licensing (Android/Web) + fallback
- [ ] Security review (key storage, MITM/TOFU, rate limits)
- [ ] Load test (relay + WS fan-out)

---

## ✅ Recently shipped (this stabilization push)
- PR #39 — serialize sync per conversation (concurrent `acceptSession` race)
- PR #38 — keep send pending+retry when peer has no prekeys
- PR #37 — retry tombstoned messages + log successful decrypts
- PR #36 — `reset-user-crypto` optional message wipe (`WIPE_MESSAGES=1`)
- PR #35 — open-chat polling (WS-independent delivery)
- PR #34 — WS reconnect on chats-screen entry
- Earlier — Android backup identity-wipe fix; sender-device resolution; session self-heal
