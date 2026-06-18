# VOIID — Engineering Handoff

> **Purpose:** single source of truth for **app/client devs** (iOS, Android, web)
> and anyone running the code on their machine. Tells you *what changed* and
> *what to run* after each push. Update this on **every push** that changes how
> someone builds, runs, or wires the apps.
>
> For backend/infra (secrets, deploy, provisioning) see [DEPLOY_HANDOFF.md](DEPLOY_HANDOFF.md).
> For the build plan and gates see [PHASE_PLAN.md](PHASE_PLAN.md) / [CHECKLIST.md](CHECKLIST.md).
>
> Last updated: 2026-06-18

---

## How to read this doc

- **Current state** sections below = the always-true "what exists and how to run
  it right now." Keep them correct on every push.
- **Change log** at the bottom = one dated entry per push: what's new + what you
  must run because of it. Newest on top.
- ⚠️ = action required by other devs after pulling.

---

## Repo layout (what lives where)

```
voiid/
├── apps/
│   ├── ios/Voiid/        SwiftUI app — most screens built (PROTOTYPE on dummy data)
│   ├── android/          Kotlin scaffold — EMPTY (no screens yet)
│   └── (web)             does not exist yet
├── backend/              api · websocket · workers · signaling · admin-api (Node, mostly Phase 0 done)
├── packages/
│   └── e2e-core/         Rust E2E encryption core + Swift/Kotlin bindings  ← crypto lives ONLY here
├── supabase/ database/   migrations
└── docs/                 these handoff/checklist docs
```

---

## Current state — what's built & runnable

### iOS app (`apps/ios/Voiid`)
- **Status:** UI prototype, ~4.3k lines SwiftUI. Onboarding + most main screens.
- **Data:** auth, conversations, and **real E2EE 1:1 messaging are wired to the
  live backend + e2e-core** (see "Messaging / E2EE" below). Groups, clips, AI,
  calls are still `DummyData`.
- **Run:** open `apps/ios/Voiid/Voiid.xcodeproj` in Xcode → run on device/simulator.
  ⚠️ Needs a real device build to verify the messaging layer (it was authored
  without an iOS toolchain in the loop — parse-clean only).

### Android app (`apps/android`)
- **Status:** full UI prototype (Kotlin/Compose). Auth, conversations, and **real
  E2EE 1:1 messaging wired** (mirror of iOS). Groups/clips/AI/calls still dummy.
- ⚠️ Needs a Gradle build to verify the messaging layer.

### Messaging / E2EE — current state (1:1)
**Done & wired (both platforms):**
- **Identity/prekeys:** `E2EManager` publishes the device identity + 100 one-time
  prekeys on login (idempotent).
- **Sessions:** lazy — sender `startSession` from the peer's prekey bundle;
  receiver `acceptSession` on the first PreKey message. Pickled per conversation
  (Keychain / EncryptedSharedPreferences).
- **Send/receive:** `ChatEngine` encrypts → `POST /messages/send` (server stores
  only ciphertext); `WebSocketClient` delivers refs → fetch + decrypt.
- **Decrypt-once + local store:** each inbound message is decrypted exactly once
  and persisted (plaintext at rest, file-protected iOS / EncryptedSharedPreferences
  Android) — ratchet ciphertext is never re-decrypted.
- **Anti-MITM:** peer identity key is pinned on first contact (TOFU); a changed
  key is refused (basis for safety numbers).
- **Contacts:** `ContactsService` discovers VOIID users by **hashing phone numbers
  on-device** (raw numbers never uploaded) → new-chat picker + invite share-sheet.
- **Receipts:** mark-read on open → `receipt` WS event flips the sender's ticks.
- **Typing + presence:** typing over WS; online/last-seen via `GET /users/status/:id`.

**Not done yet:**
- **Group messaging (MLS):** group sends are local-echo only; OpenMLS path not wired.
- **Media + voice notes:** ⚠️ **blocked on R2/S3 config** (object-store env vars
  empty). e2e-core already exposes `encryptMedia`/`decryptMedia`; the plan is
  encrypt blob on-device → upload ciphertext to R2 → send the media ref + key in
  the E2EE message. Cannot build until the bucket + creds exist.
