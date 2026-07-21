# VOIID — production hosting & go-live runbook

> Everything you need to stand up the backend and test live on real devices.
> Grounded in the actual code (env vars, services, migrations) as of this commit.
>
> **Golden rule:** every integration degrades gracefully when unconfigured — the
> app won't crash if TURN/LiveKit/VoIP/Drive aren't set up yet. So you can bring
> the stack up incrementally and test each capability as it comes online.

---

## 0. The moving parts (what you're hosting)

| Piece | What it is | Required for |
|---|---|---|
| **API service** | `backend/api` (Node/Express) | everything (auth, messages, prekeys, backup, calls signaling creds) |
| **WebSocket service** | `backend/websocket` (Node) | realtime message delivery, typing, call signaling relay |
| **PostgreSQL** | the database | everything (16 migrations) |
| **Redis** | pub/sub + presence | WS fan-out between API and sockets |
| **Object storage (R2/S3)** | Cloudflare R2 or any S3 | media attachments + encrypted backups |
| **coturn** | TURN/STUN server | calls that can't go peer-to-peer (~10-20% of them) |
| **LiveKit** | SFU | group/conference calls |
| **Firebase** | FCM push + phone-auth OTP | push notifications, SMS login |
| **APNs keys** | Apple push (alert + **VoIP**) | iOS push + reliable call ringing |
| Reverse proxy (Caddy/nginx) | TLS + routing | terminates HTTPS/WSS, routes `/ws` to the socket service |

Clients are hard-pointed at **`https://api-dev.voiid.app`** and
**`wss://api-dev.voiid.app/ws`** (see §5) — so the proxy must serve both the API
and the `/ws` path on that host.

---

## 0.1 CHOSEN TOPOLOGY (decided)

**TURN: Cloudflare** (managed) — chosen for zero ops + global anycast coverage
(relays near every user automatically, which single-region self-hosted coturn
can't match). Trade-off accepted: Cloudflare sees relay *metadata* (peer IPs,
timing) for the ~10–20% of calls that relay — it can NEVER see media, which stays
DTLS-SRTP encrypted. Our own coturn stays available in-code as a fallback and can
be added later (privacy/backup relay); the API prefers Cloudflare when both are
configured. So `deploy/turn/` is kept but not part of the initial bring-up.

**Two instances:**

