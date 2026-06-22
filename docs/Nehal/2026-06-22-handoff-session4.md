# Voiid — Handoff (2026-06-22, session 4)

Branch: `0.0.2`. Backend (dev): `https://api-dev.voiid.app`.
Focus: **verify 1:1** + **start group-MLS** (in parallel).

---

## ✅ 1:1 verification

- Live backend is healthy: `/health` → db up, redis up, firebase configured, and
  **`media.configured: true`** — the **R2 env is now on the box, so media is
  unblocked** (no longer 503).
- Dev-bypass auth is **OFF** (prod Firebase), so I can't mint a JWT here — full
  runtime verification still needs two real accounts on a device.
- **New reusable script:** [`backend/scripts/verify-1to1.mjs`](../../backend/scripts/verify-1to1.mjs)
  proves the whole **server** path the apps use, incl. the two bugs fixed earlier
  (flat `conversation_id`, `devices` → `identity_public_key`):
  ```
  API=https://api-dev.voiid.app A_JWT=<jwtA> B_JWT=<jwtB> node backend/scripts/verify-1to1.mjs
  ```
  Grab each JWT from a logged-in app (the bearer it stores: iOS Keychain `jwt` /
  Android EncryptedSharedPreferences `jwt`). It registers devices, uploads a
  prekey, creates the conversation, sends an opaque message, and reads it back —
  printing ✅/❌ per step so a failure pinpoints the exact call.
- **On-device check** (the crypto part only the app can do): build both apps, two
  accounts, send a 1:1 text → confirm Supabase `messages` row + `[VOIID] ✅ sent`
  log + peer receives & decrypts.

## ✅ Group-MLS — foundation started (backend done; app blocked on e2e-core)

**Backend plumbing (built, typechecks):**
- Migration [`011_mls.sql`](../../database/migrations/011_mls.sql): `mls_key_packages`
  (one-time public KeyPackages, like prekeys) + `mls_group_events` (Welcome/Commit
  relay). ⚠️ **No migration runner exists — apply 011 to the dev DB manually**
  (psql / Supabase) before group-MLS ships. (Tables are unused until then, so no rush.)
- Routes [`mls.ts`](../../backend/api/src/routes/mls.ts), mounted at `/mls`:
  - `POST /mls/keypackages` · `GET /mls/keypackages/:userId` (consume one/device)
  - `POST /mls/group-events` (Welcome/Commit, WS-notifies recipients) · `GET /mls/group-events`
- The server stores/relays **opaque MLS bytes only**; group application ciphertext
  rides the existing `/messages` relay.

**🚧 The real blocker (needs the native/Rust build machine):**
- e2e-core's `GroupMember` and `GroupSession` have **no `toPickle`/`restore`**
  (only `Identity`/`Session` do). MLS group + signer state is in-memory, so it
  **can't survive an app restart**, and publishing a KeyPackage now would leave a
  member unable to join after relaunch. So I deliberately did **not** wire the app
  side yet (it would be broken).
- **Next step (Rust, in `packages/e2e-core/src/ffi.rs` + `group.rs`):** add
  `GroupMember.toPickle/restore` and `GroupSession.toPickle/restore` (serialize the
  OpenMLS group state + the provider key store + signer), then regenerate the
  Swift/Kotlin bindings + rebuild the xcframework/aar. Needs cargo + uniffi-bindgen
  on the build box — can't be done from my environment.

**After that — app `GroupEngine` slice (design ready):**
1. On bootstrap: create+persist a `GroupMember` (stable identity = user_id), publish
   its KeyPackage to `/mls/keypackages`.
2. Create group: fetch each member's KeyPackage → `GroupSession.addMember` →
   `POST /mls/group-events` (welcome+ratchet_tree to new members, commit to existing).
3. Join: `GET /mls/group-events` → `joinGroup(welcome, ratchet_tree)`.
4. Send: `GroupSession.encrypt` → `/messages/send` (base64). Receive: `decrypt`
   (apply commits from group-events first, then app messages).

---

## Status table
| Item | Status |
|---|---|
| Backend healthy + media configured | ✅ verified live |
| 1:1 server contracts | ✅ script ready; ⏳ needs 2 JWTs to run |
| 1:1 crypto end-to-end | ⏳ device-only |
| Group-MLS backend | ✅ built/typechecks; ⚠️ migration to apply |
| Group-MLS app | ⛔ blocked on e2e-core group persistence (Rust) |
