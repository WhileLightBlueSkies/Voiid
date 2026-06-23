# Voiid — Handoff (2026-06-23): iOS prekey-pool fix + bootstrap resilience

Branch: `0.0.2`. Backend (dev) unchanged this session.
Fixes the device-independent root cause from Priyanshu's
[android-registration-investigation](../Priyanshu/2026-06-23-android-registration-investigation.md).

## Context (from Priyanshu's diagnosis)
Two independent reasons 1:1 chat failed:
1. **iOS never replenishes its prekey pool** → registered iOS users sit at 0–1
   available one-time keys → every send to them returns `409 peer has no available
   prekeys`. **Device-independent product bug — fixed here.**
2. **Android device-register timed out** on the test **emulator** (degraded
   emulator network over long uptime). Environmental — needs a **real device /
   cold-booted emulator** to confirm; not a code fix. (Mitigated below with retry.)

## ✅ Fixed this session

### iOS `E2EManager` — register + maintain a prekey pool (mirrors Android)
`apps/ios/.../Networking/E2EManager.swift`:
- **Register** publishes only the long-term identity key (`publishBundle(0)`); one-time
  keys are managed separately (was: one-shot `publishBundle(100)` that never refilled).
- **`ensurePrekeys`**: `GET /v1/prekeys/count` → if `available < 20`, `replenishPrekeys`
  toward **100** (capped at `maxOneTimeKeys()`), persists the identity **before**
  upload, then uploads.
- **Monotonic key ids** persisted in Keychain (`prekey_next_id`, base 100) — the
  server keys on `(device_id, key_id)` do-nothing-on-conflict, so reused ids would be
  silently dropped (the exact trap Android hit).
- Logging: `[VOIID] bootstrap: …` / `ensurePrekeys: available=…/uploading…`.

### Bootstrap resilience (both platforms)
- `withTransportRetry` wraps `register` + `ensurePrekeys`: 3 attempts with backoff on
  `ApiError.transport` (timeouts / flaky net) instead of failing permanently on the
  first hiccup. Added to **iOS and Android**.

## ▶️ To verify (needs devices)
1. **iOS:** build + relaunch the existing iOS test users (`0/0` prekey ones). Expect
   logcat/console `ensurePrekeys: uploading 100 keys`, and their DB `avail ≈ 100`.
   Then a send to them should succeed (no more 409).
2. **Android registration:** cold-boot the emulator (`adb emu kill` →
   `-no-snapshot-load`) **or** use a real device; watch `adb logcat | grep VOIID` for
   `bootstrap: registered device=…` and a new **android** row in the DB with
   `avail ≈ 100`. (This was the emulator-network stall, not yet confirmed on real hw.)

## 🚧 Still open
- **Confirm Android register on real hardware** (root cause #2 — environmental).
- **Fallback / last-resort key** for a genuinely-exhausted offline peer — needs the
  Rust/uniffi/NDK toolchain to expose vodozemac's fallback key (per Priyanshu's doc).
- Group MLS (e2e-core group persistence, Rust); media device test; Clips/AI/Calls.
- Optionally call `ensurePrekeys` on app **resume** too (currently launch-only).
