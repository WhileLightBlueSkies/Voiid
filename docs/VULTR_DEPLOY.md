# VOIID — Vultr Deployment Runbook

> Concrete, follow-along steps to run the backend (`api` + `websocket`) on Vultr.
> Fill in the `<...>` placeholders with your own values. Secrets live on the box
> (in `.env` or env vars) — **never committed to git**.
>
> Setup: **1 Vultr instance for DEV** (both services on one box). Prod is a
> SEPARATE box with a SEPARATE database + Redis (see "Dev vs Prod" below).
>
> Last updated: 2026-06-17

---

## 0. Topology

```
            Apps (iOS / Android)
                   │
   dev:  http://<dev-ip>:4000        prod: https://api.<domain>
         ws://<dev-ip>:4001                wss://ws.<domain>
                   │                              │
        ┌──────────▼──────────┐        ┌──────────▼──────────┐
        │  VULTR DEV INSTANCE │        │  VULTR PROD INSTANCE │
        │  api :4000          │        │  api :4000 (+Caddy)  │
        │  websocket :4001    │        │  websocket :4001     │
        └──────────┬──────────┘        └──────────┬──────────┘
                   │                              │
        DEV  Supabase + Upstash       PROD Supabase + Upstash
        (separate projects)            (separate projects)
```

Compute instances needed now: **1 (dev)**. Add the prod box only when going live.

---

## What actually runs (deploy the backend, but clone the whole repo)

Only the **backend** runs on the server, but the API depends on a shared
workspace package, so you must have these present for `npm ci` to resolve:

| Path | On the server | Role |
|---|---|---|
| `backend/api`, `backend/websocket` | ✅ built + run | the two services |
| `packages/common-utils` | ✅ built (not run) | dependency of the API (`@voiid/common-utils`) |
| `package.json`, `package-lock.json` (root) | ✅ needed | defines the npm workspaces that link the above |
| `apps/` (iOS/Android) | present, **not run** | client apps — ignored on the server |
| `packages/e2e-core` | present, **not run** | client-side crypto — ignored on the server |
| `docs/` | present, **not run** | docs |

**Do NOT try to copy only `backend/`** — the API imports `@voiid/common-utils`
through the workspace root, so `npm install` would fail without the root
`package.json` + `packages/common-utils`. Just `git clone` the whole repo and
build/run only the three backend pieces (steps below). The unused folders are
harmless dead weight.

---

## 1. Vultr instance spec (DEV)

- **Type:** Cloud Compute (shared CPU is fine for dev)
- **Size:** 1 vCPU / 1–2 GB RAM (~$5–6/mo) — the DB/Redis are offloaded, so the
  Node services are light
