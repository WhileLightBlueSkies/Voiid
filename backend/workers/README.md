# @voiid/workers

Background jobs. Runs as a **third pm2 process** (`voiid-workers`) alongside
`voiid-api` and `voiid-ws`, started by `infrastructure/deployment/deploy-dev.sh`.

It depends directly on `pg` + `@aws-sdk/client-s3` and does **not** import
`@voiid/api` — so it is independently restartable and an API build failure cannot
take the reaper down with it. It reads the same `DATABASE_URL` / `R2_*` env.

## Jobs

All three run on every tick, in order, each in its own try/catch — a slow bucket
holding up the story reaper must not also hold up deleting a phone number.

| Job | Interval | What it does |
|---|---|---|
| `reapStories` | 5 min (`WORKERS_INTERVAL_MS`) | Deletes expired story ciphertext from R2, then the `stories` rows (`story_keys` / `story_receipts` cascade). 1h grace after `expires_at`. |
| `erasure` | same tick | DPDP account erasure. 30 days after `DELETE /users/me`, deletes the user's R2 objects, then the rows the `on delete cascade` graph cannot reach (`otp_sessions` and `security_events` by phone number), then the `users` row itself. |
| `retention` | same tick | Storage limitation. Deletes expired `otp_sessions` (+24h), `security_events` and `contact_pin_attempts` older than 90d, expired `admin_sessions`, `call_metrics` older than 90d, `retention_sweep_log` older than 365d. |

**The periods are named constants in `erasure.ts` / `retention.ts`, deliberately.**
`data_retention_policy` (030_dpdp.sql) is the *declared* policy — what a notice or a
console quotes; the constants are the *enforced* policy. Each pass writes its own
constant back into `enforced_interval`, so a console showing declared ≠ enforced is
showing a real defect. Changing a period is then a diff someone reviews rather than an
`UPDATE` in a database console at 2am. **Every duration is an engineering placeholder
pending legal sign-off** ([COUNSEL], `docs/research/11_admin_dpdp.md` §6) — this code
implements controls, it certifies nothing.

**`erasure` is what makes account deletion real.** `DELETE /users/me` only sets
`deleted_at`; until this job runs, the phone number is still in the database. It is also
what ends the lockout: `verify-otp` rejects a soft-deleted account rather than
resurrecting it, so a deleted number cannot sign up again until this job deletes the row
and releases the unique index. If this job is not running, that lockout is permanent.

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

`GET /health` reports each **job**, not just the process: `jobs.<name>.last_run_at`,
`last_ok_at`, `last_error`, `last_result`. It returns 503 when the DB is
unreachable, when any job's most recent pass failed (`failing_jobs`), or when
`stuck_erasures` is non-zero — a worker whose process is up but whose job has been
failing for hours is the failure mode that silently leaves expired ciphertext in the
bucket, and now also the one that silently retains a phone number after its owner asked
to be erased. `stuck_erasures` means exactly that and needs a human.

## Still to build

- **signaling** — WebRTC signaling (reuses realtime backbone); Phase 4.
- prekey replenish checks, security-event processing.
- **clip reaping** — `022_clips.sql` promises a worker sweeps orphaned clip media and
  soft-deleted clips' R2 objects; nothing does. (The erasure job covers the clips of an
  *erased* user only.)
- **admin-api** — backs apps/admin-web; full ops platform from Phase 3 (Section 8).
