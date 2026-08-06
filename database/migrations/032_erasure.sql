-- 032_erasure.sql — the small amount of state the DPDP erasure worker needs in order to be
-- idempotent, to survive a broken object store, and to leave evidence that it ran
-- (repair plan 3.25). The worker itself is backend/workers/src/erasure.ts.
--
-- ======================== METADATA ONLY — NO CONTENT, EVER ========================
-- Nothing here gives the server, an operator or an admin any ability to read a message, a
-- call, a location share or a moment. Those are end-to-end encrypted and the server holds
-- ciphertext and no key. This file adds a retry counter, a queue of object keys, and a
-- table of COUNTS. It weakens nothing; it is the mechanism by which personal data stops
-- being retained.
-- =================================================================================
--
-- WHY THIS IS URGENT, and it is worth stating precisely because the two halves landed
-- separately:
--
--   * `DELETE /users/me` sets `deleted_at` and nulls the profile fields, and its response
--     literally says "hard purge runs via erasure job (DPDP)". That job has never existed,
--     so `users.phone_number` and `users.username` have been retained INDEFINITELY after
--     an erasure request. A phone number is the primary personal identifier in this
--     system; indefinite retention after the purpose ends is what s.8(7) is about.
--
--   * A security fix has since closed the resurrection hole: `POST /auth/verify-otp`
--     now REJECTS a soft-deleted account (403 account_deleted) instead of quietly
--     un-deleting it, and `requireAuth` re-checks account state on every request. That
--     was the right call — reinstating everything a user asked us to erase on the
--     strength of an OTP is not a decision an auth endpoint gets to make. But it means
--     that TODAY a deleted phone number is permanently locked out: the row is never
--     purged, so the unique constraint on `phone_number` never releases the number, so
--     that human being can never use Voiid again from that number.
--
-- The erasure worker is what closes that loop. It is simultaneously the DPDP control and
-- the thing that makes the account-deleted lockout temporary rather than permanent —
-- the number frees itself when the row is finally deleted.
--
-- EVERY DURATION IS AN ENGINEERING PLACEHOLDER. The 30-day grace lives as a named
-- constant in backend/workers/src/erasure.ts (retention policy belongs in a diff, not in
-- a database console — backend/workers/src/index.ts:1-11); this file records the fact
-- that it is unreviewed. [COUNSEL] docs/research/11_admin_dpdp.md §6.3 lists the grace
-- period as an open question, and §2.10 raises a policy question this schema cannot
-- answer: within the grace window, does a re-login CANCEL the erasure request (requiring
-- an explicit, audited un-delete) or is the account already gone? The worker implements
-- the second reading — it re-checks `deleted_at` inside the deleting transaction, so
-- clearing that column is all any future reinstatement path has to do.
--
-- THIS FILE IMPLEMENTS A CONTROL. IT DOES NOT CERTIFY THAT VOIID COMPLIES WITH ANYTHING.


-- ═════════════════════════════════════════════════════════════════════════════════
-- §1 — CLAIMING AND BACKING OFF
-- ═════════════════════════════════════════════════════════════════════════════════

-- Backoff counter, NOT a retry loop. A user whose erasure keeps failing for a reason the
-- worker cannot fix (a constraint nobody anticipated, a wedged cascade) must not sit at
-- the head of the queue re-failing forever and starving every erasure behind it. Rows
-- past the worker's attempt ceiling are skipped and surfaced on /health as `stuck`, which
-- is a page-a-human condition: it means somebody asked to be erased and was not.
alter table users
    add column if not exists erasure_attempts int not null default 0;

-- The claim query is `deleted_at < now() - grace`. Without this, every pass sequentially
-- scans the whole live user table to find the handful of rows that are pending erasure.
-- Partial, because rows with a null deleted_at can never be claimed.
create index if not exists idx_users_pending_erasure
    on users (deleted_at)
    where deleted_at is not null;


-- ═════════════════════════════════════════════════════════════════════════════════
-- §2 — OBJECTS THAT OUTLIVED THEIR ROW
-- ═════════════════════════════════════════════════════════════════════════════════
--
-- The erasure worker deletes R2 objects BEFORE the rows that name them, for the reason
-- admin.ts's clip purge already documents: the keys exist only in the row, so dropping
-- the row first orphans the objects with nothing left to enumerate them by.
--
-- That ordering creates one problem this table solves. If R2 is unreachable, "objects
-- first" would mean the phone number stays in the database until the bucket comes back —
-- i.e. a storage outage would silently extend an erasure indefinitely. That trade is the
-- wrong way round: the identifier must go on schedule, and the object must still be
-- chased afterwards. So a failed delete is queued here, the erasure proceeds, and later
-- passes retry the key until the object is actually gone.
--
-- ON HOLDING THE KEY: `media/clips/<uid>/<uuid>.mp4` contains the uuid of a user who has
-- been erased, so this row is not nothing. It is kept because the alternative is worse in
-- exactly the way that matters — dropping the row leaves the OBJECT ITSELF in the bucket
-- forever with nothing anywhere that can name it. The row dies as soon as its object
-- does, and a non-empty table is reported on /health precisely so it does not become a
-- quiet permanent home for erased users' identifiers.
create table if not exists erasure_pending_objects (
    r2_key          text primary key,
    queued_at       timestamptz not null default now(),
    attempts        int not null default 0,
    last_attempt_at timestamptz,
    -- The provider's error string, for an operator deciding whether this is a broken
    -- credential or a key that never existed. Never a user identifier.
    last_error      text
);

