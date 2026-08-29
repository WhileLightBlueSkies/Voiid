-- 055_community_entitlements.sql — per-community paid capabilities, granted by Voiid.
--
-- Creating and running a community stays FREE, and nothing in this file changes that. Home,
-- Spaces, Events, Members and About are the product; a host pays for none of them.
--
-- What this adds is a switch for capabilities that are paid-only and enabled per community,
-- on request, from the admin panel. E-commerce is the first. It is deliberately NOT a plan,
-- a tier, or a subscription: there is no billing state here, no renewal, no dunning, and no
-- entitlement engine. A row is granted by a human and can be revoked by one.
--
-- WHY A TABLE AND NOT A COLUMN ON `communities`
-- A boolean column answers "can they" and nothing else. The questions that actually arrive
-- are "who turned this on", "when", and "why" — a chargeback, a dispute, or a host insisting
-- they were promised something. Those need a row per grant, not a flag.
--
-- ============================ NOT END-TO-END ENCRYPTED ============================
-- A grant is an agreement between Voiid and a community's owner about what that community
-- may do. It is server-authored, server-enforced, and meaningless to encrypt to a client:
-- the whole point is that the SERVER refuses the write when the grant is absent. No message,
-- no media and no key material is involved.

create table if not exists community_entitlements (
  id                uuid primary key default gen_random_uuid(),
  community_id      uuid not null references communities(id) on delete cascade,

  -- Free text rather than an enum: adding a capability should not need a migration, and an
  -- unknown value fails CLOSED at the call site (nothing is granted by an unrecognised name).
  capability        text not null,

  -- Null means "until revoked". A grant is not a subscription and does not lapse on its own;
  -- an expiry exists for trials and pilots, which are the only reason to want one.
  granted_at        timestamptz not null default now(),
  expires_at        timestamptz,
  revoked_at        timestamptz,

  -- WHO granted it. Not nullable in spirit — every grant is a human decision — but the FK is
  -- ON DELETE SET NULL so removing an admin account cannot cascade away a community's
  -- capability. An orphaned grant is recoverable; a silently revoked one is not.
  granted_by        uuid references admin_users(id) on delete set null,

  -- The reason the host asked, in the granter's words. This is the field that answers the
  -- question a dispute actually asks, and it is required for the same reason a takedown
  -- reason is: a grant nobody can explain later is a grant nobody can defend.
  note              text not null,

  created_at        timestamptz not null default now(),

  constraint community_entitlements_capability_ck
    check (capability ~ '^[a-z][a-z0-9_]{2,39}$'),
  constraint community_entitlements_note_ck
    check (length(btrim(note)) between 1 and 500),
  constraint community_entitlements_window_ck
    check (expires_at is null or expires_at > granted_at)
);

-- ONE LIVE GRANT per (community, capability). A partial unique index rather than a plain one:
-- revoked and expired rows are the history this table exists to keep, and a plain unique
-- constraint would force us to delete them — throwing away the record of who had what, when.
create unique index if not exists community_entitlements_live_uq
  on community_entitlements (community_id, capability)
  where revoked_at is null;

-- The read path is always "what is this community entitled to", so that is the index.
create index if not exists community_entitlements_lookup_ix
  on community_entitlements (community_id, capability)
  where revoked_at is null;

comment on table community_entitlements is
  'Paid capabilities granted to a specific community by a Voiid admin. Not a subscription: '
  'no billing state, no renewal. Creating and running a community remains free.';