- **Safety-number UI:** the pin exists; a user-facing verification screen does not.

### Backend (`backend/`)
- **Status:** ✅ **runs and connects to live Supabase + Upstash.** Auth, device/
  prekey, conversations, message relay all verified working against the live DB
  (full chat path: login → device → conversation → send → fetch ciphertext).
- **Auth = Firebase Phone Auth (client-side).** The app does Phone Auth with the
  Firebase SDK, gets a Firebase ID token, and POSTs it to `/auth/firebase`; the
  server verifies it and returns OUR JWT. There is no server-side OTP/SMS.
- **Run locally:**
  ```bash
  # from repo root — .env is loaded automatically via --env-file in the scripts
  npm run dev:api    # http://localhost:4000  (GET /health → db/redis up)
  npm run dev:ws     # ws://localhost:4001
  ```
- **Dev login without Firebase:** set `AUTH_DEV_BYPASS=1` in `.env` (already set),
  then POST `/auth/firebase` with `{"id_token":"dev:+91XXXXXXXXXX"}` → returns a
  real JWT + creates the user in Supabase. Unset this in production.
- **Real Firebase:** set `FIREBASE_SERVICE_ACCOUNT` (service-account JSON) so the
  server can verify real Firebase ID tokens.

### E2E crypto core (`packages/e2e-core`)
- **Status:** built & tested in Rust. NOT yet linked into either app.
- **What it covers:** 1:1 messages, media, MLS groups (post-quantum X-Wing),
  call key derivation, safety numbers. See `packages/e2e-core/README.md`.
- **Test (no app needed):**
  ```bash
  cd packages/e2e-core
  cargo test            # 47 tests
  cargo test --test soak -- --ignored   # load tests (optional, slow)
  ```

---

## How to build the crypto core into the apps

> Needed once you start Phase 2 wiring. Requires Rust + the mobile targets.

### iOS (XCFramework)
```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios   # once
cd packages/e2e-core
./build-apple.sh
```
Produces `target/apple/Voiid.xcframework` + regenerates `bindings/swift/voiid.swift`.
Then in Xcode: add the XCFramework to the app target, add `voiid.swift` to the
target, `import voiid`. (Simulator slice is included — smoke-testing on the
simulator works.) See `packages/e2e-core/bindings/swift/README.md`.

### Android (JNI)
```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android  # once
cargo install cargo-ndk         # once
export ANDROID_NDK_HOME=/path/to/ndk
cd packages/e2e-core
./build-android.sh
```
Drops `.so`s under `apps/android/.../jniLibs/` + Kotlin glue. Add the JNA aar dep
(see `packages/e2e-core/bindings/kotlin/README.md`).

---

## Standing gotchas (read before wiring)

- **Crypto only lives in `packages/e2e-core`.** Never write crypto in the apps —
  call the binding. Private keys never leave the device / never go to the backend.
- **Pickle keys** (that encrypt identity + session state) must be stored in iOS
  Keychain / Android Keystore. Simulator Keychain ≠ device Secure Enclave —
  verify key storage on a real device before Phase 2 ships.
- **Group re-add:** a member who left and is re-added must rejoin with a FRESH
  `GroupMember` (clean per-group state); reusing the old one fails to join.
- **Safety numbers must be shown in the UI** and compared by users, or E2EE is
  open to MITM.
- **PQXDH 1:1 is gated:** do NOT enable the `pq-1to1-activate` feature — it
  `compile_error!`s on purpose until a cryptographer reviews the combiner.
- **Clips privacy wall (enforce when Clips is built):** the Clips identity is a
  separate world from messaging. Clips surfaces expose ONLY `username`, display
  name, avatar, and clips — NEVER `phone_number` or `user_id`, and NO "message/
  call this person" action. The only outbound action is **share** (clip/profile
  link via the share sheet). You cannot start a chat from a username; chats start
  only from a phone-matched contact. (`username` is the Clips handle only — not
  auth, not contact matching.)

---

## Change log

