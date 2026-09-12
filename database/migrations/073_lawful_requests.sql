-- LAWFUL REQUESTS: the record of what a government asked for and what we handed over.
--
-- WHY THIS IS A CASE FILE AND NOT A LOOKUP BOX
-- ============================================
-- The obvious build for "give the government what they ask for" is a text field that takes
-- a phone number and prints everything Voiid knows about that person. That tool is a mass
-- surveillance interface with a legal justification bolted on afterwards, and it is the
-- shape that gets abused — by an insider looking up an ex, by a stolen admin session, by a
-- staff member under pressure from someone with a badge and no warrant. Uber's "God View"
-- and the NSA's LOVEINT cases are both this exact build.
--
-- So the order comes FIRST. A disclosure cannot exist without a request row naming the
-- authority, the statute, the reference number, and the scope. Looking someone up without
-- one is not gated behind a warning; there is no route that does it.
--
-- WHAT THIS BUYS, CONCRETELY
--   * A regulator or court asking "who did you disclose, to whom, under what authority"
--     has one table to read, with the order attached.
--   * A subject exercising DPDP rights can be told precisely what left the building.
--   * An insider cannot browse. Every read of subject data is attributable to a request,
--     and every request names a human who approved it.
--   * Over-disclosure becomes visible: the scope is recorded, so handing over more than
--     was asked for shows up as a mismatch rather than disappearing into a zip file.
--
-- WHAT WE STILL CANNOT PRODUCE, AND WHY THAT IS NOT A GAP IN THIS TABLE
-- Message content. Voiid's servers hold ciphertext whose keys never leave user devices
-- (packages/e2e-core). A demand for "the messages" is answered with what we have —
-- ciphertext we cannot read — and that answer is recorded here like any other. This table
-- deliberately has no column that could hold decrypted content, because there is no
-- mechanism that could fill it.

