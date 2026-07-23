# @voiid/workers

Background jobs. Runs as a **third pm2 process** (`voiid-workers`) alongside
`voiid-api` and `voiid-ws`, started by `infrastructure/deployment/deploy-dev.sh`.

It depends directly on `pg` + `@aws-sdk/client-s3` and does **not** import
`@voiid/api` — so it is independently restartable and an API build failure cannot
take the reaper down with it. It reads the same `DATABASE_URL` / `R2_*` env.

## Jobs

| Job | Interval | What it does |
|---|---|---|
| `reapStories` | 5 min (`WORKERS_INTERVAL_MS`) | Deletes expired story ciphertext from R2, then the `stories` rows (`story_keys` / `story_receipts` cascade). 1h grace after `expires_at`. |

**`reapStories` is NOT what makes a story expire.** Every server read path in
`backend/api/src/routes/stories.ts` filters `expires_at > now()`, and every client
does the same locally — a story is invisible the instant it expires even if this
process has been dead for a week. The reaper is *cleanup*: it stops expired
ciphertext existing at rest. Never make visibility depend on it.

The bucket lifecycle rule on prefix `media/stories/` (**expire after 2 days**) is
the orphan net, set deliberately *wider* than the reaper so the reaper — code in
this repo, reviewable in a diff — stays the primary mechanism rather than a
console setting.

Every job here must be **idempotent** and safe to run concurrently on two boxes:
the loop has no queue, no scheduler library and no leader election.

## Env

```
DATABASE_URL=            # same as the API
R2_ENDPOINT= R2_BUCKET= R2_ACCESS_KEY_ID= R2_SECRET_ACCESS_KEY=
WORKERS_PORT=3003        # /health
WORKERS_INTERVAL_MS=300000
```

`GET /health` reports the **job**, not just the process: `last_run_at`,
`last_ok_at`, `last_error`, `last_result`. It returns 503 when the DB is
unreachable or the most recent pass failed — a worker whose process is up but
whose job has been failing for hours is the failure mode that silently leaves
expired ciphertext in the bucket.

## Still to build

- **signaling** — WebRTC signaling (reuses realtime backbone); Phase 4.
- prekey replenish checks, security-event processing, DPDP erasure.
- **admin-api** — backs apps/admin-web; full ops platform from Phase 3 (Section 8).
