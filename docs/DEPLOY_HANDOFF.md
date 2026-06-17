# VOIID — Deploy / Infra Handoff

> **Purpose:** single source of truth for the **deploy/infra dev**. Updated on every code push by the code-side dev.
> Split: code-side dev = all application code. Infra dev = provisioning, secrets, deploy, verify.
> Last updated: 2026-06-15

---

## How to read this doc
Each push adds a dated entry under **Change log**. The **Required infra state** section is the always-current "what must exist for the code to run" checklist — keep it true.

---

## Required infra state (keep current)

### Secrets / env vars the code reads
The code reads exactly these (verified against `process.env` usages). Set them per environment (dev/staging/prod) — never reuse secrets across envs.

| Var | Used by | Notes |
|---|---|---|
| `NODE_ENV` | all | `development` / `staging` / `production` |
| `API_PORT` | api | default 4000 |
| `WS_PORT` | websocket | default 4001 |
| `DATABASE_URL` | api | **Supabase pooler connection string** (Postgres host only — NOT Supabase Auth/Realtime). Use the *pooler* URL for serverless/many-conn. |
| `REDIS_URL` | api, websocket | presence, pub/sub, typing, **OTP rate-limit** |
| `JWT_SECRET` | api, websocket | **must be identical** across api + websocket (WS verifies tokens api issues). Generate a strong random per env. |
| `JWT_EXPIRY` | api | `30d` per spec §4.7 |
| `FIREBASE_SERVICE_ACCOUNT` | api (auth) | Firebase Admin service-account JSON (stringified) — verifies the client's Firebase ID token. Or `FIREBASE_SERVICE_ACCOUNT_PATH` to a file. |
| `AUTH_DEV_BYPASS` | api (auth) | dev only: `1` accepts `dev:<phone>` tokens at `/auth/firebase` without Firebase. MUST be unset/0 in prod. |
| `FIREBASE_CONFIG` | sms (future) | empty until provider wired |
| `R2_ACCOUNT_ID` / `R2_ACCESS_KEY` / `R2_SECRET_KEY` / `R2_BUCKET` | media (Phase 2) | not needed for Phase 0 |
| `SENTRY_DSN` | ops | set when Sentry stood up |

> `.env.example` in repo root is the template. Copy to `.env` (gitignored) locally; in CI these come from **GitHub Secrets** (§7.7).

### What infra dev needs to provision for Phase 0 smoke test
1. **Supabase Postgres** — already live; migrations 001–009 pushed. Provide the **pooler `DATABASE_URL`** so the API can connect. *(I need this from you — see "What I need" below.)*
2. **Redis** — needs to be reachable at `REDIS_URL`. Required for pub/sub relay AND the new OTP rate-limiter. Local Docker or a hosted instance both fine for dev.
3. (Later this phase) Vultr deploy of api + websocket, Sentry, Uptime Kuma, 100+ WS load test.

---

## What I need from you (infra dev) right now
To run the Phase 0 smoke test against live infra, I need:

- [ ] **Supabase pooler `DATABASE_URL`** (the connection-pooler string, not the direct one) for the **dev** project.
- [ ] **`REDIS_URL`** — either confirm I should spin up local Docker Redis, or give me a hosted dev Redis URL.

