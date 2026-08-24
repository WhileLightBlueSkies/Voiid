-- 049_ludo_game_v2.sql — Ludo schema-v2 (LUDO_GAME_SPEC.md §18.3).
--
-- Additive-only, like every games migration before it: earlier files are applied and tracked
-- by name, so editing one would never re-run. The catalog row keeps slug='ludo' — this is a
-- VERSIONED REPLACEMENT of the existing game, never a second `ludo_v2`.
--
-- WHAT THE FEATURE NEEDS THAT v1 DID NOT STORE:
--   mode                    duel (2 seats) or four (4 seats); no three-player setup exists
--   source_conversation_id  the chat the invite came from; authorizes identity projection
--   rules_version / schema_version   lets a v1 row be recognised and abandoned, not converted
--   terminal_audit          the RNG seed revealed at game end so a match is auditable
--   invite fields           expiry metadata for chat invite cards
--   game_match_state.commands        durable idempotency: last 64 processed command ids

alter table game_matches
    add column if not exists mode                          text,
    add column if not exists source_conversation_id        uuid references conversations(id) on delete set null,
    add column if not exists rules_version                 text not null default 'legacy',
    add column if not exists schema_version                integer not null default 1,
    add column if not exists terminal_audit                jsonb,
    -- IDEMPOTENT CREATE (§7.1): a retried idempotency_key returns the same match instead of
    -- minting a second lobby.
    add column if not exists idempotency_key               uuid;

create unique index if not exists game_matches_creator_idem_idx
    on game_matches (created_by, idempotency_key)
    where idempotency_key is not null;

-- Only the two shapes the contract allows.
do $$ begin
    if not exists (
        select 1 from pg_constraint where conname = 'game_matches_mode_check'
    ) then
        alter table game_matches
            add constraint game_matches_mode_check check (mode is null or mode in ('duel', 'four'));
    end if;
end $$;

create index if not exists game_matches_source_conversation_idx
    on game_matches (source_conversation_id)
    where source_conversation_id is not null;

-- Durable idempotency for WebSocket commands (§7.1): a retry with a seen command id must not
-- produce a second action even across a service restart.
alter table game_match_state
    add column if not exists commands jsonb not null default '{}'::jsonb;

-- First-run walkthrough marker (§10): persisted cross-device; the local write does not wait
-- on the server round trip.
create table if not exists user_game_preferences (
    user_id     uuid primary key references users(id) on delete cascade,
    preferences jsonb not null default '{}'::jsonb,
    updated_at  timestamptz not null default now()
);

-- Catalog row stays exactly as wide as the contract allows (min 2, max 4). The API permits
-- only exact 2 or exact 4 for Ludo; the engine refuses anything else.
update games
   set min_players = 2, max_players = 4, category = 'board'
 where slug = 'ludo';
