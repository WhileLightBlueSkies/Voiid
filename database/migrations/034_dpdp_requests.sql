-- 034_dpdp_requests.sql — the ledger behind the data-principal request console
-- (repair plan 3.27; DPDP Act ss.11-13: access, correction, erasure, grievance).
--
-- ======================== METADATA ONLY — NO CONTENT, EVER ========================
-- Nothing in this migration gives the server, an operator or an admin any ability to read
-- a message, a call, a location share or a moment. Those are end-to-end encrypted and the
-- server holds ciphertext and no key. Every column below describes a REQUEST and how it
-- was handled — who asked, for what kind of thing, when, by when it is due, and what was
-- done. Not one of them holds, or could hold, user content.
--
-- The consequence 030_dpdp.sql already wrote down applies here with force, because this is
-- the table where somebody will look for it: an access request (s.11) against Voiid cannot
-- return message content. There is none to return. The export endpoint this table tracks
-- (`GET /dpdp/export`) says so in the first field of the document rather than leaving the
-- absence to be discovered, because an access response that silently omits the thing the
-- principal most expects looks like an incomplete answer instead of what it is: a property
-- of the product.
-- =================================================================================
--
-- THIS FILE IMPLEMENTS A CONTROL. IT DOES NOT CERTIFY THAT VOIID COMPLIES WITH ANYTHING.
-- Every duration is an engineering placeholder and every open legal question below is
-- carried forward as a [COUNSEL] marker rather than answered here.
--
-- WHAT IS WRONG TODAY. There is no mechanism to receive, track or fulfil a data-principal
-- request at all. `DELETE /users/me` exists, so a user can delete their own account, but
-- there is nowhere for "please correct my name", "please tell me what you hold about me",
-- or a grievance to land, and no record that any of them arrived. ss.11-13 give the
-- principal those rights and s.13 requires a grievance mechanism; a support inbox nobody
-- can audit is not one, and it certainly cannot answer "was this request answered inside
-- the period" a year later.
--
-- WHY A TABLE AND NOT A TICKETING TOOL. Two of the four kinds (access, erasure) are
-- fulfilled by code in this system and by nothing else — the export is generated from
-- these tables and the erasure is executed by backend/workers/src/erasure.ts. A request
-- ledger that lives in a SaaS inbox cannot be joined to either, which means the evidence
-- that a request was fulfilled and the act of fulfilling it live in two systems that can
-- disagree. 032_erasure.sql anticipated exactly this and said where the evidence belongs:
-- "If a data-principal request console has to close a specific request with evidence, that
-- evidence belongs on the request row — where the principal has already identified
-- themselves. Do not solve it by adding a user_id [to erasure_log]." This is that row.


-- ═════════════════════════════════════════════════════════════════════════════════
-- §1 — THE REQUEST
-- ═════════════════════════════════════════════════════════════════════════════════

