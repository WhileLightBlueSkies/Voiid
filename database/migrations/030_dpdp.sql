-- 030_dpdp.sql — the DPDP data model: consent records, retention metadata, and the two
-- device-type columns. Schema only; the endpoints, the sweep worker and the client legs
-- land separately (repair plan 3.26, 3.28, 3.32).
--
-- ======================== METADATA ONLY — NO CONTENT, EVER ========================
-- Nothing in this migration gives the server, an operator, or an admin any ability to
-- read a message, a call, a location share or a moment. Those are end-to-end encrypted
-- and the server holds ciphertext and no key. Every column below describes an ACCOUNT
-- or an ACT OF ADMINISTRATION — who consented to which notice, when a row of security
-- telemetry must be deleted, what OS a device runs. If a future column here would need
-- plaintext to be useful, that is the signal that it belongs somewhere else, or nowhere.
--
-- A consequence worth writing down because it will be asked: a DPDP access request
-- (Act s.11) against Voiid cannot return message content. There is none to return. That
-- is a property of the product, not an evasion, and the notice has to say so.
-- =================================================================================
--
-- ---------------------------------------------------------------------------------
-- THE RECORD OF PURPOSE LIMITATION (Act ss.6, 8)
--
-- This header is the authoritative statement of what personal data Voiid holds, why,
-- and for how long. `data_retention_policy` below is the machine-readable half of the
-- same statement; if the two ever disagree, this header is the one a human reviewed.
--
--   PERSONAL DATA          WHERE                  PURPOSE                                   RETENTION
--   phone number           users.phone_number     identity — the account IS the number      account lifetime, then erasure
--   phone number           otp_sessions           deliver and verify the login code         row expiry + 24h
--   phone number           security_events        attribute pre-auth abuse to a number      90 days
--   profile fields         users.full_name/…      user-supplied, shown to their contacts    account lifetime, then erasure
--   device metadata        devices.*              route pushes; the user's own linked-      account lifetime, then erasure
--                                                 devices screen; support and crash triage
--   OS / app version       devices (this file)    support and crash triage ONLY             account lifetime, then erasure
--   IP address             security_events        abuse and rate-limit investigation        90 days
--   IP address + UA        admin_sessions         spot a stolen ADMIN session               session expiry
--   consent record         consent_records        evidence of lawful basis (s.6)            account lifetime — see below
--   clips + comments       clips, clip_comments   public content, posted by choice          until the author deletes them
--
-- NOT COLLECTED, deliberately: no IP on the device row (see §3 below), no device
-- fingerprint, no advertising identifier, no coarse location, no contact graph beyond
-- what contact sync already stores, no behavioural telemetry of any kind.
--
-- EVERY DURATION IN THIS FILE IS AN ENGINEERING PLACEHOLDER. 90 days for security
-- telemetry and a 30-day erasure grace are the numbers docs/research/11_admin_dpdp.md
-- proposes for review; they have NOT been reviewed by India-qualified counsel, and
-- docs/research/11_admin_dpdp.md §6 lists them as an open [COUNSEL] question along with
-- whether metadata retention periods must appear in the notice at all. This file
-- implements controls. It does not certify that Voiid complies with anything.
-- ---------------------------------------------------------------------------------


-- ═════════════════════════════════════════════════════════════════════════════════
-- §1 — CONSENT (repair plan 3.26; Act ss.5-6)
-- ═════════════════════════════════════════════════════════════════════════════════
--
-- `users.consent_given_at` (001_users.sql:15) is a bare timestamp, and it is null for
-- every user in production because no client ever called the endpoint that writes it.
-- A timestamp is not a consent record in any case: s.6 requires consent that is
-- specific and informed, which means the record has to name WHICH notice, in WHICH
-- language, for WHICH purposes — and s.6(4) requires withdrawal to be as easy as
-- giving, which means the withdrawal has to be part of the same record rather than an
-- absence of one.

