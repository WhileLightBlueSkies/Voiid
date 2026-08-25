-- In-place Ludo schema-v3 replacement. Applied migration 049 remains untouched.
alter table game_matches
    add column if not exists ludo_roster jsonb,
    add column if not exists controller_types jsonb,
    add column if not exists bot_difficulties jsonb,
    add column if not exists bot_policy_version text,
    add column if not exists bot_action_at timestamptz,
    add column if not exists former_controller_entitlements jsonb not null default '{}'::jsonb,
    add column if not exists winner_seat integer,
    add column if not exists winner_controller text,
    add column if not exists end_reason text;

do $$ begin
    if not exists (select 1 from pg_constraint where conname = 'game_matches_winner_controller_check') then
        alter table game_matches add constraint game_matches_winner_controller_check
            check (winner_controller is null or winner_controller in ('human', 'bot'));
    end if;
end $$;

create index if not exists game_matches_ludo_bot_action_idx
    on game_matches (bot_action_at)
    where bot_action_at is not null and status = 'active';

-- One human is sufficient because every other physical seat may be a server bot. API
-- validation still accepts exactly two or four roster entries and at least one human creator.
update games set min_players = 1, max_players = 4, category = 'board' where slug = 'ludo';

-- Old unfinished states are deliberately not converted. The games service restores them as
-- legacyVersionAbandoned because their decoration/drop/bot semantics are ambiguous.
