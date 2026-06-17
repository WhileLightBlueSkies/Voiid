# VOIID — Engineering Handoff

> **Purpose:** single source of truth for **app/client devs** (iOS, Android, web)
> and anyone running the code on their machine. Tells you *what changed* and
> *what to run* after each push. Update this on **every push** that changes how
> someone builds, runs, or wires the apps.
>
> For backend/infra (secrets, deploy, provisioning) see [DEPLOY_HANDOFF.md](DEPLOY_HANDOFF.md).
> For the build plan and gates see [PHASE_PLAN.md](PHASE_PLAN.md) / [CHECKLIST.md](CHECKLIST.md).
>
> Last updated: 2026-06-17

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
- **Status:** UI prototype, ~4.3k lines SwiftUI. Onboarding + most main screens
  exist (chats, chat detail, groups, clips, AI, call screens).
- **Data:** 100% `DummyData` (see `Models/DummyData.swift` + `Models/Stores.swift`).
  **No networking, no crypto wired yet.**
- **Run:** open `apps/ios/Voiid/Voiid.xcodeproj` in Xcode → run on simulator.
  Nothing to provision; it's self-contained dummy data.

### Android app (`apps/android`)
- **Status:** scaffold only (manifest + theme). No screens. Not runnable as an app yet.

### Backend (`backend/`)
- **Status:** Phase 0 mostly done (auth, device/prekey, message relay). See
  DEPLOY_HANDOFF.md for env vars + how to run locally.
- **Run:** `npm run dev:api` and `npm run dev:ws` from repo root (needs `.env` —
  see DEPLOY_HANDOFF.md).

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

---

## Change log

> One entry per push. Newest on top. Format:
> `### YYYY-MM-DD — <short title>` then **What changed** / **⚠️ Run / do this**.

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
