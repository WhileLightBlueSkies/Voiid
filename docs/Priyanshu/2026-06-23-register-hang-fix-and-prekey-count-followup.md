# Fix + handoff (2026-06-23): device-register hang (base64) — and a new per-device prekey-count bug

Author: Priyanshu (via Claude Code session)
Branch: fix landed on `dev` as **PR #24** (`fix/base64-decode-register-hang`).
Backend: dev (`api-dev.voiid.app`, Vultr `139.84.209.49`) — **fix is deployed & live** (box HEAD `d61a90e`).
Follows up [2026-06-23-android-registration-investigation.md](2026-06-23-android-registration-investigation.md)
and [../Nehal/2026-06-23-ios-prekey-fix.md](../Nehal/2026-06-23-ios-prekey-fix.md).

---

## TL;DR

- The iOS prekey-pool fix (PR #23) was **correct but unverifiable**: `POST /v1/devices/register`
  **hung for every client** (iOS *and* Android), so no device ever registered and
  `ensurePrekeys` never ran. The retry logic from PR #23 fired exactly as designed — but
  every attempt timed out.
- **Root cause (one bug, two parts):** the server's `decode($n,'base64')` can't parse the
  **unpadded** base64 that vodozemac emits (`invalid base64 end sequence`), and because the
  async handlers don't catch the rejection (Express 4 doesn't auto-catch), **no HTTP response
  was ever sent** → the client hung to its socket timeout.
- **The Android "emulator network" theory from the prior doc was a red herring.** It reproduced
  identically on the iOS simulator on a healthy network. It was always server-side.
- **Fixed in PR #24 (deployed):** decode base64 in Node (`b64()` → `Buffer` bound as `bytea`)
  at all 8 sites, and an `asyncHandler()` so handler errors return a fast 400/500 instead of
  hanging. Re-verified: iOS + Android both register and publish a full prekey pool; a
  cross-account claim returns a one-time key (no 409).
- **New bug found (NOT yet fixed):** `GET /v1/prekeys/count` counts unconsumed keys
  **per-user across all devices**, not per-device — so a user's *second* device (e.g. Android
  after iOS, same number; or a web-linked companion) sees the first device's keys, decides it
  has enough, and uploads **0** of its own. Peers can then land on that 0-key device → 409.

---

## Root cause (confirmed live on the box)

The API error log was flooding:
```
[voiid:api] unhandledRejection: invalid base64 end sequence
```
That is a Postgres `decode(text,'base64')` error. Confirmed with real 32-byte keys via the pooler:
```
decode('<standard padded>',  'base64')  -> OK, 32 bytes
decode('<same, unpadded>',   'base64')  -> ERROR: invalid base64 end sequence   <-- matches the log
decode('<base64url>',        'base64')  -> ERROR: invalid symbol "-"
```
vodozemac emits **standard base64 without padding**, which Postgres' decoder rejects.

Why it **hangs** instead of erroring: the route handlers are `async` with no try/catch, and
Express 4 does not catch rejected promises from handlers. The rejection bubbled to the global
`process.on('unhandledRejection')` logger in [../../backend/api/src/index.ts](../../backend/api/src/index.ts)
— which only **logs** — so `res` was never sent and the client waited the full timeout
(iOS URLSession 60s, Android OkHttp 30s).

Evidence both clients hit the same wall:
```
iOS:     [VOIID] bootstrap: identity ready
         [VOIID] transport error (attempt 1/3..3/3): The request timed out.
         [VOIID] bootstrap FAILED: NSURLErrorDomain Code=-1001 timed out
Android:  I/VOIID bootstrap: identity ready
          W/VOIID transport error (attempt 1/3..3/3): timeout
          E/VOIID bootstrap FAILED  ApiError$Transport: timeout  (ApiClient.kt:82)
```
And the DB had **zero real registrations** — only 3 old iOS **test fixtures** whose
`identity_public_key` decodes to `IDKEY_ALICE` / `identity-key-A` / `BASE64IDKEYA` (9–14 bytes,
not 32-byte keys). So register had never actually worked for a real client.

Note: unauthenticated paths were always fast (`/health` 200 in ~0.3s; `register` with no/bad
auth → 401 in ~0.12s; `POST /auth/firebase` succeeded from the sim). Only a **valid,
authenticated** register — the one that reaches the `decode(...)` DB write — hung. That ruled
out the network and pointed straight at the handler.

---

## What was fixed (PR #24 — deployed)

`backend/api/src/util.ts` (new):
- `b64(value)` — decode base64 in Node (lenient: tolerates missing padding **and** the
  base64url alphabet) and return a `Buffer` to bind as Postgres `bytea`. Use this **instead of**
  SQL `decode($n,'base64')`. Matches the pre-existing `Buffer.from(...,'base64')` pattern in
  [../../backend/api/src/routes/mls.ts](../../backend/api/src/routes/mls.ts).