create index if not exists idx_erasure_pending_oldest
    on erasure_pending_objects (queued_at);


-- ═════════════════════════════════════════════════════════════════════════════════
-- §3 — EVIDENCE THAT ERASURE HAPPENED
-- ═════════════════════════════════════════════════════════════════════════════════
--
-- COUNTS AND TIMINGS ONLY, by construction: no user_id, no phone number, no object key.
-- A log of erasures that names the erased is a contradiction, and it would turn the
-- record of a privacy control into a privacy problem of its own — the same reasoning
-- retention_sweep_log (030_dpdp.sql) is built on.
--
-- [COUNSEL] the consequence, which is real and is not resolved here: this table cannot
-- prove that a NAMED individual's erasure request was fulfilled, only that N erasures
-- ran on a given day. If a data-principal request console (repair plan 3.27) has to close
-- a specific request with evidence, that evidence belongs on the request row — where the
-- principal has already identified themselves and the retention period is that of the
-- request, not of the account. Do not solve it by adding a user_id here.
create table if not exists erasure_log (
    id              bigserial primary key,
    ran_at          timestamptz not null default now(),
    -- What the worker's constant actually was on this pass, so a later change to the
    -- grace period is visible in the history rather than retroactively rewriting it.
    grace_interval  interval,
    users_erased    int not null default 0,
    objects_deleted int not null default 0,
    -- Objects whose delete failed and went to erasure_pending_objects. A number that
    -- stays above zero across passes means the bucket, not the worker, is broken.
    objects_queued  int not null default 0,
    -- {"otp_sessions": 3, "security_events": 41, ...} — counts for the statements the
    -- worker issues explicitly: the deletes the cascade cannot reach, plus the counter
    -- repairs and IP redactions that have to accompany them. Rows removed by ON DELETE
    -- CASCADE are deliberately NOT counted: Postgres does not report them, and a
    -- fabricated number in an evidence table is worse than an absent one.
    deleted_counts  jsonb not null default '{}'::jsonb
                        check (jsonb_typeof(deleted_counts) = 'object'),
    duration_ms     integer
);

create index if not exists idx_erasure_log_time
    on erasure_log (ran_at desc);


-- ═════════════════════════════════════════════════════════════════════════════════
-- §4 — TWO MORE ROWS FOR THE DECLARED RETENTION POLICY
-- ═════════════════════════════════════════════════════════════════════════════════
--
-- 030_dpdp.sql declared the policy for the tables it knew about. Two more exist.
--
-- `contact_pin_attempts` (020_reachability.sql) is the brute-force ledger behind the
-- 6-digit PIN, and it stores `sender_ip`. It was missed by the original survey because
-- it is a security control rather than a log — but a table holding an IP address with no
-- retention period is the same problem whatever it is called. 90 days matches
-- security_events for the same reason: the rate limiter itself only ever reads a 1-hour
-- and a 24-hour window (routes/reachability.ts), so everything older is evidence, not
-- mechanism, and evidence is what the security_events period was chosen for.
--
-- The sweep worker refuses to touch a table with no row here (retention_sweep_log's
-- foreign key enforces it), which is the intended shape: sweeping a table is not
-- something a worker gets to decide unilaterally, it is something the declared policy
-- authorises.
insert into data_retention_policy
    (table_name, personal_data, purpose, retention_basis, declared_interval, enforced_by, sweep_rule, counsel_note)
values
    ('contact_pin_attempts',
     'sender IP address; target user_id (sender_user_id is nulled when that account is deleted)',
     'Rate-limit the 6-digit contact PIN. Six digits is 1,000,000 combinations — without this ledger the PIN is decoration.',
     'fixed_interval', interval '90 days', 'retention_worker',
     'delete where attempted_at < now() - 90 days. The limiter reads only the last hour and the last day, so nothing older affects any decision.',
     '[COUNSEL] 90 days mirrors security_events and inherits the same open question about an IT Rules 2021 retention FLOOR.'),

    ('erasure_pending_objects',
     'R2 object keys, which embed the uuid of an already-erased user',
     'Retry an object delete that failed while erasing an account, so a storage outage cannot leave a deleted user''s media in the bucket forever.',
     'not_yet_enforced', null, 'none',
     'No time-based sweep, deliberately: a row is deleted when its object is, and deleting it on a clock instead would abandon the object it exists to chase. A row that is old is a bug to fix, not a row to expire.',
     '[COUNSEL] if a key here becomes unresolvable (bucket destroyed, credentials permanently lost), deleting the row is the only remaining option and it should be a deliberate, recorded act rather than an automatic one.')
on conflict (table_name) do nothing;
