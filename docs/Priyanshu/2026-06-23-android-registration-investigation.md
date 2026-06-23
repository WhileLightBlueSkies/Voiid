# Investigation — "messages not going through" on Android (2026-06-23)

Author: Priyanshu (via Claude Code session)
Branch: `0.0.2`
Backend: dev (`api-dev.voiid.app`, Vultr `139.84.209.49`), changes from PR #22 are **live**.

This is a deep-dive into why 1:1 chat still fails on Android after the prekey/device
fixes from [2026-06-22-messaging-profile-animations.md](2026-06-22-messaging-profile-animations.md).
It documents the live evidence pulled from the backend + emulator, the **two distinct
root causes**, and a concrete plan. **No new fix was applied in this session** — this
is a diagnosis/handoff.

---

## TL;DR

There are **two separate problems**, both of which independently break messaging:

1. **The Android client never registers its device on the backend.** Its very first
   API call, `POST /v1/devices/register`, **times out (30s)**, so the device is never
   created and never publishes one-time prekeys. Result: nobody can start a session
   with the Android user. On the test emulator this is an **emulator↔HTTPS network
   stall** (see below). **Must be re-checked on a real device** to know if there's
   also a client-side bug.
2. **The iOS peers have no prekeys.** The only registered users are 3 old iOS devices
   with `0, 0, 1` available one-time prekeys. iOS publishes prekeys once and **never
   replenishes**, so sending to them returns `409 peer has no available prekeys` even
   when the sender's network is perfect. **iOS needs the same fix Android got.**

The backend itself is **healthy** and the 2026-06-22 fixes are **deployed and live**.

---

## What was verified live this session

### Backend is healthy and the fix is deployed
- From a laptop, every endpoint responds instantly:
  - `GET /health` → `200` in ~0.39s
  - `POST /v1/devices/register` (no auth) → `401` in ~0.08s
  - `GET /v1/prekeys/count` (no auth) → `401` in ~0.17s  ← **proves the new route is live**
  - `GET /v1/conversations` (no auth) → `401` in ~0.08s
