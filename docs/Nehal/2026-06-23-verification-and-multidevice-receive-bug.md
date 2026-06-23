# Verification handoff (2026-06-23): PR #25 per-device prekeys VERIFIED + a new multi-device RECEIVE/decrypt bug

Verifier session on the build machine. Branch verified: `dev` @ `3ec7d46` (Merge PR #25).
Backend (dev): `https://api-dev.voiid.app` (Vultr `139.84.209.49`) — live.
Follows [per-device prekeys + E2EE smoke test](2026-06-23-per-device-prekeys-and-e2ee-smoketest.md)
and [Priyanshu's register-hang/prekey-count follow-up](../Priyanshu/2026-06-23-register-hang-fix-and-prekey-count-followup.md).

> **No fix was applied this session** (per instruction: stop at diagnosis). A diagnostic
> log line was added to `ChatEngine.kt` to surface the swallowed error, then **reverted** —
> the tree is clean. Recommended fix is described below for the next session.

---

## TL;DR

- **PR #25 (per-device prekey count) is VERIFIED — PASS.** Each device now maintains its own
  one-time-key pool; the multi-device 409 is gone.
- **But real 1:1 messaging still "doesn't go through"** — and it's a **different bug**, on the
  **receive** side: when the **sender is multi-device**, the recipient can't decrypt the
  message. `acceptSession` throws `E2eFfiException$DecryptionFailed`, the error is **silently
  swallowed**, and the recipient shows an **empty chat**.
- Root cause: the recipient resolves the **sender's** identity key to the sender's *first*
  device (`devices.firstOrNull()`), but a multi-device sender may have encrypted with a
  *different* device — and `sender_device_id` is **null** on the message. Wrong identity key →
  decrypt fails.

---

## Verification results

| Step | Result | Evidence |
|---|---|---|
| 0. e2e-core `cargo test --release` | ✅ PASS | **47 passed, 0 failed**; soak `--ignored` **3 passed** (50/50) |
| 1. base64 fix holds | ✅ PASS | `grep "decode($" routes` empty; pm2 `invalid base64` count flat at **54**, error log untouched since 08:38 UTC despite new registrations |
| 2. per-device prekey count (PR #25) | ✅ PASS | Android (the prior 0-key device): `ensurePrekeys: available=0 → uploading 50 keys`. Counts: `?device_id=iOS`→**48**, `?device_id=android`→**50**, no-param→**98**. Claim `GET /v1/prekeys/<user>` → 2 bundles, **both non-null** (no 409) |
| 3. DB device/prekey table | ✅ PASS | user `2a077ac0` has **two** active rows: ios `9bf25fd3` 48/50, android `5aad7952` 50/50 — no 0-key device |
| 4. cross-account send + decrypt | ⚠️ **SEND ok / RECEIVE FAILS** | iOS→Nehal send: `[VOIID] ✅ sent … conv=6ad57cbf` (no 409). Backend stores + serves the ciphertext (Nehal `GET /conversations` shows `unread=3`; `GET /messages/conversation/6ad57cbf` returns 3 ciphertexts). **Recipient app shows an empty chat — all 3 fail to decrypt.** |

Test accounts: `2a077ac0` = Priyashnu / `6351822668` (logged into **both** iOS sim + Android
emulator → multi-device). `b39b7e49` = Nehal Test / `6969696969` (single device). Firebase
test OTP `696969`.

---

## 🐞 New bug: multi-device sender → recipient can't decrypt (`acceptSession` DecryptionFailed)

**Symptom:** "message flow not going through." Sender sees ✓ (sent); recipient's chat is empty.

**Exact error** (captured by temporarily un-swallowing the failure in `ChatEngine.sync`):
```
sync: fetched 3 msgs conv=6ad57cbf
inbound decrypt FAILED id=44aa7478 ctlen=356
uniffi.voiid.E2eFfiException$DecryptionFailed:
  at uniffi.voiid.Identity.acceptSession(voiid.kt:3263)
  at com.voiid.app.net.ChatEngine.decryptInbound(ChatEngine.kt:249)
```
All 3 inbound messages fail the same way.

**Root cause (code-confirmed):**
1. The recipient needs the **sender's** identity key to `acceptSession`. It fetches it with
   `peerIdentityKey()` → `GET /v1/devices/<senderUserId>` → **`devices.firstOrNull()`**
   ([android ChatEngine.kt:287-290](../../apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt#L287-L290);
   iOS `ChatEngine.peerIdentity` is the same — `env.devices.first`).
2. `GET /devices/:user_id` orders `last_seen_at desc nulls last, created_at desc`. The sender
   Priyashnu is multi-device; the **android** device (`5aad7952`, newer `created_at`) sorts
   first, but the message was encrypted by the **iOS** device (`9bf25fd3`).
3. `messages.sender_device_id` is **null** in the DB — the iOS sender doesn't populate it
   ([messages.ts insert passes `device_id ?? null`](../../backend/api/src/routes/messages.ts)),
   so the recipient has no way to know which device actually sent it.
4. → `acceptSession(wrongIdentityKey, wire)` → MAC/identity mismatch → `DecryptionFailed`.

**Aggravating bug:** `ChatEngine.sync` wraps decrypt in `runCatching { … }` with **no
`onFailure`** ([android ChatEngine.kt:202-208](../../apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt#L202-L208);
iOS equivalent). So every inbound decrypt failure is **silent** — no log, message just
disappears. This is why it looked like "nothing happens."

**Why it was missed:** single-device peers work (first device == the only device). The bug
only bites when the **sender** is multi-device — exactly Priyashnu's test setup (same number
on iOS + Android). Same multi-device family as PR #25, but on the **receive/identity** side.

---

## ✅ Recommended fix (next session — NOT applied here)

1. **Carry the sender device on the message.** Populate `sender_device_id` on send (client
   includes its `device_id`; it's already a column). On receive, resolve the sender's identity
   key by **that** `sender_device_id` (look it up in `GET /devices/<sender>`), not
   `devices.first`. Do this on **both** iOS and Android.
2. **Stop swallowing decrypt errors.** Add `.onFailure { log }` to the `sync` `runCatching` on
   both clients so failures are visible (and consider surfacing a "couldn't decrypt" placeholder
   instead of dropping the message).
3. (Related, from the prior doc) The **send** side also only targets the peer's first device
   (`bundles.first`) — true multi-device delivery (encrypt to every recipient device, and accept
   from any sender device) is the broader fix. Minimum to make 1:1 work: items 1–2.

---

## Env notes (carried)
- `AUTH_DEV_BYPASS` is **OFF** — Firebase test numbers only: `6351822668` and `6969696969`,
  OTP `696969` (no SMS). reCAPTCHA may appear on iOS; it auto-resolves.
- iOS/Android one-time-key pool caps at **50** (vodozemac) — 50 = full.
- Box: expect-wrapper SSH (`/tmp/voiid-ssh.exp` + `VOIID_PW`); no `psql` (Node + `pg`,
  `DATABASE_URL` from `/opt/voiid/.env`, read via regex — one line is unquoted, don't `source`).
- Mint a test JWT on the box: `jsonwebtoken.sign({user_id}, JWT_SECRET)` (requireAuth only
  checks the signature). Useful for `GET /v1/prekeys/count?device_id=…`, `/v1/prekeys/<user>`,
  `/v1/messages/conversation/<id>`.

## Still open
- Multi-device receive/decrypt (this doc) — **the blocker for real 1:1 messaging.**
- Multi-device **send** fan-out (encrypt to all recipient devices).
- Group MLS app side; media live device test; Clips/AI/Calls still DummyData; push.