-- ── The request ────────────────────────────────────────────────────────────────────────
create table if not exists lawful_requests (
    id                uuid primary key default gen_random_uuid(),

    -- WHO IS ASKING. Free text because the set of authorities is not ours to enumerate:
    -- a state cyber cell, a magistrate's court, a foreign authority via MLAT.
    authority         text not null,
    -- The statute or instrument relied on. Recorded as given, so a later reviewer can
    -- judge whether it actually authorises what was asked.
    -- India in practice: CrPC 91 (production), IT Act 69 (interception/decryption),
    -- IT Act 91/DPDP s.36 (government access), a court warrant, or an MLAT request.
    legal_basis       text not null,
    -- The authority's own reference — FIR number, case number, notice number. This is how
    -- they will refer to it when they follow up, and how we prove which order we answered.
    reference         text not null,

    -- WHAT THEY ASKED FOR, in their words. The scope check later compares what we
    -- disclosed against this, so it is stored verbatim rather than normalised.
    scope_requested   text not null,

    -- HOW IT ARRIVED. A phone call is not an order; recording the channel makes an
    -- improperly-served demand visible instead of laundering it into the same queue.
    received_channel  text not null check (received_channel in
                          ('sealed_post','email','in_person','court_portal','mlat','other')),
    received_at       timestamptz not null default now(),

    -- THE ORDER ITSELF, AS SERVED — the FIR copy, notice, or warrant.
    --
    -- Nullable only so a request can be LOGGED the moment it arrives, before anyone has
    -- had time to scan the paperwork. It stops being optional the instant the request
    -- moves to a complying state: see `lawful_document_required` below, which refuses at
    -- the database rather than in a form handler. A disclosure made on a phone call from
    -- someone claiming to be an officer is the exact failure this prevents, and a UI
    -- check is one bug away from not existing.
    --
    -- Object key in the evidence bucket; never the document bytes in Postgres.
    order_document_key text,
    -- Digest of the served document, so the copy we were shown can be proven to be the
    -- copy we still hold. An authority that later produces a different order, or a staff
    -- member who swaps the file, both become visible.
    order_document_sha256 text check (order_document_sha256 is null
                                      or order_document_sha256 ~ '^[0-9a-f]{64}$'),
    -- What was actually served, so "FIR" is not doing duty for everything. A statement
    -- recorded here that does not match the legal_basis is a review flag.
    order_document_kind text check (order_document_kind in
                            ('fir','court_warrant','magistrate_order','written_notice',
                             'mlat_request','other')),

    -- THE SUBJECT, identified the way the authority identified them. Phone number as
    -- served, plus the user we resolved it to (null when no such account exists — which is
    -- itself a valid, recorded outcome).
    subject_phone     text not null,
    subject_user_id   uuid references users(id) on delete set null,

    status            text not null default 'received' check (status in (
                          'received',      -- logged, not yet reviewed
                          'under_review',  -- counsel/ops assessing validity and scope
                          'refused',       -- invalid, overbroad, or improperly served
                          'narrowed',      -- partially complied after pushing back on scope
                          'complied',      -- disclosed within scope
                          'no_data',       -- valid order, nothing responsive held
                          'withdrawn'      -- authority withdrew it
                      )),

    -- WHY, in one place, for whichever way it went. A refusal with no stated reason is
    -- indefensible later; so is a disclosure.
    decision_note     text,
    -- Emergency/expedited requests exist and are sometimes legitimate (imminent harm).
    -- Flagged rather than fast-tracked silently, so the exception stays visible in review.
    emergency         boolean not null default false,

    -- TWO-PERSON RULE. A disclosure needs someone who prepared it and a DIFFERENT someone
    -- who approved it. Enforced in the route, recorded here.
    opened_by         uuid references admin_users(id) on delete set null,
    approved_by       uuid references admin_users(id) on delete set null,
    approved_at       timestamptz,

    -- WAS THE SUBJECT TOLD. Notification is sometimes barred by the order itself; the
    -- distinction between "we chose not to" and "we were forbidden to" matters, and gets
    -- lost if this is a single boolean.
    subject_notified  text not null default 'pending' check (subject_notified in
                          ('pending','notified','barred_by_order','deferred','not_required')),

    closed_at         timestamptz,
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now(),

    -- An approval must name a different admin from the one who opened it. A rule that
    -- lives only in the route is a rule one refactor away from being gone.
    constraint lawful_two_person check (approved_by is null or approved_by <> opened_by),

    -- NO PAPER, NO DISCLOSURE — enforced here rather than in a form handler.
    --
    -- Reaching any state where data left the building requires the served document and its
    -- digest on the row. 'refused', 'withdrawn' and 'under_review' are deliberately exempt:
    -- refusing an order that arrived as a phone call is a legitimate and important outcome,
    -- and demanding paperwork to record that refusal would push it off the system entirely,
    -- which is the opposite of what this table is for.
    --
    -- 'no_data' IS included. Confirming to an authority that a person has no account is
    -- itself a disclosure about that person, and it needs the same authority behind it.
    constraint lawful_document_required check (
        status not in ('complied','narrowed','no_data')
        or (order_document_key is not null and order_document_sha256 is not null)
    ),
    -- An approved request is a request someone signed off on; it needs the order attached
    -- at the moment of approval, not afterwards.
    constraint lawful_approval_needs_document check (
        approved_by is null or order_document_key is not null
    )
);

create index if not exists idx_lawful_requests_status  on lawful_requests (status, received_at desc);
create index if not exists idx_lawful_requests_subject on lawful_requests (subject_user_id);
create index if not exists idx_lawful_requests_phone   on lawful_requests (subject_phone);

