-- 018_location_shares.sql
-- Location sharing SESSIONS ONLY (docs/LOCATION.md §6). Read the table definitions
-- below and note what is absent: there is NO latitude, NO longitude, NO accuracy, NO
-- ciphertext, NO key column, NO last-seen timestamp and NO update counter anywhere in
-- this migration. That is deliberate and load-bearing.
--
-- WHERE THE COORDINATES ACTUALLY LIVE: nowhere on the server. A static pin is an
-- ordinary E2EE message (Double Ratchet 1:1 / MLS for groups) and lands in `messages`
-- as opaque ciphertext like any other. A live position fix is encrypted on-device under
-- a share key the server never sees, and is RELAYED over the WebSocket process
-- (backend/websocket) exactly like call SDP — never written to Postgres at all.
--
-- WHY THESE ROWS EXIST AT ALL, given the server can't read anything useful:
--   (a) the WS relay process has no database, so `POST /location/shares` is the only
--       place conversation membership can be validated and share creation rate-limited;
--   (b) revocation must survive the sharer going offline — an ended/revoked row plus
--       the routing signal it publishes is how an offline recipient eventually learns
--       the share stopped;
--   (c) a reinstalled/relinked device can discover "you still have an outbound share
--       running" instead of broadcasting silently forever.
--
-- THE HONEST METADATA STATEMENT (must stay in sync with the privacy policy):
--   VOIID's servers know that a share exists, who it is with, and when it ends.
--   They never know where you are, whether you moved, or how often you updated.

create table if not exists location_shares (
    id              uuid primary key default gen_random_uuid(),
    owner_user_id   uuid not null references users(id) on delete cascade,
    -- 'conversation' = a time-boxed live share inside a chat; 'map' = ambient,
    -- coarse Map presence to an explicitly named allow-list.
    kind            text not null check (kind in ('conversation','map')),
    -- kind='conversation' only; null for map presence (which is not chat-scoped).
    conversation_id uuid references conversations(id) on delete cascade,
    started_at      timestamptz not null default now(),
    -- EVERY share is bounded. There is no indefinite option, and expiry is enforced by
    -- every read path filtering on this column — so it stays correct with no reaper
    -- process running at all (there is no worker in this repo; see docs/LOCATION.md §9).
    expires_at      timestamptz not null,
    -- Explicit stop (owner ended it early). Terminal; never un-set.
    ended_at        timestamptz,
    constraint location_shares_kind_conversation check (
        (kind = 'conversation' and conversation_id is not null) or
        (kind = 'map'          and conversation_id is null)
    )
);

-- Who may see this share. Kept per-target (rather than inferring the audience from
-- conversation membership) because that is what makes single-recipient revocation
-- possible without ending the share for everyone else.
create table if not exists location_share_targets (
    share_id        uuid not null references location_shares(id) on delete cascade,
    target_user_id  uuid not null references users(id) on delete cascade,
    -- set when the owner revokes this one recipient, OR when the recipient opts out
    -- via /leave. Both are "this pair is over" and neither ends the share for others.
    revoked_at      timestamptz,
    primary key (share_id, target_user_id)
);

-- Partial indexes on ACTIVE shares only: every query in routes/location.ts filters
-- `ended_at is null and expires_at > now()`, and the active set is tiny (a handful of
-- rows per user) even though the table accumulates history until housekeeping trims it.
create index if not exists idx_location_shares_owner_active
    on location_shares (owner_user_id, kind) where ended_at is null;
create index if not exists idx_location_shares_expires
    on location_shares (expires_at) where ended_at is null;
create index if not exists idx_location_share_targets_user_active
    on location_share_targets (target_user_id) where revoked_at is null;
create index if not exists idx_location_share_targets_share
    on location_share_targets (share_id);