> One entry per push. Newest on top. Format:
> `### YYYY-MM-DD — <short title>` then **What changed** / **⚠️ Run / do this**.

### 2026-06-18 — Real E2EE 1:1 messaging wired end-to-end (iOS + Android)
**What changed**
- `ChatEngine` (both platforms): session handshake, encrypt→send, fetch→decrypt,
  **decrypt-once + persistent local store**, **TOFU identity pinning** (anti-MITM).
- `WebSocketClient` (both): live relay — message refs, typing, **receipts**.
- `ChatStore` (both): replaced the simulated send/auto-reply with the real path;
  optimistic echo, sync-on-open, WS-driven receive; group sends are local-echo only.
- **Contacts:** `ContactsService` (on-device phone hashing) + new-chat picker +
  invite share-sheet; compose button in the chats header.
- **Receipts** (read/delivered ticks) + **presence** (online/last-seen) wired.
- No backend changes — all endpoints/WS events already existed.

**⚠️ Run / do this**
- **iOS:** build `apps/ios/Voiid/Voiid.xcodeproj` on a device and report any
  compile errors — the messaging layer was authored without an iOS toolchain in
  the loop (parse-clean only). Two test accounts needed to exercise send/receive.
- **Android:** Gradle build + report errors. Same two-account test.
- **Media/voice + groups are NOT in this drop.** Media/voice is **blocked on R2/S3
  config** — provision the bucket + creds, then it can be built (see "Messaging /
  E2EE" above).

### 2026-06-17 — Backend running + Firebase auth + chat API verified
**What changed**
- Backend now boots and connects to **live Supabase + Upstash** (fixed: services
  never loaded `.env`). `npm run dev:api` / `dev:ws` work; `/health` = db/redis up.
- Auth switched to **Firebase Phone Auth (client-side)**; MSG91 + server-side OTP
  removed. New `/auth/firebase` verifies the Firebase ID token → issues our JWT.
- Full chat API path verified against the live DB (login→device→conversation→
  send→fetch ciphertext). Server only ever stores/returns opaque ciphertext.
- Added a global error handler so malformed input returns 400 instead of
  resetting the socket. (Per-route async-error wrapping is a follow-up.)

**⚠️ Run / do this**
- `npm install` (added `firebase-admin`).
- Backend now needs no extra setup to run in dev — `.env` is auto-loaded and
  `AUTH_DEV_BYPASS=1` lets you log in with `dev:<phone>` tokens.
- Next: client networking + auth layer, then wire chats.

### 2026-06-17 — E2E core complete; engineering handoff created
**What changed**
- `packages/e2e-core` finished: 1:1 (double ratchet), media (AES-GCM blobs),
  groups (MLS + post-quantum X-Wing), call key derivation, safety numbers,
  multi-device fan-out, prekey replenishment, group remove/re-add, concurrent-
  commit handling. 47 tests + 3 soak tests + fuzz harnesses, all green.
- uniffi Swift + Kotlin bindings generated; `build-apple.sh` / `build-android.sh` added.
- PQXDH 1:1 is scaffolded (real ML-KEM prekeys) but the handshake combiner is
  gated behind `pq-1to1-activate` (compile-error until cryptographer review).
- Licensing resolved: permissive libs only (vodozemac/OpenMLS/ml-kem) — no AGPL,
  no libsignal. (Lawyer sign-off still pending — CHECKLIST blocker #1.)

**⚠️ Run / do this**
- Nothing required to keep working on the iOS UI prototype (still dummy data).
- If you're starting Phase 2 wiring: run `./build-apple.sh` and do the encrypt→
  decrypt smoke test on the simulator BEFORE wiring the chat UI.
- Read "Standing gotchas" above before touching crypto.

<!-- TEMPLATE for the next push — copy this block, fill it in, put it above this comment:

### YYYY-MM-DD — <title>
**What changed**
- ...

**⚠️ Run / do this**
- e.g. `npm install` (new dep) / re-run `./build-apple.sh` (binding changed) /
  new migration to apply / new env var in DEPLOY_HANDOFF.md / nothing.

-->
