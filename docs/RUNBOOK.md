# Voiid — how to actually run it

Written 2026-08-06 at commit `f31c46c`. Every command below was run against this tree, not
recalled. Where something is untested or needs a decision from you, it says so.

Read this top to bottom the first time. After that, §1 is the deploy checklist.

---

## 0. What is in the repo

| Service | Path | What it is |
|---|---|---|
| API | `backend/api` | Express + Postgres. Every REST route. |
| WS relay | `backend/websocket` | Stateless fan-out over Redis. Carries messages, calls, location fixes. **No database by design.** |
| Games | `backend/games` | The referee for game moves. |
| Workers | `backend/workers` | Story reaper, DPDP erasure, retention sweep. |
| Admin panel | `apps/admin-web` | Next.js, port 3100. Moderation. |
| Marketing site | `apps/web` | Next.js static export. |
| iOS | `apps/ios/Voiid` | Swift / SwiftUI. |
| Android | `apps/android` | Kotlin / Compose. |

Node workspaces are `backend/*`, `packages/*`, `apps/web`, `apps/admin-web`. The two mobile
apps are **not** npm workspaces — build them with Xcode and Gradle.

---

## 1. Bring it up, in order

Each step assumes the previous one succeeded. Do not skip §1.2.

### 1.1 Install

```bash
npm install                       # installs every workspace, hoisted to the repo root
```

### 1.2 Environment

Copy `.env.example` to `.env` and fill it. The variables that will stop you dead if missing:

| Variable | Why it matters |
|---|---|
| `DATABASE_URL` | Everything. |
| `REDIS_URL` | The relay AND the API share this — call grants and account revocation cross between them through it. |
| `JWT_SECRET` | **The API and the relay must use the same value** or every socket is rejected. |
| `VOIID_SECRETBOX_KEY` | Contact PIN at-rest encryption. `seal()` throws without it. Generate: `openssl rand -base64 32` |
| `TRUST_PROXY` | **See §5 — this one needs a decision, not a default.** |
| `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET` | Media. Note it is `R2_ENDPOINT` (a full URL), not an account id. |
| `FIREBASE_SERVICE_ACCOUNT` | Phone-number auth and Android push. |
| `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | Group and conference calls. Unset degrades to 1:1 only, cleanly. |
| `VOIID_APNS_VOIP_*` | iOS call wake-up. Without these an iPhone will not ring when the app is killed. |

### 1.3 Migrations

```bash
node --env-file=.env infrastructure/deployment/migrate.mjs
```

43 files. The runner applies every unapplied one **in filename order**, each in its own
transaction, and ledgers it in `schema_migrations` **by full filename** — so duplicate
numbers (there are several: two `026`, two `030`, four `031`) are fine and all of them run.

Verified: all 43 apply clean to an empty Postgres 18, producing 60 tables.

Sanity check afterwards:

```sql
\dt   -- expect ~60 tables including creator_profiles, communities,
      -- consent_records, data_retention_policy, call_participants
select count(*) from schema_migrations;   -- 43
```

### 1.4 Seed an admin account

There is no signup for the admin panel — accounts are added by hand, deliberately (see the
header of `028_admin_users.sql`: a SIM swap must never also hand over moderation).

```bash
node -e "console.log(require('bcryptjs').hashSync(process.argv[1],10))" 'YOUR_PASSWORD'
```
```sql
insert into admin_users (email, password_hash, name)
values ('you@example.com', '<hash from above>', 'Your Name');
```

### 1.5 Run the services

```bash
npm run dev -w @voiid/api          # :4000
npm run dev -w @voiid/websocket    # :4001
npm run dev -w @voiid/games
npm run dev -w @voiid/workers
npm run dev -w @voiid/admin-web    # :3100
npm run dev -w @voiid/web          # :3000
```

Health check: `curl localhost:4000/health` — reports db, redis, firebase, media and the
build sha. A `degraded` status names which dependency is down.

### 1.6 Mobile

```bash
# iOS
cd apps/ios/Voiid && xcodebuild -project Voiid.xcodeproj -scheme Voiid \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build

# Android
cd apps/android && ./gradlew :app:assembleDebug
```

Both are verified building at this commit. Point them at your API with the base URL in
`APIClient.swift` / `ApiClient.kt`.

---

## 2. Verify a change before you push

This is the exact sequence I run. It catches everything that has actually broken in this
repo, in ascending order of cost:

```bash
# 1. Backend types — both services, they can break independently
(cd backend/api && npx tsc --noEmit) && (cd backend/websocket && npx tsc --noEmit)

# 2. Tests — 142 at this commit
npm test -w @voiid/api

# 3. Migrations against a THROWAWAY database (see §6 for why this matters)
#    Never against a database you care about.

# 4. Android — note --rerun-tasks
cd apps/android && ./gradlew :app:compileDebugKotlin --rerun-tasks

# 5. iOS
cd apps/ios/Voiid && xcodebuild -project Voiid.xcodeproj -scheme Voiid \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build

