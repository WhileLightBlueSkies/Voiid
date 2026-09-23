-- Moderator tags, institution communities, and host KYC for paid events.
--
-- ── 1. THE MODERATOR TAG IS A GRANT, NOT A ROLE ─────────────────────────────────────
--
-- A "Community moderator" tag on someone's posts is a statement BY VOIID that this person
-- speaks for this community — a college's student council, a verified club's office bearers.
-- It is deliberately separate from community_members.role:
--
--   * a host can make anyone an admin; only a Voiid admin can make anyone WEAR THE TAG, so the
--     tag cannot be self-awarded by whoever happens to own a community;
--   * the tag is MODULAR — `badge` is a vocabulary with one word today, and a second kind of
--     tag is a CHECK constraint change, not a new table or a new column on every post.
--
-- A community may carry tags only while it holds the `moderator_badge` entitlement (055) or is
-- official (066). routes/admin.ts enforces that at grant time, and revoking the entitlement
-- revokes the tags, so a post never shows a tag its community is no longer allowed to give.
--
-- The tag is read at render time (routes/communities.ts AUTHOR_JOIN), never stamped onto the
-- post: revoking it takes it off every past post at once, which is what "this person no longer
-- speaks for us" has to mean.
create table if not exists community_member_badges (
    id           uuid primary key default gen_random_uuid(),
    community_id uuid not null references communities(id) on delete cascade,
    user_id      uuid not null references users(id) on delete cascade,
    badge        text not null,
    granted_by   uuid references admin_users(id) on delete set null,
    granted_at   timestamptz not null default now(),
    revoked_at   timestamptz,
    revoked_by   uuid references admin_users(id) on delete set null,
    -- Why, in the granter's words — same rule as entitlements (055): a grant nobody can
    -- explain later is a grant nobody can defend.
    note         text not null,
    constraint community_member_badges_badge_ck check (badge in ('community_moderator')),
    constraint community_member_badges_note_ck check (length(btrim(note)) between 1 and 500)
);

-- One live tag of each kind per person per community; revoked rows are history.
create unique index if not exists community_member_badges_live_uq
    on community_member_badges (community_id, user_id, badge)
    where revoked_at is null;

-- ── 2. INSTITUTIONS ─────────────────────────────────────────────────────────────────
--
-- An institution community is an ordinary community that Voiid created for a verified
-- institution and assigned to its owner account. The name is what the verified mark reads
-- ("IIT Bombay"), and like official_key it is written only by the admin panel: public
-- create/PATCH do not list it, so a host cannot call their club a university.
alter table communities add column if not exists institution_name text;
do $$ begin
    alter table communities add constraint communities_institution_name_ck
        check (institution_name is null or length(btrim(institution_name)) between 2 and 120);
exception when duplicate_object then null; end $$;

-- ── 3. HOST KYC ─────────────────────────────────────────────────────────────────────
--
-- Selling tickets pays money OUT to a host, so the host has to be a known person first.
-- Cashfree Secure ID checks the PAN and the bank account; a Voiid admin reviews the result
-- and any documents; only then can the host price an event.
--
-- WHAT IS NOT STORED: the full PAN and the full account number. Both are used once — sent to
-- Secure ID and to Easy Split's vendor registration during the same request — and then only
-- the last four characters are kept. A leak of this table cannot be spent.
create table if not exists host_verifications (
    user_id            uuid primary key references users(id) on delete cascade,
    status             text not null default 'draft',
    legal_name         text,
    email              text,

    pan_last4          text,
    pan_registered_name text,
    pan_valid          boolean,
    pan_name_match     boolean,
    pan_reference      text,

    bank_last4         text,
    ifsc               text,
    bank_name          text,
    name_at_bank       text,
    bank_name_match    text,
    bank_reference     text,

    -- Easy Split vendor: where the host's share of each order settles.
    cashfree_vendor_id text unique,
    vendor_status      text,

    submitted_at       timestamptz,
    reviewed_at        timestamptz,
    reviewed_by        uuid references admin_users(id) on delete set null,
    rejection_reason   text,
    created_at         timestamptz not null default now(),
    updated_at         timestamptz not null default now(),

    constraint host_verifications_status_ck
        check (status in ('draft', 'pending_review', 'verified', 'rejected')),
    constraint host_verifications_last4_ck
        check ((pan_last4 is null or pan_last4 ~ '^[A-Z0-9]{4}$')
           and (bank_last4 is null or bank_last4 ~ '^[0-9A-Za-z]{1,4}$')),
    -- A verified host is one money can be paid to: both checks passed and a vendor exists.
    constraint host_verifications_verified_ck
        check (status <> 'verified' or (pan_valid and cashfree_vendor_id is not null))
);

create index if not exists host_verifications_queue_ix
    on host_verifications (submitted_at) where status = 'pending_review';

-- Documents the host uploads for review. The FILE is in R2 under `kyc/<user>/…`, a prefix no
-- public route will presign: POST /media/presign-download accepts `media/` keys only, and
-- routes/kyc.ts presigns `kyc/` keys for the admin panel alone, one audit row per view.
create table if not exists kyc_documents (
    id           uuid primary key default gen_random_uuid(),
    user_id      uuid not null references users(id) on delete cascade,
    kind         text not null,
    r2_key       text not null unique,
    mime         text not null,
    uploaded_at  timestamptz not null default now(),
    -- Set when the client confirms the upload landed; an unconfirmed row is an abandoned
    -- presign and is never shown to a reviewer.
    confirmed_at timestamptz,
    deleted_at   timestamptz,
    constraint kyc_documents_kind_ck
        check (kind in ('pan_card', 'bank_proof', 'address_proof', 'institution_letter', 'other')),
    constraint kyc_documents_key_ck check (r2_key like 'kyc/%'),
    constraint kyc_documents_mime_ck check (mime in ('image/jpeg', 'image/png', 'application/pdf'))
);

create index if not exists kyc_documents_user_ix
    on kyc_documents (user_id) where deleted_at is null;

comment on table host_verifications is
    'Host KYC for paid events. Stores only last-4 of PAN and account; full numbers go to '
    'Cashfree and are never persisted.';