- On the box: `pm2` shows `voiid-api` + `voiid-ws` **online**, process created
  `2026-06-22T18:16:15Z` (the PR #22 deploy), stable ~13h, `dist/` rebuilt at 18:16
  including `/prekeys/count` and the device-revoke logic. `git log` on the box HEAD =
  `Merge PR #22`.
- The high pm2 restart count (`1767`) is **historical** — from the earlier pre-creds
  crash-loop (`ERR_MODULE_NOT_FOUND .../common-utils/src/crypto`). Not happening now.

### Database state (Supabase, queried via the pooler from the box)
Only **3 devices exist, all iOS**, all old:

| phone (trunc) | platform | active | available OTKs | total OTKs | created |
|---|---|---|---|---|---|
| +91 727016… | ios | yes | **1** | 2 | 06-18 13:40 |
| +91 999444… | ios | yes | **0** | 0 | 06-17 11:07 |
| +91 990000… | ios | yes | **0** | 0 | 06-17 11:05 |

- **Zero Android devices, ever** — including `6351822668`, which has been logged in
  many times. So Android registration has been failing the whole time (not a
  regression from the 2026-06-22 changes).
- Two iOS devices have `total = 0` one-time prekeys (never uploaded any), one has 1
  left. This is why sends 409.

### The exact Android failure (from logcat, with added bootstrap logging)
```
I/VOIID: bootstrap: identity ready
E/VOIID: bootstrap FAILED
E/VOIID: com.voiid.app.net.ApiError$Transport: timeout   (ApiClient.kt:82)
```
- The local e2e-core identity is created fine; the **first network call
  (`devices/register`) times out** at the OkHttp `readTimeout` (30s). Reproduced on
  every relaunch.
- The failure is swallowed by `runCatching { … bootstrap() }` at the call sites
  ([OtpScreen.kt:78](../../apps/android/app/src/main/java/com/voiid/app/onboarding/OtpScreen.kt#L78),
  [ChatsHomeView.kt:110](../../apps/android/app/src/main/java/com/voiid/app/main/ChatsHomeView.kt#L110)),
  and `E2EManager` logged nothing — so it failed **silently** until logging was added.

### Why it's the emulator's network (for this test), not the server
- The emulator **can reach the box**: `ping 8.8.8.8` and `ping api-dev.voiid.app`
  (resolves to 139.84.209.49) both 0% loss, ~35ms.
- But its **HTTPS POST gets no response for 30s**, while the same endpoint answers a
  laptop in 0.08s.
- Earlier the **same** emulator worked (it loaded the chat list and a prekey fetch
  returned a 409) — so its user-mode network stack **degraded over long uptime**, a
  known Android-emulator issue. Fix for testing: **cold-boot the emulator or use a
  real device.** (A cold boot was started but the session was stopped before it
  finished — re-run it to verify.)

---

## Root causes (ranked)

1. **iOS doesn't maintain a prekey pool** → peers are unmessageable (`409`). This is a
   real, device-independent bug and the most likely reason *real* sends fail. The
   2026-06-22 work added register-on-launch + replenishment + monotonic key ids to
   **Android only**; iOS still does a one-shot publish (or less).
2. **Android device registration must actually complete.** On the emulator it's the
   degraded-network stall. We have **not yet confirmed** registration succeeds on a
   healthy network/real device — that's the #1 thing to verify next. If it *also*
   times out on a real device, investigate the client TLS/OkHttp path (see below).
3. **Silent bootstrap failure** — even when the network is fine, a single failed
   `devices/register` leaves the device permanently unregistered for that session with
   no user-visible signal and (until this session) no log.

---

## What to do next (concrete)

### A. Verify Android registration on a clean network  ← do this first
- Cold-boot `emulator-5554` (`adb emu kill`, relaunch with `-no-snapshot-load`) **or**
  install on a real device, then log in as `6351822668` and watch:
  ```
  adb logcat | grep VOIID
  ```
  Expect: `bootstrap: identity ready` → `bootstrap: registered device=…` →
  `ensurePrekeys: uploading N keys`. Then confirm a new **android** row appears in the
  DB with `avail ≈ 100`.
- The APK with the bootstrap logging is at
  `apps/android/app/build/outputs/apk/debug/app-debug.apk` (and `~/Desktop/voiid-0.0.2-debug.apk`).

### B. Port the prekey/register fix to iOS (highest product impact)
Mirror the Android `E2EManager` changes in `apps/ios/.../Networking/E2EManager.swift`:
- On launch: register the device, then **check `GET /v1/prekeys/count`** and
  **replenish toward ~100 when below ~20**, using **monotonic key ids** (persist a
  counter; the server keys on `(device_id, key_id)` with do-nothing-on-conflict, so
  reused ids are silently dropped — same trap Android had).
- Re-publish on reinstall (new identity → new device; backend already revokes the
  superseded same-platform device).
- After shipping, have the existing iOS test users relaunch so they publish a fresh
  pool (the `0/0` users will then become messageable).

### C. Make bootstrap resilient + visible (small, high value)
- Retry `devices/register` / `ensurePrekeys` on `ApiError.Transport` (a few attempts
  with backoff) instead of giving up on the first timeout.
- Surface a non-blocking "couldn't connect — retrying" state so a failed bootstrap
  isn't invisible. Keep the `E2EManager` bootstrap logging (added this session,
  uncommitted locally) so logcat shows the cause.
- Consider raising/justifying the OkHttp `readTimeout` (currently 30s,
  [ApiClient.kt:52](../../apps/android/app/src/main/java/com/voiid/app/net/ApiClient.kt#L52)).

### D. If registration also times out on a REAL device (only if A fails)
Then it's a genuine client/transport issue, not the emulator. Check:
- TLS/cert chain to Caddy from the device; OkHttp connection-pool/IPv6 behaviour.
- Whether `auth/firebase` (login) succeeds but authenticated calls hang (would point
  at a header/proxy issue on authenticated requests).

### E. Still pending from before
- **Fallback / last-resort key** — the real backstop for a genuinely-exhausted offline
  peer. Needs the Rust/uniffi/NDK toolchain (`cargo` not available in this
  environment) to expose vodozemac's fallback key + regenerate bindings. See the
  2026-06-22 doc's follow-ups.

---

## Useful commands (for the box)

```bash
# SSH (no sshpass on the Mac — use an expect wrapper with the box password in VOIID_PW)
# pm2 status / logs
pm2 list ; pm2 logs voiid-api --nostream --lines 100

# DB has NO psql installed — query via Node + the project's pg (Supabase pooler URL in /opt/voiid/.env):
cd /opt/voiid && NODE_PATH=/opt/voiid/node_modules node /tmp/diag.js   # devices + prekey counts
```
(The `diag.js` used this session lists every device with its available/total one-time
prekeys and a per-user summary — recreate it from the query in the table above.)

---

## Status of earlier work (unchanged, already on 0.0.2 / dev)
- ✅ Backend: revoke stale same-platform devices on re-register; freshest-first
  ordering; `GET /prekeys/count` — **deployed & live**.
- ✅ Android: replenishment + monotonic key ids + bundle selection + send-error icon.
- ✅ Profile: real name / @username / phone (phone from saved contact).
- ✅ Animations: footer pill stretch + splash→Terms shared-element logo glide.
- ⏳ This session added **bootstrap logging** to `E2EManager` (diagnostic only; in the
  working tree — commit if keeping).