create table if not exists dpdp_requests (
    id          uuid primary key default gen_random_uuid(),

    -- ── ON DELETE SET NULL, and this is the single most considered line in the file ──
    -- CASCADE is wrong here in a way that is easy to miss: the erasure worker deletes the
    -- users row, so CASCADE would destroy the erasure request AT THE MOMENT IT IS
    -- FULFILLED. The only record that would survive is erasure_log, which by construction
    -- names nobody — so the system would be unable to show that a specific request was
    -- ever answered, precisely for the requests it answered.
    --
    -- SET NULL keeps the row and drops the identifier. What survives is: a request of this
    -- KIND was opened at T1 and closed at T2 with this status. That is evidence in the
    -- aggregate — "every erasure request in this period was closed inside the SLA" — and
    -- it is not evidence about a named person, which is the correct trade for someone who
    -- asked to stop being known to us.
    --
    -- [COUNSEL] whether it is the LEGALLY correct trade is not settled here. Proving to a
    -- regulator that Mr X's erasure request was fulfilled requires retaining a record that
    -- names Mr X, i.e. retaining an identifier for a person whose entire request was that
    -- we stop holding one. 030_dpdp.sql raises the same tension for consent_records and
    -- resolves it the same way, for the same reason: until counsel decides, the
    -- privacy-preserving reading wins. If counsel says otherwise, the change is to store a
    -- one-way hash of the phone number on this row at closure, NOT to switch this FK back
    -- to CASCADE and NOT to add a user_id to erasure_log.
    user_id     uuid references users(id) on delete set null,

    -- The four rights this console exists to serve. A constrained vocabulary rather than
    -- free text because the SLA, the fulfilment path and the required evidence all differ
    -- per kind, and code branches on this value.
    --
    --   access      s.11 — "what do you hold about me". Self-served by GET /dpdp/export;
    --               a request of this kind means the export did not answer them.
    --   correction  s.12 — "this is wrong, fix it". Most of the profile is self-editable,
    --               so this kind is for the fields that are not (phone number, username).
    --   erasure     s.12(3) — "delete it". Fulfilled by setting users.deleted_at, after
    --               which backend/workers/src/erasure.ts owns the actual purge.
    --   grievance   s.13 — the complaint channel, which the Act requires to exist and to
    --               be answerable within a period. [COUNSEL] the grievance-officer
    --               designation and the response period are open questions
    --               (docs/research/11_admin_dpdp.md §6.4, docs/LEGAL_QUESTIONS.md).
    kind        text not null check (kind in ('access', 'correction', 'erasure', 'grievance')),

    -- The lifecycle. `verifying` is a real state and not bureaucracy: fulfilling an access
    -- or erasure request for the wrong person is itself a data breach, so "are you who you
    -- say you are" is a step, not an assumption. (Requests opened through the app are
    -- already authenticated, which is why the app-opened path can skip straight to
    -- in_progress; requests that arrive by email cannot be.)
    status      text not null default 'open'
                    check (status in ('open', 'verifying', 'in_progress', 'done', 'rejected')),

    -- What the principal asked, in their words. Free text and necessarily so — the whole
    -- point is that they get to say it. Length-capped in the route, and scrubbed by the
    -- trigger below if the account is later erased.
    subject_note text,

    opened_at   timestamptz not null default now(),

    -- ── THE SLA CLOCK ────────────────────────────────────────────────────────────
    -- Written by the route from a named constant, NOT computed by a column default here.
    -- Same rule 030_dpdp.sql states for retention periods and backend/workers/src/index.ts
    -- states for the sweep: a period that can be edited in a psql session at 2am leaves no
    -- diff, and a response deadline is exactly the kind of number somebody will want to
    -- quietly extend when the queue is full.
    --
    -- Storing the deadline on the ROW rather than deriving it from opened_at at read time
    -- is deliberate: a later change to the constant must not retroactively move the
    -- deadline of a request that was already open under the old one.
    --
    -- [COUNSEL] the durations themselves are engineering placeholders. The DPDP Rules 2025
    -- commencement and the prescribed response periods are open question
    -- docs/research/11_admin_dpdp.md §6.1, and the IT Rules 2021 grievance timelines are
    -- §6.4. Nothing in this schema or the route asserts that any period here is the
    -- legally required one.
    due_at      timestamptz not null,

    closed_at   timestamptz,
    handled_by  uuid references admin_users(id) on delete set null,

    -- What was actually done, and the answer to "show me that this request was fulfilled".
    -- Required at closure by the constraint below: a request closed with an empty
    -- resolution is indistinguishable from one that was quietly dropped.
    resolution  text,

    -- Operator working notes. Separate from `resolution` because one is the answer and the
    -- other is the workings, and only the answer is evidence.
    notes       text,

    -- Set by the scrub trigger below when the subject is erased, so a reader can tell
    -- "this row never had free text" from "this row's free text was removed on erasure".
    redacted_at timestamptz,

    -- A deadline before the request existed is a bug in whatever wrote the row.
    constraint dpdp_due_after_open check (due_at >= opened_at),

    -- Terminal status and closure are the same fact; allowing them to disagree gives you a
    -- queue that shows an open request nobody will ever see again, or a closed one that
    -- keeps burning SLA. Both halves of the equality matter.
    constraint dpdp_closed_iff_terminal
        check ((status in ('done', 'rejected')) = (closed_at is not null)),

    -- A closed request must say what was done. btrim so a space does not satisfy it.
    constraint dpdp_closed_needs_resolution
        check (closed_at is null or (resolution is not null and length(btrim(resolution)) > 0))
);