- **OS:** Ubuntu 22.04 LTS (or 24.04)
- **Region:** closest to your users / to Supabase `ap-south-1` (e.g. Mumbai/Bangalore) to keep DB latency low
- **Firewall:** allow inbound `22` (SSH), `4000`, `4001` for dev. (For prod with a
  domain you'd open `80`/`443` instead and keep 4000/4001 internal.)

> Fill in once created:
> - DEV instance IP: `<dev-ip>`

---

## 2. One-time server setup

SSH in (`ssh root@<dev-ip>`), then:

```bash
# Node 20 LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs git

# pm2 process manager (keeps services running + restarts on reboot)
npm install -g pm2

# get the code
git clone <your-repo-url> /opt/voiid
cd /opt/voiid
git checkout 0.0.2          # or your release branch
npm ci                       # install workspace deps

# build the shared package + services
npm run build -w @voiid/common-utils
npm run build -w @voiid/api
npm run build -w @voiid/websocket
```

---

## 3. Environment (DEV) — the file the box reads

Create `/opt/voiid/.env` on the DEV box (gitignored; never pushed):

```bash
NODE_ENV=development
API_PORT=4000
WS_PORT=4001

# --- DEV database + redis (SEPARATE from prod) ---
DATABASE_URL=<DEV Supabase pooler URL>      # postgres://...pooler.supabase.com:6543/postgres
REDIS_URL=<DEV Upstash URL>                 # rediss://...upstash.io:6379  (TLS)

JWT_SECRET=<dev random secret>              # any strong random; UNIQUE per env
JWT_EXPIRY=30d

# Dev login without Firebase (accepts "dev:<phone>" tokens). MUST be off in prod.
AUTH_DEV_BYPASS=1

# Firebase (leave empty in dev — dev bypass covers auth)
FIREBASE_SERVICE_ACCOUNT=
```

> `npm run start` uses `node --env-file=.env`, so this file is auto-loaded.

---

## 4. Run the services (DEV)

```bash
cd /opt/voiid
pm2 start "npm run start -w @voiid/api"        --name voiid-api
pm2 start "npm run start -w @voiid/websocket"  --name voiid-ws
pm2 save                                        # persist across reboots
pm2 startup                                     # follow the printed command once
```

Check:
```bash
curl http://localhost:4000/health    # → {"service":"api","status":"ok","db":"up","redis":"up"}
pm2 logs                              # live logs
```

From your laptop: `curl http://<dev-ip>:4000/health` should return the same.

---

## 5. Point the apps at the DEV box

- **iOS** (`Networking/APIClient.swift`):
  `APIConfig.baseURL = "http://<dev-ip>:4000"`, `wsURL = "ws://<dev-ip>:4001"`
- **Android** (`net/ApiClient.kt`):
  `ApiConfig.baseUrl = "http://<dev-ip>:4000"`, `wsUrl = "ws://<dev-ip>:4001"`
  (keep `usesCleartextTraffic=true` for the http dev box)

---

## 6. Deploying updates (DEV)

```bash
cd /opt/voiid
git pull
npm ci
npm run build -w @voiid/common-utils -w @voiid/api -w @voiid/websocket
pm2 restart voiid-api voiid-ws
```

---

## Dev vs Prod — the environment separation (IMPORTANT)

Dev and prod must use **different databases, different Redis, different secrets**,
so test data and tokens never touch real users. Same code, different env.

| Var | DEV (this box) | PROD (separate box) |
|---|---|---|
| `NODE_ENV` | `development` | `production` |
| `DATABASE_URL` | **DEV** Supabase project | **PROD** Supabase project (create a new one) |
| `REDIS_URL` | **DEV** Upstash db | **PROD** Upstash db (create a new one) |
| `JWT_SECRET` | dev secret | **different** prod secret |
| `AUTH_DEV_BYPASS` | `1` | **unset / 0** (real Firebase only) |
| `FIREBASE_SERVICE_ACCOUNT` | empty | the prod service-account JSON |
| App base URL | `http://<dev-ip>` | `https://api.<domain>` (TLS) |

### How to MAINTAIN the two environments (the mental model)

**One codebase, two boxes, two `.env` files.** The code is identical on dev and
prod — the *only* difference is the `.env`/environment variables on each machine.
You never fork the code per environment.

```
            git repo (one)
                 │ git pull
        ┌────────┴────────┐
   DEV box                PROD box
   /opt/voiid             /opt/voiid
   .env (dev DB/Redis)    .env (prod DB/Redis)   ← the ONLY thing that differs
   pm2: api + ws          pm2: api + ws
```

Day-to-day flow:
1. You develop + commit to the repo (branch `0.0.2` now; later a `main`/release branch).
2. **Deploy to DEV:** on the dev box, `git pull` → rebuild → `pm2 restart` (step 6
   below). Test against dev DB/Redis with `AUTH_DEV_BYPASS`.
3. **Promote to PROD:** when dev looks good, on the prod box `git pull` the SAME
   commit/tag → rebuild → `pm2 restart`. It picks up prod's `.env` automatically,
   so it hits the prod DB/Redis with real Firebase.

Recommended branch discipline (simple, scales later):
- `0.0.2` / `main` = what dev runs (latest).
- Tag releases (e.g. `v0.3.0`) and have **prod check out the tag**, not the moving
  branch — so prod only moves when you deliberately bump it.

Golden rules so the two never bleed together:
- **Secrets live on the box, never in git.** Each box has its own `.env`. The repo
  only holds `.env.example`.
- **Never copy dev's `JWT_SECRET` to prod** (a dev token must not work in prod).
- **Separate DB + Redis projects** — migrations are applied to *each* DB
  independently (see below); a migration run on dev does NOT touch prod.
- **`AUTH_DEV_BYPASS=1` only on dev.** If it's ever set on prod, anyone can log in
  as any phone number — treat that as a release blocker.
- Keep the two boxes on the **same code version** when comparing behavior; a bug
  that's "only on prod" is usually an env/data difference, not code.

> Optional later: a CI/CD pipeline (GitHub Actions) that SSHes in and runs the
> pull+build+restart on a push to a branch — but the manual flow above is the
> source of truth and works fine to start.

### To create the PROD environment (when going live)
1. **New Vultr instance** (same steps 1–4 above, `NODE_ENV=production`).
2. **New Supabase project** → run the migrations there → use its pooler URL as the prod `DATABASE_URL`. Do NOT reuse the dev project.
3. **New Upstash Redis** → its `rediss://` URL as prod `REDIS_URL`.
4. **Fresh `JWT_SECRET`** (do not copy dev's).
5. `AUTH_DEV_BYPASS` unset; set real `FIREBASE_SERVICE_ACCOUNT`.
6. **Domain + HTTPS:** point `api.<domain>` / `ws.<domain>` at the prod IP; put
   Caddy in front for auto-TLS (App Store/Play require HTTPS/WSS). Apps switch to
   the `https`/`wss` URLs and Android turns OFF cleartext.

> Running migrations on a new DB: apply `supabase/migrations/001..009*.sql` (and
> any later ones) to the new project via the Supabase SQL editor or CLI.

---

## Prod TLS (Caddy) — minimal reference

On the prod box, `/etc/caddy/Caddyfile`:
```
api.<domain> {
    reverse_proxy localhost:4000
}
ws.<domain> {
    reverse_proxy localhost:4001
}
```
Caddy auto-provisions Let's Encrypt certs. Point the DNS A records at the prod IP first. Ensure the firewall allows 80/443 and the WebSocket upgrade passes through (Caddy handles it by default).

---

## Checklist before pointing real users at prod
- [ ] Separate prod DB + Redis + JWT_SECRET (not dev's)
- [ ] `AUTH_DEV_BYPASS` off; real Firebase service account set
- [ ] HTTPS/WSS via domain + Caddy; Android cleartext off
- [ ] `/health` green on prod
- [ ] pm2 startup enabled (survives reboot); logs/monitoring (Sentry, uptime)
- [ ] DB backups enabled on the prod Supabase project
- [ ] (Pre-launch) the E2EE audit — see CHECKLIST pre-production gate