# 6. Web
npm run build -w @voiid/web && npm run build -w @voiid/admin-web
```

**On `--rerun-tasks`:** without it Gradle will report `BUILD SUCCESSFUL … UP-TO-DATE` having
compiled nothing. That has produced a false green in this repo. If the output says
`UP-TO-DATE`, you did not test your change.

**On the web build:** if it fails with `Cannot find module for page: /_not-found`, the build
cache is stale — `rm -rf apps/web/.next apps/web/out` and rebuild. Not a code error.

---

## 3. Destructive operations

### 3.1 Wipe all clips — **irreversible, has never been run**

```bash
node --env-file=.env backend/api/scripts/wipe-clips.mjs                        # DRY RUN, deletes nothing
node --env-file=.env backend/api/scripts/wipe-clips.mjs --confirm             # deletes clips + media
node --env-file=.env backend/api/scripts/wipe-clips.mjs --confirm --reset-profiles
```

Run the dry run first and read the counts. R2 objects are deleted **before** rows, because
the keys exist only in the rows — the reverse orphans every video with no way to enumerate
it. A half-finished run is safe to repeat.

`--reset-profiles` is a **separate flag on purpose**. Wiping clips is content; wiping
profiles destroys identity — handles, follower graphs, avatars. But without it, every user
keeps their old handle and the "create a profile before you post" gate never fires, so the
first-post flow cannot be tested on a supposedly fresh database.

### 3.2 Account erasure

`DELETE /users/me` soft-deletes and revokes device trust immediately; the worker in
`backend/workers/src/erasure.ts` performs the hard purge on its next tick.

Two things that are easy to get wrong and are now correct — do not "tidy" them back:

- **`photo_url` is deliberately NOT nulled at soft-delete.** It is the only pointer to the
  avatar object in R2, and the worker follows it to delete that object. Clearing it early
  orphans the image permanently.
- **Prekeys are deleted at soft-delete**, not left to the worker. An unconsumed one-time
  prekey for a deleted account is material a sender could still be handed.

---

## 4. Things that will bite you

Every one of these has actually happened in this repo.

**kotlinx `encodeDefaults = false` omits fields equal to their default.** It has silently
broken read receipts, Stories and action envelopes. On a **request** body, either drop the
default or annotate `@EncodeDefault`. On a **response** model a default is correct and
necessary.

**Swift `Codable` throws `keyNotFound` on an absent key** — the mirror image. Response
models need optionals, or one added server field breaks the client.

**Postgres NULL in a unique constraint is DISTINCT**, so `ON CONFLICT` never matches and an
upsert silently becomes an insert. Use a partial unique index instead.

**Two processes editing one file lose edits.** If you run parallel agents, batch them so no
two touch the same file.

**`grep -c` exits 1 when the count is zero**, so `$(grep -c … || echo 0)` yields `"0\n0"` and
breaks shell arithmetic.

**`find -newermt` is GNU-only** — BSD `find` on macOS silently returns nothing rather than
erroring, which reads as "no activity".

---

## 5. Decisions only you can make

### 5.1 `TRUST_PROXY` — **do this before relying on rate limits**

`backend/api/src/index.ts` defaults to `'loopback'`, which is correct for both topologies
documented in `docs/VULTR_DEPLOY.md`: prod runs Caddy on the same box proxying to
`localhost:4000`, and dev exposes `:4000` directly.

**If a load balancer sits in front of prod that the runbook does not document, set
`TRUST_PROXY=2`.** Getting this wrong fails in both directions — too permissive and IP
spoofing still works, too restrictive and every request looks like it came from the proxy so
the rate limiter throttles all users as one client. The client IP is written into
`admin_sessions`, `security_events` and the admin audit log, which are the records a breach
investigation reads.

This was flagged as a merge condition by the security review and is **still unverified
against your real deployment.**

### 5.2 Deleted-account login

A soft-deleted account is currently **rejected** at login (403 `account_deleted`) rather than
reinstated. Until the erasure worker runs, that number is locked out. No client calls
`DELETE /users/me` today so it is unreachable, but decide reject-vs-reinstate before account
deletion ships in a client.

### 5.3 Legal

`docs/research/11_admin_dpdp.md` carries `[COUNSEL]` flags on questions a lawyer must answer,
not an engineer — retention periods, whether an anonymised consent stub must survive erasure,
cross-border processor status for R2/Firebase/LiveKit. The code carries those flags forward
rather than resolving them. **Do not ship a compliance claim on the strength of this repo.**

---

## 6. Testing against a throwaway Postgres

How I verified every migration in this session. Never point this at real data.

```bash
export PATH=/opt/homebrew/opt/postgresql@18/bin:$PATH
D=/tmp/vpg; S=/tmp/vpgs; rm -rf $D $S; mkdir -p $S
initdb -D $D -U postgres >/dev/null
pg_ctl -D $D -o "-p 55432 -k $S" -l $D/log start
psql -h $S -p 55432 -U postgres -c "create extension pgcrypto"
for f in database/migrations/*.sql; do
  psql -h $S -p 55432 -U postgres -v ON_ERROR_STOP=1 -q -f "$f" || echo "FAILED $f"
done
# … run your checks …
pg_ctl -D $D stop -m immediate; rm -rf $D $S
```

The socket directory must be short — a path over 103 bytes fails with
`Unix-domain socket path is too long`, which is why `$S` is `/tmp/vpgs` and not the scratchpad.

---

## 7. What is built, and what is not

**Working and verified at this commit:** messaging with E2EE, the reachability/PIN model,
1:1 and group calls, the friends map and live location, clips with creator profiles and
follows, four games, moments, the admin moderation panel, the marketing site.

**Backend only — no client UI yet:**

| Feature | State |
|---|---|
| Conference calls (1:1 → group) | Five endpoints, 32 guard tests. **No UI to trigger it.** |
| Communities | Full routes + schema, mounted. Both apps route the tab to a placeholder. |
| Group roles at scale | Owner/admin/member with caps and transfer endpoints, this commit. **Clients do not render roles or system messages yet.** |
| DPDP console, reports | Schema + workers. No admin UI. |

The marketing site deliberately does not advertise any of these. If you build a client for
one, update `apps/web` in the same change — its README explains the rule.

**Not started:** MLS multi-device event delivery (`3.13`), the 1000-member scale test
(`3.14`), the group-call UI overhaul (`3.15`), tournaments and ticketing (`3.22`/`3.23`).
All are specified in `docs/research/00_REPAIR_PLAN.md` with file lists and conflict notes.
