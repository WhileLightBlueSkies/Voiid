-- 035_reports.sql — user-filed reports, and the queue a moderator works them from
-- (repair plan 3.29; docs/research/11_admin_dpdp.md finding #5).
--
-- ============================ NOT END-TO-END ENCRYPTED ============================
-- This is a SCOPED, REASONED exception in the same shape as 022_clips.sql, and like that
-- one it is never a precedent for weakening messaging.
--
-- WHY IT HAS TO BE: a report is an accusation addressed TO US. Nobody else can act on it,
-- so there is no second party to encrypt it to, and a queue whose rows the server cannot
-- read is not a queue. The reason code, the reporter's note and the id of what was
-- reported are therefore stored as server-readable plaintext.
--
-- WHAT THAT DOES *NOT* INCLUDE — read this before adding a column:
--
--   * Reporting a CLIP gives the server nothing it did not already have. Clip media,
--     captions and counts are already plaintext (022_clips.sql). A clip report is an
--     index into content we can already see.
--
--   * Reporting a CREATOR is likewise metadata we already hold: a user id, a handle, a
--     public profile (029_creator_profiles.sql).
--
--   * Reporting a MESSAGE SENDER SHIPS NO MESSAGE. The server holds ciphertext and no
--     key, and there is no endpoint anywhere that can decrypt one. What a message report
--     carries by default is: who is being reported, which conversation both people are
--     provably in, a reason code, and the reporter's own words. That is enough to act on
--     a pattern of accounts; it is not the conversation.
--
--     The ONE way message plaintext can ever reach this table is `evidence`, which the
--     REPORTING USER's own device fills in from its own decrypted store, after the app
--     has shown them the exact text that will be uploaded, and only if they tap the
--     switch. The server cannot ask for it: there is no request, no push and no flag that
--     makes a client attach evidence. See the disclosure gate below, which makes
--     "attached without being marked as attached" a constraint violation rather than a
--     code review question.
--
--     THIS IS THE WHOLE REASON THE GATE EXISTS. A reporting flow is the classic place a
--     content-blind product accidentally grows a content pipe — first as an optional
--     debug field, then as a default, then as a requirement because moderation got
--     easier. If you are here to make evidence mandatory, or to attach it for a reason
--     other than a person deliberately choosing to hand us their own copy, you are
--     removing the product's central promise. Do not.
--
-- Messages, calls, locations and moments remain end-to-end encrypted and nothing in this
-- file changes that. The repair plan's own note for 3.29 says reporting must not extend
-- to messages "which the server cannot read" — the server still cannot read them, and
-- `message_sender` reports it on the sender, not the message.
-- =================================================================================
--
-- ONE TABLE, THREE TARGET KINDS, ON PURPOSE. The plan proposes `clip_reports`. A separate
-- table per target kind means the moderator's queue is a UNION of N tables that has to be
-- re-sorted and re-paginated every time a fourth thing becomes reportable, and it means
-- the disclosure gate above would have to be re-implemented (or forgotten) per table.
-- One table with a checked `target_type` keeps the queue one keyset scan and keeps the
-- E2EE gate in exactly one place.


create table if not exists content_reports (
    id uuid primary key default gen_random_uuid(),

    -- 'clip'           → target_id is clips.id
    -- 'creator'        → target_id is users.id (the public creator identity, 029)
    -- 'message_sender' → target_id is users.id, and the report is about the PERSON, never
    --                    about a message. There is deliberately no 'message' kind and no
    --                    message_id column: a message id would be an invitation to build
    --                    "fetch the reported message", which is unbuildable and must stay
    --                    unbuildable.
    target_type text not null check (target_type in ('clip', 'creator', 'message_sender')),

    -- NO FOREIGN KEY, and this is deliberate — the same call admin_audit_log makes for its
    -- own `target_id` (028_admin_users.sql). A report is the RECORD OF WHY something was
    -- taken down, and every plausible FK action destroys it at the worst possible moment:
    -- ON DELETE CASCADE erases the evidence the instant the purge it justified runs, and
    -- SET NULL cannot be used because this column is half the anti-report-bombing key
    -- below and must stay NOT NULL. The cost is a column that can dangle; the admin queue
    -- left-joins and renders "deleted" rather than assuming a row is there.
    target_id uuid not null,

    -- ON DELETE CASCADE: this row is the reporter's own personal data — their id, their
    -- words, their accusation — so erasing the account erases it. The moderation DECISION
    -- survives independently in admin_audit_log, which records what an ADMIN did and is
    -- not the reporter's data.
    -- [COUNSEL] 11_admin_dpdp.md §6 leaves the general "which stubs may survive an
    -- erasure" question open, and this table inherits it: a resolved report that was the
    -- basis for a takedown arguably has to outlive the reporter for the takedown to remain
    -- defensible. Not resolved here.
    reporter_user_id uuid not null references users(id) on delete cascade,

    -- A fixed vocabulary, not free text, because this is the column moderation is sorted
    -- and prioritised by, and because it is the half of a report that can be shown to the
    -- reported user without quoting their accuser.
    --
    -- 'child_safety' and 'illegal' are listed separately from 'violence' precisely so they
    -- can be routed differently by whatever escalation process exists. [COUNSEL] the
    -- handling obligations attached to those two in India (IT Rules 2021 grievance
    -- timelines, and any mandatory-reporting duty) are open question #13 in
    -- docs/LEGAL_QUESTIONS.md and are NOT settled by this file — nothing here claims
    -- Voiid meets any statutory timeline.
    reason text not null check (reason in (
        'spam',
        'harassment',
        'hate',
        'violence',
        'nudity',
        'self_harm',
        'child_safety',
        'impersonation',
        'illegal',
        'other'
    )),

    -- The reporter's own words. Optional, capped, and NEVER required: a mandatory
    -- free-text box on a report form is a box people paste conversations into, which is
    -- exactly the leak the disclosure gate exists to make deliberate.
    note text check (note is null or length(note) <= 1000),

    -- ── THE DISCLOSURE GATE ──────────────────────────────────────────────────────
    --
    -- 'metadata_only'     the default, and what every client sends unless a human acted
    -- 'reporter_attached' the reporting user was shown the exact content and chose to
    --                     upload their own copy of it
    --
    -- The coherence check below makes the two states structurally inseparable from the
    -- data: plaintext present without the flag, or the flag set with nothing attached,
    -- are both rejected by the database. That matters because the flag is what the admin
    -- UI reads to warn a moderator that they are about to look at something a person
    -- consented to hand over — a mislabelled row would silently turn that warning off.
    disclosure text not null default 'metadata_only'
        check (disclosure in ('metadata_only', 'reporter_attached')),

    -- Client-built JSON: the messages the reporter chose to attach, as they decrypted
    -- them on their own device. jsonb rather than text so the shape is inspectable and so
    -- a malformed blob fails at write time; there is no schema beyond that, because the
    -- server has no business normalising content it never asked for.
    evidence jsonb,

    -- Which conversation the reported behaviour happened in. Required for
    -- 'message_sender' and forbidden otherwise (see the checks): it is what proves the
    -- reporter and the reported person actually share a conversation, which is what stops
    -- this endpoint from becoming "accuse any user id you can guess".
    --
    -- ON DELETE CASCADE would take the whole report with the conversation, so there is no
    -- FK here either, for the same reason target_id has none.
    context_conversation_id uuid,

    status text not null default 'open' check (status in ('open', 'resolved')),
    created_at timestamptz not null default now(),

    resolved_at timestamptz,
    -- SET NULL rather than CASCADE: losing the admin row must not delete the record that
    -- the report was dealt with. Same reasoning as clips.removed_by in 028.
    resolved_by uuid references admin_users(id) on delete set null,
    resolution text check (resolution in ('removed', 'no_action', 'duplicate', 'escalated')),
    resolution_note text check (resolution_note is null or length(resolution_note) <= 1000),

    -- Plaintext may only ever exist on the one target kind that has a plausible reason to
    -- carry it. A clip report cannot attach evidence because the server already holds the
    -- clip, and collecting a second copy would be pure surplus data.
    constraint content_reports_evidence_scope
        check (evidence is null or target_type = 'message_sender'),

    -- The gate, stated as data. Neither direction is reachable through an application bug.
    constraint content_reports_disclosure_coherent
        check ((disclosure = 'metadata_only'     and evidence is null)
            or (disclosure = 'reporter_attached' and evidence is not null)),

    -- Conversation context belongs to message reports and only to message reports. A clip
    -- report carrying a conversation id would be a quiet claim about where somebody saw
    -- something, which is metadata nobody asked for.
    constraint content_reports_context_scope
        check (context_conversation_id is null or target_type = 'message_sender'),
    constraint content_reports_context_required
        check (target_type <> 'message_sender' or context_conversation_id is not null),

    -- An open report has no verdict; a resolved one has both a timestamp and a verdict.
    -- `resolved_by` is deliberately absent from this check — it can legitimately become
    -- NULL later if the admin row is deleted, and a constraint that made THAT fail would
    -- turn removing an admin account into an error nobody can explain.
    constraint content_reports_resolution_coherent
        check ((status = 'open'
                and resolved_at is null and resolution is null and resolution_note is null)
            or (status = 'resolved'
                and resolved_at is not null and resolution is not null))
);


-- ─────────────────────────────────────────────────────────────────────────────────
-- ANTI REPORT-BOMBING
--
-- One OPEN report per (target, reporter). Without this, one account can file forty
-- reports on one clip in a minute and the queue's "40 reports" signal — the thing a
-- moderator prioritises by — becomes a measure of how angry one person is.
--
-- ALL THREE KEY COLUMNS ARE NOT NULL, and must stay that way. If any nullable column
-- is ever added to this key, Postgres treats every NULL as distinct: the constraint
-- stops matching, ON CONFLICT stops firing, and the upsert below silently becomes an
-- insert. That failure is invisible — no error, just duplicate rows — which is why it
-- is called out here rather than trusted to review. (The repair plan flags exactly this
-- hazard for 3.29.)
--
-- WHY PARTIAL (`where status = 'open'`) RATHER THAN THE PLAIN UNIQUE THE PLAN PROPOSES.
-- A total unique key means a user who reports an account, gets a "no action" verdict,
-- and is then harassed by the same account NEXT MONTH can never report it again — their
-- one row is used up forever. Scoping uniqueness to open reports keeps the anti-bombing
-- property (you cannot stack reports on a live case) while letting a closed case be
-- reopened by new behaviour. The trade is that the lifetime count of reports against a
-- target is a count of rows, not a count of reporters; the admin queue counts DISTINCT
-- reporters where that distinction matters.
-- ─────────────────────────────────────────────────────────────────────────────────
create unique index if not exists idx_content_reports_one_open
    on content_reports (target_type, target_id, reporter_user_id)
    where status = 'open';

-- THE queue query: newest-first over open reports, keyset-paginated on (created_at, id)
-- and never OFFSET — offset pagination on a queue whose rows are being resolved
-- underneath you SKIPS rows, which on a moderation queue means silently never seeing a
-- report. Partial so the index only carries rows the queue can return.
create index if not exists idx_content_reports_open
    on content_reports (created_at desc, id desc)
    where status = 'open';

-- Grouping open reports by what they are about — the "12 reports on this clip" number
-- the queue is actually worked from.
create index if not exists idx_content_reports_target
    on content_reports (target_type, target_id)
    where status = 'open';

-- Two readers: "what have I reported" for the user's own receipt, and the DPDP access /
-- erasure path, which has to find every row belonging to one person without a seq scan.
create index if not exists idx_content_reports_reporter
    on content_reports (reporter_user_id, created_at desc);


-- ─────────────────────────────────────────────────────────────────────────────────
-- Declared retention (030_dpdp.sql). ON CONFLICT DO NOTHING so a re-run cannot stomp
-- the worker-written columns, matching how 030 seeds its own rows.
-- ─────────────────────────────────────────────────────────────────────────────────
insert into data_retention_policy
    (table_name, personal_data, purpose, retention_basis, declared_interval, enforced_by,
     sweep_rule, counsel_note)
values
    ('content_reports',
     'reporter user id and their free-text note; the reported user id or clip id; the conversation id a message report was filed from; and, ONLY where the reporter explicitly attached it, message text their own device decrypted (disclosure = ''reporter_attached'')',
     'Let users report content and accounts, and give moderators a queue to act on. The row is also the record of why something was taken down.',
     'account_lifetime', null, 'erasure_worker',
     'No time sweep. Rows die with the reporter''s account via the ON DELETE CASCADE on reporter_user_id; the erasure worker owns them, not the retention worker.',
     '[COUNSEL] Two open questions, neither resolved here. (1) Whether a RESOLVED report that justified a takedown must outlive the reporter''s erasure for the takedown to stay defensible — this table currently says no, inheriting the unresolved stub question in 11_admin_dpdp.md §6. (2) Whether IT Rules 2021 grievance obligations impose a retention FLOOR on reports and their resolutions, in which case account_lifetime is not merely a placeholder but wrong. Nothing in this file asserts that Voiid meets any grievance timeline.')
on conflict (table_name) do nothing;


-- ─────────────────────────────────────────────────────────────────────────────────
-- WHAT THIS FILE DELIBERATELY DOES NOT ADD
--
-- No user suspension, ban or shadow-ban column. Resolving a report against a person can
-- currently end in 'no_action' or 'escalated', and that is honest: there is no account
-- sanction anywhere in this schema, and inventing one as a side effect of building a
-- report queue would ship the most consequential moderation power in the product with no
-- appeal path, no notice to the affected person, and no design review. When account
-- sanctions are built they get their own migration, their own audit action, and their own
-- argument about due process.
--
-- No auto-removal threshold. "Hide anything with N reports" is one brigading campaign away
-- from being a takedown API operated by whoever can muster N accounts. Every takedown here
-- goes through admin_audit_log with a person's name on it.
--
-- No notification to the reported user, and no read path for them. Telling someone they
-- were reported, in a product where reports come from people they are in a conversation
-- with, is a retaliation vector.
-- ─────────────────────────────────────────────────────────────────────────────────
