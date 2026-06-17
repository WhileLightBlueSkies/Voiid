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