| Box / service | Runs | Sizing (start) |
|---|---|---|
| **Box A — app** | API + WebSocket + Redis | 4 vCPU / 8 GB |
| **Box B — LiveKit** | LiveKit SFU only (media-heavy, isolated so a group call can't degrade the API) | 4 vCPU / 8 GB |
| **Supabase** | managed Postgres (the DB) | managed — no box |
| *(Cloudflare)* | TURN | managed — no box |

**Postgres = Supabase (managed).** `backend/api/src/db.ts` connects via a plain
`pg` Pool over `DATABASE_URL` with TLS — Supabase is used purely as hosted
Postgres (no supabase-js, no edge functions). So Box A does NOT run Postgres, and
the "managed, backed-up DB" box is already handled. Just point `DATABASE_URL` at
the Supabase connection string. **Use a DEDICATED Supabase project for this clean
app** — its 16-migration schema is separate from the `Voiid-Main` fork's schema;
don't share a database.

**Box B (LiveKit) firewall/ports:** `7880` (HTTP/WS signaling, put TLS in front for
`wss://livekit.voiid.app`), `7881` (TCP fallback), **UDP `50000-60000`** (media),
on a **public IP**. Hand its `LIVEKIT_API_KEY`/`SECRET` to Box A's env.

**Box A is now nearly stateless** — API + WS hold no state (all shared state via
Redis), so scale-out later is just adding more of them behind the proxy. Redis is
the only stateful piece on Box A; for a fully-disposable Box A use a managed Redis
(Upstash etc.), otherwise back up/persist it. The DB (Supabase) is already managed.

**Group calls can be skipped for the FIRST live test** — 1:1 calls don't need
LiveKit, and `POST /calls/group/token` returns a clean 503 until it's configured.
So a 1:1-only smoke test can run on Box A alone with Cloudflare TURN; bring Box B
up when testing group calls.

---

## 1. Prerequisites
- [ ] A domain (e.g. `voiid.app`) with DNS you control. Suggested records:
  - `api.voiid.app` → API/proxy host
  - `turn.voiid.app` → coturn host (your bare metal)
  - `livekit.voiid.app` → LiveKit host
- [ ] TLS certs (Let's Encrypt). The reverse proxy handles API/WSS; coturn and
      LiveKit need their own certs (see their sections).
- [ ] Your Vultr bare-metal box(es). API+WS+Redis+Postgres can co-locate to start;
      coturn and LiveKit are happiest on their own (UDP-heavy).

---

## 2. Data stores

### PostgreSQL = Supabase (managed)
- [ ] Create a **dedicated Supabase project** for this app (NOT shared with the
      Voiid-Main fork — different schema). Grab its Postgres connection string.
- [ ] Set `DATABASE_URL` to the Supabase connection string (TLS required; the app
      enables SSL automatically for non-local hosts).
- [ ] **Apply the 16 migrations in order** — there is no migration runner yet, so
      either paste each file into the Supabase SQL editor in order, or:
  ```bash
  for f in database/migrations/0*.sql; do
    echo "== $f"; psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" || break
  done
  ```
  Migrations `001`–`016` cover: users, devices, prekeys, OTP, conversations,
  messages, receipts, contact-sync, security-events, username, MLS, recovery,
  message-ciphertexts (fan-out), **calls (014)**, **device VoIP token (015)**,
  **call metrics (016)**. (014/015/016 are the newest — make sure they run.)
- [ ] Set `DATABASE_URL=postgres://user:pass@host:5432/voiid`.

### Redis
- [ ] Provision Redis (managed or on the box). Set `REDIS_URL=redis://…` (or
      `rediss://…` with TLS). Used by BOTH api and websocket — same instance.

### Object storage (Cloudflare R2 recommended, or any S3)
- [ ] Create a bucket. Create an access key/secret.
- [ ] Set `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`.
- Media + encrypted backups live here. Without it, media/backup return 503 (the
  rest of the app still works).

---

## 3. Push & auth (Firebase + APNs)

### Firebase (FCM + phone-auth OTP) — see docs/FIREBASE_SETUP.md
- [ ] Create/confirm the Firebase project. Enable **Authentication → Phone**.
- [ ] Add **test phone numbers** for dev (no real SMS / Blaze needed to start).
- [ ] Create a **service account** (Console → Project Settings → Service accounts →
      Generate key). Put it on the API box and set **`FIREBASE_SERVICE_ACCOUNT_PATH`**
      (path to the JSON) or `FIREBASE_SERVICE_ACCOUNT` (inline JSON). This is what
      lets the backend send FCM data pushes. **Never commit it.**
- [ ] Client config files (see §5): `google-services.json` (Android),
      `GoogleService-Info.plist` (iOS).

### APNs — alert push + VoIP push (iOS)
- [ ] Apple Developer → create an **APNs Auth Key (.p8)**. Set `APNS_KEY_ID`,
      `APNS_TEAM_ID`, `APNS_KEY_PATH` (or `APNS_KEY_P8` inline), `APNS_BUNDLE_ID`
      (`com.voiid.app`), `APNS_ENV` (`sandbox` for TestFlight/dev, `production` for
      App Store).
- [ ] **VoIP push** (reliable call ringing on a killed app): the VoIP topic is
      `<bundle-id>.voip` and Apple **rejects** a VoIP push to the plain bundle id.
      Set `VOIID_APNS_VOIP_TOPIC=com.voiid.app.voip`. The other
      `VOIID_APNS_VOIP_*` vars fall back to the matching `APNS_*`, so if you reuse
      one key for both you only need to set the topic. (You can also use a separate
      VoIP .p8 via `VOIID_APNS_VOIP_KEY_ID`/`_KEY_PATH`/`_P8`.)
- Upload the same APNs key to Firebase (Cloud Messaging) so FCM can reach iOS too.

---

## 4. Calls infrastructure

### CHOSEN: Cloudflare TURN (managed)
- [ ] Create a Cloudflare Realtime/TURN key. Set `VOIID_TURN_CLOUDFLARE_KEY_ID` +
      `VOIID_TURN_CLOUDFLARE_API_TOKEN` on Box A. That's it — the API mints
      per-client credentials from Cloudflare and advertises them via
      `GET /v1/calls/turn`. Keep `VOIID_STUN_URLS` (Cloudflare or Google STUN) for
      the P2P-discovery path. Leave the coturn vars UNSET; when both are set the API
      prefers Cloudflare.
- [ ] **Verify:** the Trickle-ICE web test with creds from `GET /v1/calls/turn`
      should show a `relay` candidate. Test a real call with one device on cellular
      to confirm relayed calls connect.

### FALLBACK / later: self-hosted coturn — config in `deploy/turn/`, steps in docs/TURN_SETUP.md
Not part of the initial bring-up (Cloudflare is the chosen path). Add it later if
you want relay metadata kept in-house or a backup relay:
- [ ] Install coturn on the (bare-metal) box. Use `deploy/turn/turnserver.conf`.
- [ ] Generate a strong secret and set it in BOTH places (they MUST match):
  - coturn `static-auth-secret=…`
  - API env `VOIID_TURN_STATIC_AUTH_SECRET=…`
- [ ] TLS cert for `turn.voiid.app` (Let's Encrypt) wired into the conf.
- [ ] **Open firewall:** UDP+TCP 3478, TCP 5349, **TCP 443** (critical for
      restrictive networks), and the relay UDP range 49152-65535.
- [ ] Set `external-ip` in the conf if the box is behind NAT.
- [ ] Set API env `VOIID_TURN_URLS=turn:turn.voiid.app:3478?transport=udp,turns:turn.voiid.app:5349?transport=tcp,turns:turn.voiid.app:443?transport=tcp`
      and `VOIID_STUN_URLS=stun:turn.voiid.app:3478` (or keep Google's public STUN).
- Managed alternative: set `VOIID_TURN_CLOUDFLARE_KEY_ID` + `_API_TOKEN` instead;
  the API prefers Cloudflare when both are present.
- **Verify:** the Trickle-ICE web test with creds from `GET /v1/calls/turn`, and
  `turnutils_uclient`. See docs/TURN_SETUP.md.

### LiveKit (group calls) — see docs/LIVEKIT_SETUP.md
- [ ] Self-host LiveKit (docker) or use LiveKit Cloud. Get the URL + API key/secret.
- [ ] Set `LIVEKIT_URL=wss://livekit.voiid.app`, `LIVEKIT_API_KEY`,
      `LIVEKIT_API_SECRET`. Until set, `POST /calls/group/token` returns 503 and
      group calls are cleanly unavailable (1:1 calls unaffected).
- Group-call media stays E2E encrypted (key derived on-device from MLS) — the SFU
  forwards ciphertext.

---

## 5. Point the clients at production

The apps currently target `api-dev.voiid.app`. For your live test either (a) point
DNS `api-dev.voiid.app` at your stack, or (b) change the URLs:
- **iOS:** `apps/ios/Voiid/Voiid/Networking/APIClient.swift` → `APIConfig.baseURL`
  + `wsURL`.
- **Android:** `apps/android/app/src/main/java/com/voiid/app/net/ApiClient.kt` →
  `baseUrl` + `wsUrl`.

Also install per-platform config:
- [ ] **iOS** `GoogleService-Info.plist` in the Voiid target (gitignored). APNs
      capability + Background Modes (voip/audio/remote-notification — already in
      Info.plist). A real provisioning profile with **App Groups** (`group.com.voiid.app`),
      **Keychain Sharing**, **Push**, and **iCloud** (`iCloud.com.voiid.app`) — needed
      for the NSE, VoIP, and iCloud backup to work on device.
- [ ] **iOS** vendored `WebRTC.xcframework` (see `apps/ios/VENDOR.md`) + LiveKit SPM.
- [ ] **Android** `google-services.json` in `apps/android/app/`, and the debug +
      release **SHA-1/SHA-256** registered in Firebase (for phone auth) and in the
      Google OAuth client (for Drive).
- [ ] (Optional) **Google Drive backup** OAuth: enable Drive API + consent screen +
      `drive.appdata` scope + OAuth clients (see docs/GOOGLE_INTEGRATION_TODO.md).
      Until set up, Drive backup is disabled in-app; server backup still works.

---

## 6. Build & run the backend

```bash
# from repo root, with a .env at repo root holding the vars from §7
cd backend/api && npm ci && npm run build && npm run start   # serves API_PORT
cd backend/websocket && npm ci && npm run build && npm run start  # serves WS_PORT
```
Run both under a process manager (systemd / pm2 / docker). Then the reverse proxy:
- `https://api.voiid.app/*` → API service (`API_PORT`)
- `wss://api.voiid.app/ws` → WebSocket service (`WS_PORT`)  ← the `/ws` path
- TLS terminated at the proxy.

(`npm test` in `backend/api` runs the 53-test suite — worth running in CI.)

---

## 7. Complete env var reference (repo-root `.env`, gitignored)

**Core (required):**
```
NODE_ENV=production
API_PORT=8080
WS_PORT=8081
DATABASE_URL=postgres://user:pass@host:5432/voiid
REDIS_URL=redis://host:6379
JWT_SECRET=<long random>          # MUST be identical for api AND websocket
JWT_EXPIRY=30d
```
**Object storage (media + backups):**
```
R2_ENDPOINT=  R2_BUCKET=  R2_ACCESS_KEY_ID=  R2_SECRET_ACCESS_KEY=
BACKUP_MAX_BYTES=52428800
```
**Firebase / FCM (push + OTP):**
```
FIREBASE_SERVICE_ACCOUNT_PATH=/etc/voiid/firebase-sa.json   # or FIREBASE_SERVICE_ACCOUNT=<inline json>
```
**APNs (iOS push + VoIP ringing):**
```
APNS_KEY_ID=  APNS_TEAM_ID=  APNS_KEY_PATH=/etc/voiid/apns.p8   # or APNS_KEY_P8 inline
APNS_BUNDLE_ID=com.voiid.app
APNS_ENV=sandbox                 # sandbox for TestFlight, production for App Store
VOIID_APNS_VOIP_TOPIC=com.voiid.app.voip
# VOIID_APNS_VOIP_KEY_ID / _TEAM_ID / _KEY_PATH / _P8  — only if using a separate VoIP key
```
**Calls — TURN:**
```
VOIID_STUN_URLS=stun:stun.l.google.com:19302
VOIID_TURN_URLS=turns:turn.voiid.app:443?transport=tcp,turn:turn.voiid.app:3478?transport=udp
VOIID_TURN_STATIC_AUTH_SECRET=<matches coturn>
VOIID_TURN_TTL_SECONDS=3600
# or Cloudflare: VOIID_TURN_CLOUDFLARE_KEY_ID= VOIID_TURN_CLOUDFLARE_API_TOKEN=
```
**Calls — LiveKit (group):**
```
LIVEKIT_URL=wss://livekit.voiid.app  LIVEKIT_API_KEY=  LIVEKIT_API_SECRET=
LIVEKIT_TOKEN_TTL_SECONDS=21600
```
**Metrics / ops:**
```
VOIID_METRICS_DEDUPE_SECRET=<long random>   # rotating it severs metric->call linkage
VOIID_OPS_USER_IDS=<comma-separated user ids allowed to read /calls/metrics/summary>
```
**Force-update gate (optional):**
```
MIN_APP_IOS=  MIN_APP_ANDROID=  IOS_STORE_URL=  ANDROID_STORE_URL=  FORCE_CUTOFF=
```
**Dev only (NEVER in prod):**
```
AUTH_DEV_BYPASS=   # bypasses auth — leave UNSET in production
```

---

## 8. Smoke test — what to check, in order

Bring it up incrementally; each step proves one layer.
1. [ ] **API health:** `GET https://api.voiid.app/config` returns JSON (proxy + API + DB reachable).
2. [ ] **DB:** migrations applied (`\dt` shows ~16+ tables incl. `calls`, `call_metrics`, `mls_group_events`).
3. [ ] **Register/login:** on a real device, phone → OTP (use a Firebase test number) → lands in the app. Proves Firebase auth + JWT + users/devices tables.
4. [ ] **WebSocket:** connect (the app does `wss://…/ws?token=JWT` on login). Proves proxy `/ws` routing + Redis.
5. [ ] **1:1 message (TWO devices):** send both directions; delivered + decrypts. Proves prekeys, fan-out, WS relay, push.
6. [ ] **Push:** background the app, send a message → notification (with iOS NSE decrypted preview). Proves FCM/APNs + service account.
7. [ ] **Backup/restore:** set a PIN + recovery phrase, back up, reinstall, restore. Proves R2 + recovery + e2e-core.
8. [ ] **1:1 call (TWO devices):** place a call. Proves TURN issuance + signaling + WebRTC. Test on **different networks** (one WiFi, one cellular) to exercise TURN relay + ICE restart, and with **one phone on silent** to check ringback plays for the caller.
9. [ ] **Group call:** create a group, start a group call with 3+ people. Proves LiveKit + MLS-derived E2EE.
10. [ ] **Metrics:** after a few calls, `GET /calls/metrics/summary` (as an ops user) shows setup-success rate / % relayed.

---

## 9. Known gotchas (learned the hard way in this codebase)
- **`JWT_SECRET` must match** across api and websocket, or sockets reject every token.
- **iOS VoIP push** needs the `.voip` topic + a signed build on real hardware — it
  cannot be tested in the simulator or on a plain alert push.
- **iOS entitlements** (App Groups, Keychain Sharing, iCloud) only take effect in a
  **signed** build with a matching provisioning profile — the NSE decrypt, VoIP,
  and iCloud backup silently no-op without them.
- **coturn secret mismatch** = calls connect on WiFi (host/srflx) but fail behind
  NAT/CGNAT (no relay). Test on cellular to catch this.
- **Google Drive `drive.appdata`** is a sensitive scope → OAuth app verification
  has a multi-day lead time for non-test users. Start it early.
- **Migrations are manual** — don't forget 014/015/016; calls + VoIP token + metrics
  break without them.

---

## 10. The honest caveat
None of the native call/backup/group paths have been runtime-tested — they are
build-verified only. Expect the two-device live test (steps 5-10) to surface real
bugs, most likely in: Bluetooth audio routing, group-call E2EE key agreement across
MLS epochs, the call-waiting swap, and iOS background/PiP transitions. That test
pass is the point of this deployment.
