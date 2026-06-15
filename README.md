# VOIID

Privacy-first, end-to-end-encrypted messaging super-app. See [`VOIID_MASTER_SPEC_COMPLETE.md`](VOIID_MASTER_SPEC_COMPLETE.md) for the full spec, [`docs/PHASE_PLAN.md`](docs/PHASE_PLAN.md) for the build plan, and [`docs/CHECKLIST.md`](docs/CHECKLIST.md) for live progress.

## Monorepo layout (Section 7.1)
```
apps/        web · ios · android · admin-web
backend/     api · websocket · signaling · workers · admin-api
packages/    shared-types · design-tokens · api-contracts · common-utils
database/    migrations · schema · seeds
infrastructure/  docker · github-actions · deployment · monitoring
docs/        PHASE_PLAN.md · CHECKLIST.md
```
- **apps/ios** — add the Xcode project here (Swift + SwiftUI).
- **apps/android** — add the Android Studio project here (Kotlin + Jetpack Compose).

## Golden rules (non-negotiable)
- The **server never sees plaintext** — it stores/relays **ciphertext only**.
- Server stores **public keys only**; private keys never leave the device.
- All crypto via **libsignal** (wired in Phase 2, after AGPL licensing is cleared — blocker #1).
- **Supabase = Postgres host only** (not Supabase Auth, not Supabase Realtime). **Firebase = OTP sender only**.
- Every external dependency behind a swappable interface.

## Run Phase 0 backend locally
```bash
cp .env.example .env            # fill JWT_SECRET etc.
docker compose -f infrastructure/docker/docker-compose.yml up --build
# api:  http://localhost:4000/health
# ws:   ws://localhost:4001?token=<jwt>
```

Or without Docker (needs local Postgres + Redis):
```bash
npm install
npm run dev:api      # :4000
npm run dev:ws       # :4001
```

## Database / Supabase
Migrations live in [`database/migrations/`](database/migrations/) (`001_users.sql` … `009_security_events.sql`),
tracked in git and run via the Supabase CLI:
```bash
supabase link --project-ref <your-ref>
supabase db push           # applies migrations to the linked project
```
Use **plain Postgres** in critical paths so swapping Supabase → Vultr Managed Postgres / RDS is a
`DATABASE_URL` change. Do **not** adopt Supabase Auth or Supabase Realtime.

## Current status
**Phase 0 — Backend Foundation** in progress. Track the review gate in [`docs/CHECKLIST.md`](docs/CHECKLIST.md).