Drop these in `.env` (it's gitignored) or paste them to me. Nothing else is needed for the smoke test.

---

## Change log

### 2026-06-15 (f) — iOS dummy frontend built (all 20 screens)
Full interactive iOS app under `apps/ios/Voiid/` — **dummy data, NO backend, NO crypto** (per owner: "experience everything real" locally). Built to the Figma design (file `MDWkYefTASCc6Nf3ORRyeW` — Voiid App Design).
- **Screens**: onboarding (Splash/Terms/Phone/OTP/Signup/Create Profile), Chats grid + Groups, Chat detail (read/delivered/sent ticks, timestamps, date separators, typing, auto-reply), voice notes (record+playback), images (pick/send/fullscreen), AI chatbot, Clips (feed/fullscreen/comments/upload).
- **Structure**: `DesignSystem/`, `Models/`, `Onboarding/`, `Main/`. Uses Xcode **synchronized folders** → files auto-compile, no .pbxproj surgery.
- **Permissions** (camera/mic/photos/contacts) added to both Debug+Release target configs.

**For the OTHER DEV (build/test side):**
- Open `apps/ios/Voiid/Voiid.xcodeproj` in **Xcode 16+**, ⌘R. See `apps/ios/BUILD_NATIVE.md`.
- **Must add Urbanist-Bold.ttf** (Google Fonts, OFL) for the Splash/Terms logo — steps in BUILD_NATIVE.md.
- **Send screenshots** → pixel-tuning loop (I can't render SwiftUI here; built to exact Figma values, shadows/spacing may need nudges).

**No infra action.** Frontend only; backend untouched.

### 2026-06-15 (e) — Full backend built + verified ✅ (27/27)
Built out the complete Phase 0/1 backend API (all routes the schema supports). New endpoints + features:
- **Conversations**: `POST /conversations/create` (direct idempotent + group w/ admin roles), `GET /conversations` (list + last-msg preview + unread count), `GET /conversations/:id` (members; non-members 403).
- **Users/profile**: `GET /users/:id`, `POST /users/profile/update`, `GET /users/status/:id` (Redis presence), `POST /users/consent` (DPDP), `DELETE /users/me` (soft-delete + revoke devices).
- **Contacts**: `POST /contacts/sync` (resolved user_ids only — **rejects raw phone numbers**), `GET /contacts` (saved_name override).
- **Receipts**: `POST /receipts/mark` (delivered/read, notifies sender, clears pending), `GET /receipts/:message_id`.
- **Device linking (Web companion)**: `POST /linking/request` → QR token, `POST /linking/approve` (authed), `GET /linking/poll/:token`.
- **WS**: typing indicators (TTL 5s) + presence heartbeat fan-out via Redis.
- **Security**: per-IP + per-route rate limiting; `security_events` logging (otp_abuse, failed_login, device_link).
- **Crypto seam**: `packages/common-utils/src/crypto.ts` — server stays ciphertext-only; libsignal drops in client-side post-legal. `assertOpaque` guard rejects plaintext-ish relay payloads.

All 3 services typecheck clean; common-utils now has a tsconfig + builds. Smoke test `/tmp/voiid-smoke2.mjs` = **27/27 pass**.

**Infra: still no new requirement** — same `DATABASE_URL` + `REDIS_URL`. (Linking + typing use Redis, already provisioned.)

### 2026-06-15 (d) — Phase 0 smoke test PASSED ✅ (21/21)
Full backend flow verified against live Supabase + Upstash Redis (script: `/tmp/voiid-smoke.mjs`):
- health (db+redis up) · request-otp · verify-otp→JWT · wrong-code rejected · auth-required enforced
- device register (A+B) · prekey upload · bundle fetch · **one-time prekey consumed atomically** (101 then 102)
- message send → **B receives over WS via Redis pub/sub** · **server stored ciphertext only / no plaintext column** (golden rule ✓)
- pending (offline) fetch · history pagination · **OTP rate limit** kicks in

**Known gaps surfaced (code-side, NOT infra):**
- **No `/conversations` API yet** (spec §10 lists create/list/get). Smoke test seeded conversation+members directly in DB. Needed before Phase 1 client.
- SMS still stubbed — verify-otp tested by seeding a known OTP hash; real provider pending blocker #3.

**Infra: nothing required for this entry.** Next infra items: deploy api+ws to Vultr (dev), Sentry, Uptime Kuma, 100+ WS load test.

### 2026-06-15 (c) — Connectivity GREEN ✅
- **Redis (Upstash):** PING → PONG ✓
- **Supabase Postgres (pooler):** connected via the ap-south-1 (Mumbai) transaction pooler on `:6543` ✓ (exact host + creds live in `.env`, gitignored). All **11 tables** present (migrations live): users, devices, signed_prekeys, one_time_prekeys, otp_sessions, conversations, conversation_members, messages, message_read_receipts, contact_sync, security_events.
- Correct `DATABASE_URL` form (for staging/prod too): `postgresql://postgres.<ref>:[PW]@aws-1-<region>.pooler.supabase.com:6543/postgres`.

### 2026-06-15 (b) — Connectivity check + DB SSL + Upstash confirmed
**Verified:**
- **Redis (Upstash)** — connects, `PING` → `PONG` ✓. Upstash is the chosen dev Redis. Use the `rediss://` (TLS) URL, not the REST endpoint.
- **Postgres** — FAILED with the current `DATABASE_URL`: it's the **direct** host (`db.<ref>.supabase.co`) which is IPv6-only / unresolvable here.

**Action required (infra dev):** replace `DATABASE_URL` with the **Supabase pooler** string:
`postgresql://postgres.<project-ref>:[PASSWORD]@aws-0-<region>.pooler.supabase.com:6543/postgres`
(Dashboard → Settings → Database → Connection string → **Connection pooling**, Transaction mode.)

**Code change:** `backend/api/src/db.ts` now enables TLS automatically for non-local `DATABASE_URL` (Supabase requires SSL). Local Postgres still connects without SSL.

### 2026-06-15 — OTP hardening + env scaffolding
**Code changes (by code-side dev):**
- `backend/api/src/routes/auth.ts`: OTP now generated with crypto-safe `randomInt` (was `Math.random`); added **per-phone OTP rate limiting** via Redis (3 / 15 min, §4.9).
- Created root `.env` from `.env.example` with a generated dev `JWT_SECRET`.

**Infra action required:**
- The API now uses **Redis** in the OTP path (rate-limit keys), so Redis MUST be up for `/auth/request-otp` to work — previously Redis was only needed for the relay/WS.
- Provide `DATABASE_URL` (Supabase pooler) + `REDIS_URL` as above.

**Decisions locked this session:**
- **Own JWT** (NOT Supabase Auth) — per §2.2; identity/sessions stay in our Postgres, tied to device/prekey model.
- SMS provider stays **stubbed** until blocker #3 (Firebase India OTP pricing vs MSG91) is decided. No real SMS goes out yet.
