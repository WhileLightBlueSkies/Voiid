# Voiid — Handoff (2026-06-23): multi-device 1:1 RECEIVE fix

Branch: `0.0.2` → merged to `dev` as **PR #26** (auto-deploys). Backend (dev): `https://api-dev.voiid.app`.
Fixes the receive-side blocker from
[the verification + multi-device receive bug doc](2026-06-23-verification-and-multidevice-receive-bug.md).

## The bug
When the **sender** was multi-device (e.g. same number on iOS + Android), the recipient
couldn't decrypt: `acceptSession` → `E2eFfiException$DecryptionFailed`, swallowed by
`runCatching` → recipient's chat stayed empty. Cause: recipient resolved the sender's
identity key to the sender's *first* device, but the message was encrypted by a
**different** device, and `messages.sender_device_id` was null so there was no way to
pick the right one.

## ✅ Fixed (backend + iOS + Android) — PR #26
- **Backend** `POST /messages/send`: stores `sender_device_id` from the request body
  (the JWT may not carry a device id, so the client sends it). `GET
  /messages/conversation/:id` now **returns `sender_device_id`**.
- **Clients send their own `device_id`** on every send (text + media).
- **On receive**, resolve the sender's identity key by the message's `sender_device_id`
  (match in `GET /v1/devices/<sender>`), falling back to the first device if absent —
  so a multi-device sender decrypts correctly.
- **Identity pin keyed per (peer, device)** (`idpin_<user>_<device>`): a multi-device
  peer legitimately has a different key per device, so this avoids a false MITM (495)
  while still catching a real key-swap on a given device.
- **`sync()` logs decrypt failures** (`[VOIID] ❌ inbound decrypt FAILED id=… senderDev=…`)
  instead of silently dropping. NOT persisted as a placeholder, so a transient failure
  is retried on the next sync (once decryptable, it appears).

## Verified here
- Backend `tsc` clean. e2e-core `cargo test --release` = **47 + 3 soak, 0 failed**.
- ⚠️ App↔backend path needs the **device repro** below (no toolchain/box in my env).

## Env (carried)
- `AUTH_DEV_BYPASS` OFF. Firebase test numbers **6351822668** + **6969696969**, OTP **696969**.
- One-time-key pool caps at **50** (vodozemac) — 50 = full.
- Box: expect-wrapper SSH + `VOIID_PW`; no psql (Node + pg, `DATABASE_URL` from
  `/opt/voiid/.env`, regex-read, don't `source`). Mint JWT: `jwt.sign({user_id}, JWT_SECRET)`.

## ▶️ Verify on devices
Multi-device sender (6351822668 on iOS sim + Android emulator) → recipient (6969696969):
1. Send iOS(6351822668) → Nehal: message **arrives + decrypts** (was empty). No
   `DecryptionFailed` in logcat/console.
2. Reverse (Nehal → 6351822668) and a **2nd** message (ratchet) both decrypt.
3. DB: the message row has a non-null `sender_device_id`; the recipient's store shows
   the decrypted text.

## 🚧 Still open
- Full multi-device **fan-out** (encrypt to every recipient device; accept from any
  sender device) — the minimal a+b+c here makes 1:1 work for the common case.
- Group MLS app side (e2e-core group persistence, Rust); media live device test;
  fallback/last-resort key; Clips/AI/Calls; safety-number UI; push.
