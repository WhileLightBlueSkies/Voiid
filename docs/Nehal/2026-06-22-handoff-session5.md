# Voiid — Handoff (2026-06-22, session 5)

Branch: `0.0.2` → merged to `dev` (PRs #19, #20). Backend (dev): `https://api-dev.voiid.app`.
Focus: **main-chat search shows contacts** + **API versioning / client-compat architecture**.

---

## ✅ Done this session

### 1. Main-chat search now surfaces contacts (PR #19)
Search on the chats home only filtered existing conversations, so a contact you
hadn't messaged ("not started" chat) never appeared. Now search also lists matched
VOIID contacts (minus ones you already chat with) under a **"Start new chat"**
section — tap to create the 1:1 and open it. iOS + Android. Chats tab only;
gracefully empty if contacts permission isn't granted.
- iOS: `Main/ChatsHomeView.swift` (contactResults + Start-new section).
- Android: `main/ChatsHomeView.kt` (SearchChatRow/SearchContactRow, LazyColumn results).

### 2. API versioning & client-compatibility architecture (PR #20)
See [`docs/API_VERSIONING.md`](../API_VERSIONING.md) for the full spec. Summary:

- **Path versioning** — all routes mounted at `/v1` **and** legacy root (migration
  alias) in `backend/api/src/index.ts`. `/v1` is additive-only; breaking → `/v2`.
- **`GET /config`** (`routes/config.ts`, unversioned + ungated) — version, feature
  flags, min app version, per-caller `force_update`, SDUI seam. Apps fetch on launch
  (`ConfigService`).
- **Force-update gate** (`version.ts`) — clients send `X-Voiid-Platform / App-Version
  / Api-Version`; below the per-platform min → **HTTP 426**; both apps show a blocking
  update screen. Tunable via env: `MIN_APP_IOS`, `MIN_APP_ANDROID`, `FORCE_CUTOFF`.
- **SDUI** — seam only in `/config.sdui`, **deferred** until Clips is built.
- Android: enabled `buildConfig=true` for `BuildConfig.VERSION_NAME`.

---

## ⚠️ Gotchas / how to verify (READ THIS)

- **`/v1` IS deployed and working.** Verify by curling a REAL route and expecting
  **401** (route exists, auth-guarded):
  ```
  curl -s -o /dev/null -w "%{http_code}" https://api-dev.voiid.app/v1/conversations   # → 401 ✅
  curl -s https://api-dev.voiid.app/config                                            # → 200 {api_version:"v1",...}
  ```
- **Do NOT test `/v1/health`** — it 404s **by design**. `/health` and `/config` are
  intentionally **top-level/unversioned** (the client must reach `/config` before it
  knows the version). 404 there is correct, not a bug.
- **Deploy = merge to `dev`** → auto-deploys to `api-dev.voiid.app`. (Confirmed:
  `/config` returned 200 after #20 merged.)
- **Feature flags / force-update are server-driven** — flip `/config` flags or set the
  env vars on the box; no app release needed.

---

## 🚧 Still open (unchanged from session 4)
- **1:1 live verify** — fixes are deployed; still needs 2 accounts on a device, OR run
  `backend/scripts/verify-1to1.mjs` with two JWTs. Send path logs `[VOIID] ✅/❌`.
- **Apply `011_mls.sql`** to the Voiid Supabase (only pending migration; no runner).
  Everything else (001–010) is applied.
- **Group messaging (MLS)** — backend plumbing done; blocked on adding
  `GroupMember`/`GroupSession` `toPickle`/`restore` in e2e-core (Rust, needs the
  native build box) before app `GroupEngine`.
- **Media live test** — code + R2 ready (`/health` → `media.configured:true`); needs a device check.
- **Clips / AI / Calls** still DummyData; SDUI (clips) waits on Clips being built.
- Safety-number UI, push notifications, prod box/DB split + store pipelines.

---

## Verification status
| Item | Status |
|---|---|
| `/v1` versioning + `/config` live | ✅ verified via curl (401 on real routes; 200 /config) |
| Contact search in chats home | code complete; ⏳ device check |
| Force-update screen (both apps) | code complete; ⏳ device check |
| 1:1 crypto end-to-end | ⏳ device-only |
| Group-MLS app | ⛔ blocked on e2e-core group persistence (Rust) |