-- The published notices themselves, so "which text did this user agree to" has an
-- answer years later. `content_sha256` is what makes the answer defensible: it pins the
-- exact bytes that were served, so a later edit to the hosted document cannot silently
-- rewrite what anyone consented to.
create table if not exists consent_notices (
    version       text not null,           -- e.g. '2026-08-01' or '1.0' — publisher's choice, but immutable once used
    language      text not null,           -- BCP-47: 'en', 'hi', 'ta'. The Eighth-Schedule translation
                                           -- obligation's scope is [COUNSEL] (11_admin_dpdp.md §6.6);
                                           -- the schema is ready for 22 rows per version, the policy is not decided.
    url           text not null,           -- where it was hosted at publication time
    content_sha256 bytea,                  -- sha256 of the served document; null only for notices published
                                           -- before hashing was wired up, never for new ones
    published_at  timestamptz not null default now(),
    -- Set when a newer version supersedes this one. The row is NEVER deleted: consent
    -- records point at it by version, and an evidence trail that can vanish is not one.
    retired_at    timestamptz,
    primary key (version, language)
);

-- Consent as given by one user, once, to one version of the notice.
--
-- NO FOREIGN KEY to consent_notices, deliberately. An FK would make signup fail closed
-- whenever the notice registry is unseeded or a client sends a version the server has
-- not published yet — i.e. it would turn a paperwork gap into an outage on the most
-- critical path in the app. The endpoint validates the version against the registry and
-- rejects unknown ones; that check belongs in code where it can return a 400, not in a
-- constraint that returns a 500.
create table if not exists consent_records (
    id              uuid primary key default gen_random_uuid(),
    -- ON DELETE CASCADE: the erasure worker (3.25) deletes the users row and this goes
    -- with it. [COUNSEL] — this is a real tension and it is not resolved here: the
    -- consent record is the evidence that processing was lawful, and destroying it on
    -- erasure destroys that evidence, but keeping it means retaining a user_id for a
    -- user who asked to be erased. Counsel decides whether an anonymised stub
    -- (notice version + timestamp, no user_id) must survive erasure. Until then the
    -- privacy-preserving reading wins: it cascades.
    user_id         uuid not null references users(id) on delete cascade,
    notice_version  text not null,
    language        text not null,

    -- Per-purpose flags: {"identity": true, "push": true, "support_diagnostics": false}.
    -- JSONB rather than a column per purpose because the purpose SET changes with every
    -- notice revision, and a schema migration per revision guarantees the two drift.
    -- The endpoint whitelists keys against the notice's declared purposes, so a client
    -- cannot invent a purpose or smuggle a value in here.
    purposes        jsonb not null default '{}'::jsonb
                        check (jsonb_typeof(purposes) = 'object'),

    given_at        timestamptz not null default now(),
    -- Constrained vocabulary, not free text: this is client-supplied, and free text is
    -- both useless for "how did people actually consent" and a channel for smuggling
    -- identifiers into an evidence record (same reasoning as 016_call_metrics.sql).
    given_via       text not null default 'app_onboarding'
                        check (given_via in ('app_onboarding','app_settings','backfill_prompt','support')),

    -- ── THE WITHDRAWAL PATH (s.6(4): as easy to withdraw as to give) ──────────────
    -- Withdrawal is a field on the SAME row, not a separate table and not a delete.
    -- Deleting the row would erase the fact that consent ever existed, which is exactly
    -- what makes the period before withdrawal unauditable; a separate table would let
    -- the two halves disagree about whether consent is currently live.
    withdrawn_at    timestamptz,
    withdrawn_via   text check (withdrawn_via in ('app_settings','support','account_deletion')),
    -- Free text is acceptable here and only here: it is operator-entered when a
    -- withdrawal arrives by support ticket, and it is not part of any decision path.
    withdrawal_note text,

    -- Time cannot run backwards, and a withdrawal reason without a withdrawal is a bug
    -- in whatever wrote the row.
    constraint consent_withdrawal_after_grant check (withdrawn_at is null or withdrawn_at >= given_at),
    constraint consent_withdrawal_coherent    check ((withdrawn_at is null) = (withdrawn_via is null))
);

-- At most ONE live consent per (user, notice version). A PARTIAL unique index, not a
-- unique constraint over (user_id, notice_version, withdrawn_at): in Postgres a NULL
-- never equals a NULL, so a nullable column in a unique key permits unlimited duplicate
-- rows and makes ON CONFLICT never match — an upsert against it silently becomes an
-- insert. The predicate keeps NULL out of the key entirely.
create unique index if not exists idx_consent_active
    on consent_records (user_id, notice_version)
    where withdrawn_at is null;

