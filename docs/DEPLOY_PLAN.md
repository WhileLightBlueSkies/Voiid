# VOIID — Backend Deployment Plan

> How to deploy the backend (api + websocket) for dev/staging/prod. The code is
> stack-portable: Supabase Postgres + Redis + two Node services behind TLS.
> Secrets live in the host's secret store — NEVER in the repo, never in code.
>
> Last updated: 2026-06-17

## What gets deployed

| Service | What | Port (dev) | Scales |
|---|---|---|---|
| `backend/api` | REST API (auth, devices, prekeys, conversations, messages, receipts, contacts) | 4000 | horizontally (stateless; JWT-auth) |
| `backend/websocket` | Real-time relay (presence, typing, ciphertext push) | 4001 | horizontally (Redis pub/sub fans out across instances) |

External managed services (already in use):
- **Supabase Postgres** (ap-south-1) — `DATABASE_URL` (pooler). Migrations already applied.
- **Upstash Redis** — `REDIS_URL` (rediss://, TLS). Presence, pub/sub, rate-limit.
- **Cloudflare R2** (later, for media) — `R2_*`.

## Environments

Three isolated environments — separate DB, Redis, secrets, URLs. Never share a
JWT_SECRET or DB across envs.

| | dev | staging | prod |
|---|---|---|---|
| NODE_ENV | development | staging | production |
| Auth | `AUTH_DEV_BYPASS=1` (dev tokens) | Firebase (test project) | Firebase (prod project) |
| TLS | http://localhost ok | HTTPS required | HTTPS required |
| Cleartext on apps | allowed | off | off |

## Required env vars (set in the host secret store)

```
NODE_ENV=production
API_PORT=4000
WS_PORT=4001
DATABASE_URL=postgres://...pooler.supabase.com:6543/postgres   # TLS
REDIS_URL=rediss://...upstash.io:6379                          # TLS
JWT_SECRET=<strong random, UNIQUE per env>                      # api + ws MUST match
JWT_EXPIRY=30d
FIREBASE_SERVICE_ACCOUNT=<service-account JSON, stringified>    # prod/staging auth
# AUTH_DEV_BYPASS — set ONLY in dev; MUST be unset/0 in staging+prod
# R2_* — when media ships
# SENTRY_DSN — when monitoring stood up
```

> The code loads these via `--env-file` in dev. In prod, inject them as real
> environment variables from the platform's secret manager (do NOT ship a
> committed `.env`).

## Deploy options (pick one host)

The services are plain Node + a `start` script (`node --env-file=... dist/index.js`,
or run TS via `tsx` in dev). Any of these work:

### Option A — Container (recommended, portable)
1. Add a `Dockerfile` per service (Node 20+ base, `npm ci`, `npm run build`, `CMD node dist/index.js`).
2. Push images; run on **Vultr / Fly.io / Railway / Render / a VM**.
3. Put **TLS + a reverse proxy** (Caddy/Nginx/Cloudflare) in front: `api.voiid.app` → :4000, `ws.voiid.app` → :4001 (WebSocket upgrade enabled).
4. Inject env vars from the platform secret store.

### Option B — PaaS (fastest to first deploy)
- **Railway / Render / Fly.io**: point at the repo, set the build (`npm run build -w @voiid/api`) and start (`npm run start -w @voiid/api`) commands, add env vars in the dashboard. Deploy `api` and `websocket` as two services. They give you HTTPS automatically.

### Option C — Single VM (cheapest, most manual)
- Vultr/EC2: install Node, clone, `npm ci`, build, run both services under **pm2** or systemd, Caddy in front for TLS + WS upgrade.

## Step-by-step (first deploy)

1. **Pick host** (Option A/B/C). PaaS is fastest for staging.
2. **Provision secrets** in the host: copy the env table above, generate a fresh
   `JWT_SECRET`, paste the real `DATABASE_URL`/`REDIS_URL`, and the
   `FIREBASE_SERVICE_ACCOUNT` JSON (see Firebase setup below).
3. **Build:** `npm ci && npm run build -w @voiid/common-utils && npm run build -w @voiid/api && npm run build -w @voiid/websocket`.
4. **Run:** `api` and `websocket` as separate processes/containers.
5. **Front with TLS:** map `https://api.<domain>` → api, `wss://ws.<domain>` → websocket (ensure the proxy allows WebSocket upgrade + long-lived connections).
6. **Verify:** `GET https://api.<domain>/health` → `{db:"up",redis:"up"}`.
7. **Point the apps** at the deployed URLs: iOS `APIConfig.baseURL/wsURL`,
   Android `ApiConfig.baseUrl/wsUrl`. Turn OFF cleartext on Android for prod.
8. **Turn auth real:** unset `AUTH_DEV_BYPASS`, set `FIREBASE_SERVICE_ACCOUNT`.

## Firebase setup (who does what)

**The dev (you) provisions all Firebase creds — they never go in the repo or to anyone else.**

Server (token verification):
1. Firebase Console → Project Settings → **Service accounts** → "Generate new private key" → downloads a JSON.
2. Set it as the `FIREBASE_SERVICE_ACCOUNT` env var (stringified JSON) in the host secret store. Done — the server's `firebase.ts` verifies real ID tokens.

Apps (phone auth + token):
1. Firebase Console → enable **Phone** sign-in provider.
2. iOS: add the app, download **`GoogleService-Info.plist`** into the Xcode project; add the Firebase Auth SDK (SPM).
3. Android: add the app, download **`google-services.json`** into `app/`; add the Firebase Auth SDK + google-services Gradle plugin.
4. Wire the screens: replace `AuthService.devLogin(...)` with the real
   verify → `loginWithFirebase(idToken)` (the seam is already there).

> ⚠️ Do NOT commit any of these files. `google-services.json`,
> `GoogleService-Info.plist`, and the service-account JSON must be gitignored /
> injected, not checked in.

## Operational must-haves before prod
- Separate dev/staging/prod (above).
- HTTPS/WSS everywhere; WebSocket upgrade + idle-timeout tuned for long connections.
- Health checks + uptime monitor (`/health`) and Sentry (`SENTRY_DSN`).
- Backups/DR for Postgres; Redis is ephemeral but presence/relay depend on it.
- Rate limits are in-code (per-IP + per-auth); confirm they're active behind the proxy (preserve client IP via `X-Forwarded-For`).
- **Before real users:** the E2EE audit (see CHECKLIST pre-production gate).