- `asyncHandler(fn)` — wraps an async route so a rejected promise is forwarded to the existing
  global error middleware (returns a clean 400/500 instead of hanging).

`decode($n,'base64')` replaced with `b64(...)` + handlers wrapped at **all 8 client-bytes sites**:
- [devices.ts](../../backend/api/src/routes/devices.ts) — `/register` (the blocker)
- [prekeys.ts](../../backend/api/src/routes/prekeys.ts) — `/upload` (signed + one-time), `/refresh`
- [mls.ts](../../backend/api/src/routes/mls.ts) — `/keypackages`, `/group-events`
- [messages.ts](../../backend/api/src/routes/messages.ts) — `/send`
- [linking.ts](../../backend/api/src/routes/linking.ts) — `/approve`

`tsc` clean; CI `deploy-dev.yml` succeeded; pm2 restarted.

---

## Re-verification (post-deploy)

| Check | Result | Evidence |
|---|---|---|
| iOS register + prekeys | ✅ | New device `9bf25fd3` (user `2a077ac0`, number `6351822668`), **real 32-byte** identity key, **50/50** one-time keys |
| Android register | ✅ | `bootstrap: registered device=5aad7952…` → `prekeys ensured` (no timeout) |
| Cross-account claim (no 409) | ✅ | `GET /v1/prekeys/<iOS user>` → **HTTP 200**, `one_time_prekey` present |
| DB source of truth | ✅ | see table below |

> The expected log "uploading **100** keys" is actually "uploading **50**" — vodozemac caps
> one-time keys at 50 (`maxOneTimeKeys()`). 50 = a full pool; update the expectation in the
> Nehal doc.

Device/prekey table after re-verification:
```
platform   user_id      device     avail  total  created
android    2a077ac0…    5aad7952    0      0     06-23 09:03   <-- see follow-up bug
ios        2a077ac0…    9bf25fd3   49     50     06-23 08:59   <-- iOS fix working
ios        972f271d…    aec31ee7    1      2     06-18 (old test fixture)
ios        3fe96ca4…    edb62b1a    0      0     06-17 (old test fixture)
ios        a5b96f4f…    b6debb34    0      0     06-17 (old test fixture)
```

---

## 🐞 New bug (NOT yet fixed): prekey count is per-user, not per-device

`GET /v1/prekeys/count` ([prekeys.ts](../../backend/api/src/routes/prekeys.ts)) counts unconsumed
one-time keys across **all** of the caller's active devices:
```sql
select count(*) from one_time_prekeys otp
  join devices d on d.id = otp.device_id
 where d.user_id = $1 and d.revoked_at is null and otp.consumed_at is null
```
`ensurePrekeys` (iOS + Android) calls this and skips replenishment when `available >= 20`.

So with number `6351822668` logged into **both** sims (one user `2a077ac0`, two devices):
the iOS device uploaded 50; when the **Android** device registered, `count` returned 49
(the iOS device's keys), Android saw "enough", and uploaded **0 keys of its own**.

`GET /v1/prekeys/:user_id` returns a bundle **per device, newest-first**, and "the client takes
the first bundle". So a peer can land on the 0-key device → the original 409:
```
GET /v1/prekeys/2a077ac0…  -> 2 bundles
  bundle[0] device=5aad7952 (android)  one_time_prekey = NULL     <-- would 409
  bundle[1] device=9bf25fd3 (ios)      one_time_prekey = key_id=101
```

**Who it affects:** multi-device users — same number on two platforms, or a web-linked
companion ([linking.ts](../../backend/api/src/routes/linking.ts)). Single-device users are fine.

**Recommended fix:** make the count (and therefore replenishment) **per-device**.
- The login JWT only carries `user_id` (see [../../backend/api/src/routes/auth.ts](../../backend/api/src/routes/auth.ts) /
  `issueToken`), so the server can't infer the calling device. Have the client pass its
  `device_id`: `GET /v1/prekeys/count?device_id=…`, and filter the count by that device.
- Update `E2EManager.ensurePrekeys` on **both** clients to send their `device_id`.
- This is a client + server change → a new PR + app rebuild (I did **not** deploy it unilaterally).

---

## Other notes / still open

- **`AUTH_DEV_BYPASS` is OFF on dev.** `dev:<phone>` is now rejected (`invalid or expired token`);
  both apps use **real Firebase**. Test with the Firebase test number `6351822668` / OTP `696969`
  (no real SMS). The old docs' "dev bypass" testing path no longer applies.
- **Old iOS test fixtures** (`972f271d`, `3fe96ca4`, `a5b96f4f`) are stale rows with non-key
  `identity_public_key` values — safe to delete to de-noise the DB.
- Still open from before: **fallback / last-resort key** for a genuinely-exhausted peer
  (needs the Rust/uniffi toolchain); group MLS persistence; media device test.