-- "Is this user's consent currently live" — read on the path that decides whether to
-- prompt an existing user for the backfill.
create index if not exists idx_consent_user
    on consent_records (user_id, given_at desc);

-- ── Keeping the legacy column honest ─────────────────────────────────────────────
-- `users.consent_given_at` predates this table and is still read elsewhere. Leaving it
-- to be maintained by hand means a withdrawal clears the record here while the old
-- column keeps saying "consented" — a read path that has not been updated would then
-- treat a withdrawn user as a consenting one, which is precisely the failure s.6(4) is
-- about. A trigger makes that impossible rather than merely unlikely.
--
-- Direction of truth: consent_records is authoritative; users.consent_given_at is a
-- derived cache of "does this user have any live consent", kept only so existing
-- callers keep working.
-- The value written is the EARLIEST still-live consent — "consenting since" — so a
-- notice-version bump does not make an existing user look newly consented.
create or replace function sync_user_consent_flag() returns trigger as $$
declare
    ids    uuid[];
    target uuid;
begin
    -- NEW does not exist on DELETE and OLD does not exist on INSERT, so branch rather
    -- than coalesce across them. An UPDATE that repointed user_id has to fix both
    -- sides, or the row the consent moved away from keeps a stale flag.
    if tg_op = 'INSERT' then
        ids := array[new.user_id];
    elsif tg_op = 'DELETE' then
        ids := array[old.user_id];
    else
        ids := array[new.user_id];
        if old.user_id is distinct from new.user_id then
            ids := ids || old.user_id;
        end if;
    end if;

    foreach target in array ids loop
        -- Matches zero rows when the user is being erased (the cascade from users runs
        -- after the parent row is gone), which is exactly right: nothing to sync.
        update users
           set consent_given_at = (
                 select min(given_at)
                   from consent_records
                  where user_id = target and withdrawn_at is null)
         where id = target;
    end loop;

    return null;  -- after-trigger; return value is ignored
end;
$$ language plpgsql;

drop trigger if exists trg_consent_sync on consent_records;
create trigger trg_consent_sync
    after insert or update or delete on consent_records
    for each row execute function sync_user_consent_flag();


-- ═════════════════════════════════════════════════════════════════════════════════
-- §2 — RETENTION METADATA (repair plan 3.28; Act s.8(7))
-- ═════════════════════════════════════════════════════════════════════════════════
--
-- Three tables holding directly identifying data have never had a single row deleted:
-- security_events (IP + phone), otp_sessions (phone, with an expires_at nothing acts
-- on), admin_sessions (IP + user agent, deleted only on explicit logout). Storage
-- limitation requires a period that is both STATED and ENFORCED, and today neither
-- half exists.
--
-- WHAT THIS TABLE IS NOT: it is not the scheduler and it is not where the sweep reads
-- its numbers from. The worker keeps its periods as named constants in code, on
-- purpose — the whole reason the workers process exists is that retention policy should
-- be reviewable in a diff rather than editable in a database console at 2am with no
-- record (backend/workers/src/index.ts:1-11).
--
-- WHAT IT IS: the declared policy, in one place, in a form the DPDP console and the
-- privacy notice can read — plus the evidence that the sweep actually ran.
-- `declared_interval` is what was reviewed and published; `enforced_interval` is what
-- the worker's constant currently is, written by the worker on each pass. When those
-- two disagree, the published policy and the running code have drifted apart, and that
-- is a defect the console should surface loudly rather than a value to reconcile
-- silently.
create table if not exists data_retention_policy (
    table_name       text primary key,
    -- Which identifying fields this table actually holds. Prose, because the audience
    -- is a human answering a regulator, not a query planner.
    personal_data    text not null,
    -- Why we hold it at all. If this is hard to write in one sentence, the column
    -- probably should not exist.
    purpose          text not null,

    retention_basis  text not null check (retention_basis in (
                         'fixed_interval',    -- delete N after the row was created
                         'until_expiry',      -- the row carries its own expires_at; delete past it (+ optional grace)
                         'account_lifetime',  -- lives as long as the account; the ERASURE worker owns it, not the sweep
                         'not_yet_enforced'   -- honest placeholder: stated, not yet implemented
                     )),
    -- For fixed_interval: the age at which a row is deleted.
    -- For until_expiry: grace ADDED to the row's own expires_at.
    declared_interval interval,
    check (case retention_basis
             when 'fixed_interval'   then declared_interval is not null
             when 'account_lifetime' then declared_interval is null
             else true
           end),

    enforced_by      text not null check (enforced_by in ('retention_worker','erasure_worker','none')),
    -- Exactly which rows go, in words, so the policy can be checked against the code
    -- without reading the code.
    sweep_rule       text not null,

    -- Defaults to FALSE and must stay false until an India-qualified lawyer has signed
    -- off on the number. A period nobody reviewed is an engineering guess, and the
    -- console must be able to show which is which.
    counsel_reviewed boolean not null default false,
    counsel_note     text,

    -- Written by the sweep worker from its own constants. Drift from declared_interval
    -- means published policy ≠ running behaviour.
    enforced_interval  interval,
    last_sweep_at      timestamptz,
    last_sweep_deleted bigint,
    updated_at         timestamptz not null default now()
);

