# VOIID — Build Checklist

> Living checklist tracking every feature against the spec. Check items as completed.
> Review gates are **hard stops** — do not proceed to the next phase until the current gate is fully checked and human-approved.
> Last updated: 2026-06-17

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked

---

## 🔴 Blocking pre-conditions
> Lawyer questions for all of these are tracked in [LEGAL_QUESTIONS.md](LEGAL_QUESTIONS.md).
- [x] **#1 E2E crypto licensing** (BEFORE PHASE 2) — `libsignal` confirmed **AGPL-3.0, no commercial exception**; closed-source VOIID cannot link it. **Resolved:** built our own `packages/e2e-core` on **permissively-licensed** libraries (vodozemac Apache-2.0 for the 1:1 double ratchet, OpenMLS Apache-2.0 for groups, ml-kem/aes-gcm/hkdf — all Apache/MIT/BSD, **no AGPL, no libsignal code**). We implement the *protocol design* from public specs, not anyone's source. Closed-source is clean. ⚠️ Still requires the lawyer sign-off in [LEGAL_QUESTIONS.md](LEGAL_QUESTIONS.md) #1 to formally close, and an external crypto audit before launch (see Pre-production gate).
- [!] **#2 Design tokens "derived → confirm" + Figma link** (BEFORE PHASE 1 client) — design is in Figma (per owner); need the file URL + confirmed token values.
- [x] **#3 OTP provider = Firebase Phone Auth (client-side)** (confirmed by owner). MSG91 dropped entirely. Firebase SDK sends+verifies OTP on the device → app gets a Firebase ID token → server `/auth/firebase` verifies it (Firebase Admin) and issues OUR JWT. Dev bypass (`AUTH_DEV_BYPASS=1`, token `dev:<phone>`) works now; real Firebase needs a service-account key (`FIREBASE_SERVICE_ACCOUNT`).
- [!] **#4 SF Pro font licensing confirmed (Android/Web) + fallback chosen** (BEFORE PHASE 1 client)

---

## Cross-cutting (must hold at ALL times)
- [x] Server **never** stores plaintext messages (ciphertext only) — verified (smoke test: no plaintext column; ciphertext round-trips)
- [x] Server **never** stores private keys (public keys only) — devices/prekeys store public keys only
- [x] No custom/hand-rolled crypto — all primitives via vetted permissive libs (vodozemac, OpenMLS, ml-kem, aes-gcm, hkdf) in `packages/e2e-core`. The one bespoke piece (1:1 PQXDH handshake combiner) is `compile_error!`-gated until a cryptographer reviews it.
- [ ] Contact books never uploaded (local match only)
- [ ] Media always encrypted before upload to R2
- [ ] Hardware-backed key storage on every client (Keychain/Keystore)
- [ ] Separate dev/staging/prod (DB, Redis, keys, URLs) — no hardcoded endpoints
- [ ] Every external dep behind a swappable interface

---

## Phase 0 — Backend Foundation
**Build**
- [x] Monorepo structure created
- [ ] Docker Compose: api + websocket + redis run locally  *(services run via npm; Docker compose not yet exercised)*
- [x] Env strategy: dev/staging/prod configs, separate secrets, `.env.example`  *(`.env` live; staging/prod values pending infra)*
- [x] Migrations 001–009 authored, run via Supabase CLI
- [x] OTP via **Firebase Phone Auth on the client** (no server-side SMS provider; MSG91 removed). Server verifies the Firebase ID token.
- [x] OTP stored as **hash only**; expiry 5 min; max 3 attempts; rate-limited  *(crypto-safe RNG + Redis rate-limit verified)*
- [x] Auth flow: Firebase Phone Auth (client) → Firebase ID token → `/auth/firebase` verifies → our user upsert (Supabase) → our JWT  *(verified end-to-end against live Supabase via dev bypass; real Firebase token verification pending service-account key)*
- [x] Device register + public prekey bundle upload + distribution (consume one-time prekey) + refresh  *(atomic consumption verified)*
- [x] Message relay: store ciphertext → Redis pub/sub → WS push; offline → `GET /messages/pending`  *(end-to-end verified)*
- [~] Redis: presence (TTL+heartbeat), last_seen, typing (TTL 5s), pub/sub channels, rate-limit/cache keys  *(pub/sub + presence + rate-limit verified; typing = Phase 2)*
- [ ] Health endpoints + Sentry + Uptime Kuma  *(health live; Sentry + Uptime Kuma pending)*

