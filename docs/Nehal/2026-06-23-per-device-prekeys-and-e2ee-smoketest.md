# Voiid — Handoff (2026-06-23): per-device prekey count + E2EE smoke test

Branch: `0.0.2` → merged to `dev` as **PR #25** (auto-deploys). Backend (dev): `https://api-dev.voiid.app`.
Follows [Priyanshu's register-hang + prekey-count follow-up](../Priyanshu/2026-06-23-register-hang-fix-and-prekey-count-followup.md)
and [the iOS prekey fix](2026-06-23-ios-prekey-fix.md).

## ✅ Done this session

### 1. Confirmed the shipped base64/asyncHandler fix (PR #24) — code + live API
- **No `decode(…,'base64')` left** in any route — all client bytes go through `b64()`
  (`backend/api/src/util.ts`); handlers wrapped in `asyncHandler`.
- Live: `/health` 200 (~0.38s), `/v1/prekeys/count` → 401 (route live + guarded).
- ⚠️ pm2-log / DB checks were **not** run here (need the box SSH password, unavailable
  in this environment) — run those from the build-machine session.

### 2. Fixed the per-device prekey-count bug (client + server) — PR #25
**Bug:** `GET /v1/prekeys/count` summed unconsumed one-time keys across **all** the
caller's devices. A user's 2nd device (same number on iOS+Android, or a web companion)
saw the 1st device's keys, decided it was full, uploaded **0** of its own → a peer who
landed on that 0-key device got a null `one_time_prekey` → **409**.

**Fix:**
- Backend `prekeys.ts` `/count` now takes `?device_id=` and filters by it. The join
  still scopes to the caller's own devices, so a foreign device_id counts 0. No
  `device_id` keeps the old per-user behaviour (back-compat). Wrapped in `asyncHandler`.
- iOS `E2EManager.availableCount(deviceId:)` and Android `availableCount(devId)` now
  pass their own device id → each device replenishes its OWN pool. Watermark unchanged
  (replenish when `< 20`, toward `min(target, maxOneTimeKeys())`).

### 3. E2EE smoke test — GREEN (run locally; cargo available)
`cd packages/e2e-core && cargo test --release` → **47/47** passing (roundtrip, PQXDH,
ratchet ordering, group MLS, media, multidevice, hardening, robustness/garbage-input,
tamper-rejection, safety-numbers), **+ 3/3 soak** (`--test soak -- --ignored`:
1:1 / group churn / media stream). **50/50, 0 failed.** Backend `tsc` clean.
> The clean-room E2EE **core** is verified correct. This does NOT verify the
> app↔backend wiring — that still needs the device check below.

## 🔑 Important env notes (carried from the smoke prompt)
- `AUTH_DEV_BYPASS` is **OFF** — use the Firebase **test number 6351822668 / OTP 696969**.
- iOS one-time-key pool caps at **50** (vodozemac), so "50/50" = a full pool (not 100).
- Box: no key-auth SSH (expect wrapper + `VOIID_PW`); no `psql` (query via Node + `pg`,
  `DATABASE_URL` from `/opt/voiid/.env`, read with a regex — one line is unquoted, don't `source`).
- Mint a test JWT on the box: `jsonwebtoken.sign({user_id}, JWT_SECRET)` (requireAuth
  only checks the signature).

## ▶️ Still to verify on devices / box
1. **Multi-device 409 repro is gone:** same number into iOS sim + Android emulator →
   `GET /v1/prekeys/<user_id>` returns a bundle per device, **each with a non-null
   `one_time_prekey`**; both devices show ~50 keys in the DB.
2. **No-409 single device** (already claimed working in PR #24) still holds.
3. pm2 has no new `unhandledRejection: invalid base64` lines.

## 🚧 Open (unchanged)
- Group MLS app side (needs e2e-core `GroupMember`/`GroupSession` persistence in Rust).
- Fallback/last-resort key for a genuinely-exhausted offline peer (Rust/uniffi/NDK).
- Media live device test; Clips/AI/Calls still DummyData; safety-number UI; push.