drop trigger if exists trg_retention_policy_updated_at on data_retention_policy;
create trigger trg_retention_policy_updated_at before update on data_retention_policy
    for each row execute function set_updated_at();

-- Evidence that retention was actually applied — the thing a breach review or a
-- regulator asks for and that "we have a cron somewhere" cannot answer. Counts and
-- timings only: BY CONSTRUCTION this table holds nothing about any individual, so
-- logging retention can never itself become a retention problem.
create table if not exists retention_sweep_log (
    id            bigserial primary key,
    -- RESTRICT, not CASCADE: dropping a policy row must not silently destroy the proof
    -- that the policy was enforced while it existed. Retiring a policy is then a
    -- deliberate two-step, which is the correct amount of friction for deleting evidence.
    table_name    text not null references data_retention_policy(table_name) on delete restrict,
    swept_at      timestamptz not null default now(),
    deleted_count bigint not null,
    duration_ms   integer
);

create index if not exists idx_retention_sweep_table
    on retention_sweep_log (table_name, swept_at desc);

-- ── The declared policy ──────────────────────────────────────────────────────────
-- ON CONFLICT DO NOTHING so a re-run cannot stomp the worker-written columns, and so a
-- later migration changing a period does so as its own reviewable statement rather than
-- as a side effect of replaying this one.
insert into data_retention_policy
    (table_name, personal_data, purpose, retention_basis, declared_interval, enforced_by, sweep_rule, counsel_note)