**Review gate (Section 10)**
- [x] Supabase Postgres live, all tables created; migrations run via deploy
- [x] Redis live, pub-sub verified  *(Upstash; relay delivery verified)*
- [ ] Vultr API + WebSocket deployed; WS authenticates + routes via Redis  *(WS auth+routing verified locally; Vultr deploy pending — infra)*
- [~] OTP verify end-to-end (Firebase → verified phone → our user → our JWT)  *(our-JWT path verified; Firebase SMS stubbed — blocker #3)*
- [x] SMS provider swappable; Supabase Auth/Realtime NOT used  *(own JWT; only Postgres used)*
- [x] Device registration, prekey upload/distribution work  *(atomic one-time-prekey consumption verified)*
- [x] Message store + relay + offline fetch work (placeholder payloads)
- [ ] Single instance handles 100+ concurrent WS connections  *(load test pending)*
- [ ] Health + Sentry + Uptime Kuma live  *(health live; Sentry + Uptime Kuma pending)*
- [ ] Dev environment separate from staging/prod  *(dev live; staging/prod pending — infra)*
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
> Group E2E = **MLS / RFC 9420** via OpenMLS (not Sender Keys), with the hybrid
> post-quantum **X-Wing** ciphersuite (X25519 + ML-KEM-768). Core implemented &
> tested in `packages/e2e-core` (`src/group.rs`).
- [ ] Group create/name/photo; membership; admin vs member; add/remove/leave
- [x] E2E via MLS + **rekey on member add/remove** verified — removed member locked out of subsequent messages (test: `group_membership::remove_locks_out_member`)
- [ ] ⚠️ **Re-add gotcha (wire into client):** a re-added member must rejoin with a FRESH `GroupMember` (clean per-group key state); reusing the old one fails to join. Documented in `join_group`.
- [ ] Concurrent commits: server serializes commits per epoch; losing committer must `clear_pending` + apply the winner (core supports this — test: `concurrent::losing_committer_reconciles`)
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

## 🚦 Pre-production gate (HARD STOP before launch)

> Every box here must be checked **and human-approved** before VOIID ships to
> real users. Nothing below is optional — these are the things that, if skipped,
> either break E2EE silently or create legal/operational liability.
> Source of truth for the crypto items: `packages/e2e-core/SECURITY.md`.

### A. E2EE crypto — independent audit (NON-NEGOTIABLE)
- [ ] **External cryptographic audit** of `packages/e2e-core` commissioned & passed. The code is tested (47 tests + 3 soak + fuzz harnesses) but **unaudited** — tests prove correctness, not security. Scope the auditor with `SECURITY.md`'s pre-audit checklist:
  - [ ] Nonce uniqueness in media (`media.rs`) — fresh random nonce per blob, no key+nonce reuse
  - [ ] RNG is a CSPRNG on iOS + Android targets
  - [ ] `WireMessage` type-tag handling can't cause type confusion / bogus sessions
  - [ ] KeyPackage validation in `group.rs::add_member` is not bypassable
  - [ ] Ciphersuite pinning — X-Wing enforced; classic-suite downgrade not forceable by a peer
  - [ ] Safety-number construction reviewed (or replaced with a vetted lib)
  - [ ] Pickle round-trip fails closed on wrong key; pickles hold no plaintext secrets
  - [ ] FFI boundary (`ffi.rs`) — no panic can cross unsafely
  - [ ] Group exporter → SRTP derivation (`call.rs`) labels/lengths correct; non-member can't derive
  - [ ] Memory hygiene / key zeroization reviewed
- [ ] **1:1 PQXDH decision:** either (a) ship with the documented classic-1:1 + PQ-prekeys-scaffold limitation accepted in writing, OR (b) get the gated handshake combiner (`pq-1to1-activate`) cryptographer-reviewed and activated. Do NOT enable the gate without that review.
- [ ] **Olm `version_1` MAC** (64-bit truncated) accepted, or moved to v2 once stable (tracked in `SECURITY.md`).
- [ ] Pen test · dependency/SCA review (`cargo audit`, `cargo deny`) · OWASP MASVS pass.

### B. Crypto wired correctly into the apps
- [ ] `packages/e2e-core` built & linked into iOS (XCFramework) and Android (JNI) via `build-apple.sh` / `build-android.sh`; smoke test on real devices.
- [ ] **Private keys never leave the device**; backend stores ciphertext + public bundles/KeyPackages only (re-verify against live backend, not just tests).
- [ ] **Pickle keys** (identity + session state) stored in iOS Keychain / Android Keystore, hardware-backed; never on disk in plaintext; never logged.
- [ ] **Safety numbers surfaced in the UI** and users prompted to verify — encryption without verification is open to MITM.
- [ ] **Prekey replenishment** wired: client tops up one-time keys when the server reports the count is low (`replenish_prekeys`); signed-prekey rotation (30d) scheduled.
- [ ] **Re-add path** uses a fresh `GroupMember` (see Phase 3 gotcha).
- [ ] No plaintext / keys / ciphertext in any log at `info`/`warn`/`error` level on any platform.

### C. Licensing / legal
- [ ] Lawyer sign-off on [LEGAL_QUESTIONS.md](LEGAL_QUESTIONS.md) #1 — confirm the permissive-library approach keeps VOIID closed-source-clean (no AGPL, no libsignal). 
- [ ] Third-party license attributions bundled in-app (acknowledgments screen) and accurate.
- [ ] Fonts (#4) + any other asset licenses cleared for Android/Web.
- [ ] DPDP Act 2023: consent capture, India data residency, user rights/erasure (true delete-account purge), breach-notification process, published privacy policy.

### D. Reliability / operations
- [ ] Separate dev / staging / prod (DB, Redis, keys, URLs) — no hardcoded endpoints.
- [ ] Single instance handles target concurrent WS connections (load test passed).
- [ ] Health endpoints + Sentry + Uptime Kuma live; alerting wired.
- [ ] Soak test green at expected volume (core soak passes: 20k 1:1 msgs, 10k group msgs w/ churn, 2k media; re-run against integrated stack).
- [ ] Backups & disaster recovery for server state; key-rotation runbook.
- [ ] **User-backup sign-off** (v1 = lose-device-lose-history) — explicitly accepted by owner.
- [ ] Rollback plan for a bad client release.

### E. Final sign-offs
- [ ] Security audit report reviewed; all critical/high findings fixed & re-verified.
- [ ] Legal sign-off received.
- [ ] ✅ **Owner approval to launch.**