-- ── ONE OPEN REQUEST PER PERSON PER KIND ─────────────────────────────────────────
-- A PARTIAL unique index, not a unique constraint over (user_id, kind, closed_at). In
-- Postgres NULL never equals NULL, so a nullable column inside a unique key permits
-- unlimited duplicate rows and makes ON CONFLICT never match — an upsert against it
-- silently becomes an insert. The predicate keeps NULL out of the key entirely. Same trap,
-- same fix, as idx_consent_active in 030_dpdp.sql.
--
-- `user_id is not null` is in the predicate for the second NULL reason: after erasure the
-- FK above nulls user_id, and rows with a null key column would otherwise all be permitted
-- to coexist anyway — which is fine, but only by accident. Saying it is deliberate.
--
-- The rule this enforces is a real one and not just hygiene: without it, a client retry or
-- an impatient user opens five erasure requests, and the queue's SLA numbers become
-- meaningless. Re-opening is possible the moment the previous one is closed.
create unique index if not exists idx_dpdp_open_per_kind
    on dpdp_requests (user_id, kind)
    where closed_at is null and user_id is not null;

-- The queue's only ordering: what is due soonest, among what is still open.
create index if not exists idx_dpdp_open_by_due
    on dpdp_requests (due_at)
    where closed_at is null;

-- "Show me this person's request history" — read by the per-user admin view and by the
-- principal's own GET /dpdp/requests.
create index if not exists idx_dpdp_by_user
    on dpdp_requests (user_id, opened_at desc);


-- ═════════════════════════════════════════════════════════════════════════════════
-- §2 — WHAT THE FK CANNOT DO BY ITSELF
-- ═════════════════════════════════════════════════════════════════════════════════
--
-- ON DELETE SET NULL removes the user_id. It does not remove the three free-text columns,
-- and free text written by a human is exactly where an identifier ends up: "called +91…
-- to verify", "same person as the Rahul ticket". Leaving those behind would mean the row
-- that survives an erasure still names the erased — which is the failure mode this whole
-- migration exists to avoid, arrived at through the back door.
--
-- A BEFORE UPDATE trigger, because the FK's SET NULL action IS an UPDATE, so this fires as
-- part of the same statement that drops the identifier. There is no window in which the
-- row exists with a null user_id and live notes, and no worker to remember to run.
--
-- WHY `resolution` GETS A SENTINEL AND NOT NULL: dpdp_closed_needs_resolution requires a
-- non-empty resolution on any closed row, so nulling it would make the erasure of a user
-- with a closed request fail with a constraint violation — i.e. a privacy control would
-- block a privacy control. The sentinel keeps the constraint satisfied and is honest about
-- what happened, which is better than either weakening the constraint or silently keeping
-- the text.
create or replace function scrub_dpdp_request_on_unlink() returns trigger as $$
begin
    new.subject_note := null;
    new.notes        := null;
    if new.resolution is not null then
        new.resolution := '[redacted: the data principal was erased]';
    end if;
    new.redacted_at  := now();
    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_dpdp_scrub_on_unlink on dpdp_requests;
create trigger trg_dpdp_scrub_on_unlink
    before update on dpdp_requests
    for each row
    when (old.user_id is not null and new.user_id is null)
    execute function scrub_dpdp_request_on_unlink();


-- ═════════════════════════════════════════════════════════════════════════════════
-- §3 — DECLARING THIS TABLE'S OWN RETENTION
-- ═════════════════════════════════════════════════════════════════════════════════
--
-- A table created to serve storage limitation that is itself retained forever would be a
-- poor joke, so it goes in the register 030_dpdp.sql built — as 'not_yet_enforced', which
-- is the honest state: the period is genuinely unknown, and picking one here to look tidy
-- is exactly the kind of unreviewed guess that file warns against.
--
-- ON CONFLICT DO NOTHING for the reason stated there: a re-run must not stomp the columns
-- the sweep worker writes, and a later change of period should be its own reviewable
-- statement rather than a side effect of replaying this file.
insert into data_retention_policy
    (table_name, personal_data, purpose, retention_basis, declared_interval, enforced_by, sweep_rule, counsel_note)
values
    ('dpdp_requests',
     'user_id while the account exists; free text written by the principal and by the operator. Nothing after the subject is erased — the FK nulls the identifier and a trigger scrubs the free text in the same statement.',
     'Receive, track and evidence data-principal requests under ss.11-13, including whether each was answered within its period.',
     'not_yet_enforced', null, 'none',
     'No sweep. A request record is the evidence that a right was honoured, and the value of that evidence is precisely that it outlives the request.',
     '[COUNSEL] how long a fulfilled request record must be kept — the same unresolved tension 030_dpdp.sql records for admin_audit_log, where storage limitation and the point of an audit trail pull in opposite directions. Do not pick a number here without advice. Note that a row whose subject has been erased holds no identifier, so the pressure to sweep it is far lower than for a live one.')
on conflict (table_name) do nothing;