values
    ('otp_sessions',
     'phone number (E.164), hashed OTP',
     'Deliver and verify the SMS login code. The row has no purpose once it has expired.',
     'until_expiry', interval '24 hours', 'retention_worker',
     'delete where expires_at < now() - 24h. The grace exists only so a late verify attempt fails as "expired" rather than as "unknown session".',
     '[COUNSEL] 24h grace is an engineering choice; confirm nothing requires a longer OTP audit trail.'),

    ('security_events',
     'IP address, phone number (pre-auth events), user_id, device_id',
     'Investigate abuse: rate-limit breaches, reachability abuse, failed logins. Nothing else reads this table.',
     'fixed_interval', interval '90 days', 'retention_worker',
     'delete where created_at < now() - 90 days.',
     '[COUNSEL] 90 days is the placeholder proposed in docs/research/11_admin_dpdp.md; confirm against any IT Rules 2021 log-retention obligation, which may set a FLOOR rather than a ceiling.'),

    ('admin_sessions',
     'admin IP address, user agent (admins only — never a Voiid user)',
     'Let an admin see their own signed-in sessions and let us spot a stolen one.',
     'until_expiry', null, 'retention_worker',
     'delete where expires_at < now(). An expired session row cannot authenticate anything; all it still does is hold an IP.',
     null),

    ('call_metrics',
     'none by construction — no user_id, no call_id, hour-bucketed (see 016_call_metrics.sql)',
     'Call reliability trends. Anonymous samples, not call detail records.',
     'fixed_interval', interval '90 days', 'retention_worker',
     'delete where bucket_hour < now() - 90 days, finally enforcing the prune 016_call_metrics.sql:80-85 described and left to an ops cron that was never wired up.',
     'Not personal data as designed, but the longer an anonymous sample set is kept the more surface it offers to correlation attacks — which is why it is swept anyway.'),

    ('admin_audit_log',
     'admin identity, action target, and client IP inside detail jsonb',
     'Accountability for moderation and admin action: who removed what, and why.',
     'not_yet_enforced', null, 'none',
     'No sweep. Deliberately unimplemented rather than silently absent.',
     '[COUNSEL] genuine tension: storage limitation pulls one way, and the value of an audit trail is precisely that it outlives the incident. Do not pick a number here without advice.'),

    ('users',
     'phone number (primary identifier), full name, email, photo, bio, status text',
     'Identity. The account IS the phone number; every other field is user-supplied and shown to their contacts.',
     'account_lifetime', null, 'erasure_worker',
     'Not swept on a clock. Deletion is user-initiated: DELETE /users/me sets deleted_at, and after the grace period the erasure worker purges or tombstones the row (repair plan 3.25).',
     '[COUNSEL] the erasure grace period (30 days proposed) is unreviewed, and 11_admin_dpdp.md §2.10 raises a policy question this schema cannot answer: within that window, does re-login cancel the erasure request or is the account already gone?'),

    ('devices',
     'device name (free text, e.g. "iPhone 15"), platform, push token, OS version, app version',
     'Route content-free push wakeups, drive the user''s own linked-devices screen, and give support and crash triage a version to work from.',
     'account_lifetime', null, 'erasure_worker',
     'Cascades from users on erasure. Revoked device rows are kept while the account lives so the linked-devices screen can show "signed out on 3 Aug".',
     null),

    ('consent_records',
     'user_id, notice version, language, per-purpose flags',
     'Evidence that processing had a lawful basis, and the record of any withdrawal.',
     'account_lifetime', null, 'erasure_worker',
     'Cascades from users on erasure — see the [COUNSEL] note on the foreign key above.',
     '[COUNSEL] whether an anonymised consent stub must survive erasure as evidence.'),

    ('retention_sweep_log',
     'none — counts and timings only',
     'Evidence that the retention policy was actually applied.',
     'fixed_interval', interval '365 days', 'retention_worker',
     'delete where swept_at < now() - 365 days. Long enough to answer "was this enforced last year", short enough that the log cannot grow without bound.',
     null)
on conflict (table_name) do nothing;


-- ═════════════════════════════════════════════════════════════════════════════════
-- §3 — MINIMAL DEVICE-TYPE COLLECTION (repair plan 3.32)
-- ═════════════════════════════════════════════════════════════════════════════════
--
-- Two columns, both nullable, both client-declared, both visible to the user on their
-- own linked-devices screen. Purpose: support and crash triage. Today a bug report says
-- "the app crashes" and there is no way to know which OS or which build, so triage is
-- guesswork.
--
-- WHAT THIS IS NOT: a device fingerprint. Two coarse version strings, already sent in
-- request headers for the force-update gate, do not identify a handset — and nothing
-- here is combined with anything else to try. Explicitly rejected: device model
-- identifier, screen metrics, locale/timezone, battery, network type, advertising id.
--
-- AND NO IP COLUMN ON devices. That is the whole design decision, stated so nobody
-- adds one later thinking it is harmless: device metadata lives on the device row and
-- outlives the session; IP lives only in short-retention security telemetry and is
-- swept on the schedule declared above. Signal's server device record stores exactly
-- lastSeen and userAgent and no IP, and that is the posture Voiid's devices table
-- already had — this change keeps it.
--
-- Length caps because these are client-supplied strings that nothing validates
-- semantically: the cap is what stops an unbounded blob (or an attempt to use the
-- device row as free storage) from landing in a column meant to hold "17.4".
alter table devices
    add column if not exists os_version  text check (os_version  is null or length(os_version)  <= 32),
    add column if not exists app_version text check (app_version is null or length(app_version) <= 32);
