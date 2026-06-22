# Voiid — Handoff (2026-06-22, session 3)

Branch: `0.0.2` → merged to `dev` (PR #17). Backend (dev): `https://api-dev.voiid.app`

Focus: **1:1 messaging was not reaching the server** ("nothing in Supabase"),
plus offline visibility + refresh. Found and fixed the root cause + a receive-path
bug, and made messages persist/queue offline.

---

## ✅ Fixed this session

### 🔴 Root cause — messages never reached the backend (Android)
`POST /conversations/create` returns a **flat** `{ conversation_id }`. iOS was
already fixed to that; **Android still decoded `{ conversation: { id } }`**, so
`createDirect` threw, the conversation was never created, and **no message could
be sent** → nothing in Supabase. Fixed `ChatService.kt` to the flat shape.

### 🔴 Receive path — inbound couldn't decrypt
`GET /devices/:id` did **not** return `identity_public_key`, which the
`acceptSession` (first inbound PreKey message) path requires. Added it to the
backend select (base64; it's public). **This is a backend change — it deploys on
the merge to `dev`.**

### Offline + refresh (WhatsApp-like) — both platforms
- Text messages persist to the local store as **PENDING** the moment you hit send
  → visible instantly, **offline**, and across app restarts. A background flush
  sends them; failures stay queued and **auto-retry** on next open / sync /
  reconnect (`ChatEngine.enqueueText` + `flushPending`).
- The local **decrypted** store is the single source of truth — reopening a chat
  shows history with no network. Sent bubble shows ⏲ until accepted, then ✓.

### Diagnostics
Send path now logs `[VOIID] ✅ sent…` / `[VOIID] ❌ sendText FAILED…`
(NSLog / android.util.Log) — the exact failure point is visible in Xcode console
/ logcat.

### Profile + group pages
Confirmed both already fetch **live** data on open (`ContactProfileView` →
`GET /users/:id`; `GroupInfoView` → `GET /conversations/:id` members). The only
remaining dummy there is the **shared-media** grid (needs media history — later).

---

## ▶️ To verify (needs a device — no toolchain in my session)
1. Pull `dev`, confirm `/health` is up. The `devices` fix is deployed.
2. Build iOS + Android. Sign in **two** accounts (real OTP or `AUTH_DEV_BYPASS=1`).
3. New chat → send a text. Expect: Supabase `messages` gets a row; logcat/Xcode
   shows `[VOIID] ✅ sent`; the peer receives it.
4. If it still fails: grab the `[VOIID] ❌ …` log line — it names the failing step
   (peer resolve / prekey bundle / session / POST).

---

## 🚧 Still open (sequenced — do after 1:1 is confirmed working)
- **Make everything E2EE / group messaging (MLS):** group sends are still local
  echo only; needs the OpenMLS `GroupSession` path wired (send + receive). This is
  the "make each and everything e2ee" item — the largest remaining piece.
- **Media live:** still needs the **R2 env on the box** (`/media/*` = 503 until
  then) + token roll (from session 1/2).
- **True push-realtime for profile/group** (membership/profile change events over
  WS) — currently fetch-on-open.
- Shared-media grid (profile/group) — needs media history.
- Safety-number UI, push notifications, Clips/AI/Calls still dummy.