-- ── What actually left the building ────────────────────────────────────────────────────
--
-- One row per category disclosed, not one per request. A request answered with "subscriber
-- info and call records" produces two rows, because a subject asking "what did you give
-- them" deserves that answer at category granularity, and because partial compliance is
-- the normal case rather than the exception.
create table if not exists lawful_disclosures (
    id            uuid primary key default gen_random_uuid(),
    request_id    uuid not null references lawful_requests(id) on delete cascade,

    -- The category, from a CLOSED LIST. Closed on purpose: a free-text field here would
    -- let a disclosure be described vaguely enough to hide what it contained, and the
    -- list doubles as the statement of what this system is capable of producing.
    category      text not null check (category in (
                      'subscriber_info',     -- phone, registration date, platform
                      'device_list',         -- devices on the account, platform, last seen
                      'contact_graph',       -- contact_sync edges
                      'conversation_members',-- who is in which conversation (NOT content)
                      'community_members',   -- community/space membership
                      'call_records',        -- calls + participants metadata, no media
                      'location_shares',     -- who shared with whom; payload stays E2EE
                      'blocked_list',
                      'push_tokens',
                      'security_events',     -- auth events and the IPs on them
                      'ciphertext',          -- message_ciphertexts as held: undecryptable
                      'account_status'
                  )),

    -- The count disclosed, so the volume is on the record and not just the shape.
    record_count  integer not null default 0 check (record_count >= 0),

    -- Where the produced artefact went. Evidence-bucket key, never the payload itself:
    -- a disclosure bundle in Postgres is a second copy of the data we were compelled to
    -- reveal once, sitting somewhere with weaker access control than the tables it came
    -- from.
    artifact_key  text,
    -- Digest of what was handed over, so the exact bytes can be proven later without
    -- retaining them here.
    artifact_sha256 text check (artifact_sha256 is null or artifact_sha256 ~ '^[0-9a-f]{64}$'),

    disclosed_by  uuid references admin_users(id) on delete set null,
    disclosed_at  timestamptz not null default now(),

    unique (request_id, category)
);

create index if not exists idx_lawful_disclosures_request on lawful_disclosures (request_id);

-- ── Every look at subject data, whether or not it was disclosed ─────────────────────────
--
-- SEPARATE FROM lawful_disclosures ON PURPOSE. Assessing an order means looking at what we
-- hold before deciding what to hand over, and that look is exactly the access an insider
-- would want to make unattributable. A table that only records disclosures leaves reading
-- unlogged, which is the wrong half to leave open.
create table if not exists lawful_access_log (
    id          bigserial primary key,
    request_id  uuid not null references lawful_requests(id) on delete restrict,
    admin_id    uuid references admin_users(id) on delete set null,
    category    text not null,
    record_count integer not null default 0,
    -- Kept even when the answer was "nothing" — an empty read is still a read.
    created_at  timestamptz not null default now()
);

create index if not exists idx_lawful_access_request on lawful_access_log (request_id, created_at desc);
create index if not exists idx_lawful_access_admin   on lawful_access_log (admin_id, created_at desc);

-- ── Retention ──────────────────────────────────────────────────────────────────────────
--
-- These rows are the PROOF that a disclosure was lawful, so they outlive the data they
-- describe and are not swept on an interval. 'not_yet_enforced' is the honest state:
-- nobody has set a period, and inventing one here would be the engineering guess this
-- register exists to prevent. Counsel decides, then this row changes.
insert into data_retention_policy
    (table_name, personal_data, purpose, retention_basis, enforced_by, sweep_rule)
values
    ('lawful_requests',
     'Subject phone number and resolved user id; the requesting authority and its reference.',
     'Evidence that a government disclosure was demanded under a stated legal basis, and what we decided.',
     'not_yet_enforced', 'none',
     'No sweep. This is the audit trail for a compelled disclosure and must outlive the data it describes; period to be set by counsel.'),
    ('lawful_disclosures',
     'Category and volume of personal data disclosed about the subject; digest of the artefact.',
     'Record of exactly what left the building, at category granularity, for regulator and subject answers.',
     'not_yet_enforced', 'none',
     'No sweep. Deleted only with its parent request, by cascade, once counsel sets a period.'),
    ('lawful_access_log',
     'Which admin read which category of subject data, and when.',
     'Insider-abuse detection: makes every read of subject data attributable to a specific order and person.',
     'not_yet_enforced', 'none',
     'No sweep. Access history is the control; truncating it defeats the purpose.')
on conflict (table_name) do nothing;
