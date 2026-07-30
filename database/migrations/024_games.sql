-- VOIID Games — catalog, matches, per-player results (docs/GAMES.md §2).
--
-- ============================ THE EXCEPTION THIS TABLE MAKES ============================
-- Every other user-content surface in this schema stores CIPHERTEXT the server cannot
-- read. Game state is different, and deliberately so: the server is the referee. It must
-- read moves to validate them, or "server-authoritative" means nothing and any modified
-- client can claim an illegal move happened.
--
-- That exception is SCOPED TO GAME STATE AND NOTHING ELSE. A game invite still travels
-- the ordinary E2EE message pipe as a normal message; only the match itself is readable.
-- This is not a precedent for weakening E2EE anywhere else.
-- =======================================================================================
--
-- WHAT IS NOT HERE: live match state. An arcade match updates 10-15x/second; writing that
-- to Postgres would be thousands of rows for something that is worthless 90 seconds later.
-- Live state lives in Redis under `match:<id>:state` (ephemeral, TTL-refreshed). These
-- tables hold only what must OUTLIVE the match: who played, who won, what the score was.

-- Static catalog. Seeded below and rarely touched; a new game is one INSERT plus a rules
-- module server-side and a renderer client-side.
create table if not exists games (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique,          -- 'tictactoe' — matches the rules-module folder name
  name          text not null,
  category      text not null,                 -- 'arcade' | 'board' | 'card'
  min_players   int  not null default 2,
  max_players   int  not null default 2,
  -- Client resolves its own asset for this key; the server never serves game art.
  icon_key      text,
  -- Lets a broken game be pulled from the catalog without a deploy.
  enabled       boolean not null default true,
  created_at    timestamptz not null default now()
);

create table if not exists game_matches (
  id            uuid primary key default gen_random_uuid(),
  game_id       uuid not null references games(id) on delete restrict,
  -- jsonb array of user ids rather than a join table: matches are read whole, always, and
  -- 2-4 players means a join table would be three extra queries for zero benefit. Ludo and
  -- the card games need >2, so a pair of columns would not have survived either.
  player_ids    jsonb not null,
  status        text not null default 'waiting',  -- waiting | active | finished | abandoned
  -- Null until someone wins. A draw finishes with status='finished' and winner_id null,
  -- which is why "finished" and "has a winner" are deliberately separate facts.
  winner_id     uuid references users(id) on delete set null,
  created_by    uuid not null references users(id) on delete cascade,
  created_at    timestamptz not null default now(),
  started_at    timestamptz,
  ended_at      timestamptz
);

-- The invite path polls "my pending matches", so this index carries the hot read.
create index if not exists idx_game_matches_status on game_matches (status, created_at desc);
-- Containment lookup for "matches I am in" — needs jsonb_path_ops to be usable at all.
create index if not exists idx_game_matches_players on game_matches using gin (player_ids jsonb_path_ops);

create table if not exists game_match_results (
  match_id      uuid not null references game_matches(id) on delete cascade,
  user_id       uuid not null references users(id) on delete cascade,
  score         int  not null default 0,
  placement     int,                            -- 1 = winner; null for a draw
  primary key (match_id, user_id)
);

create index if not exists idx_game_match_results_user on game_match_results (user_id);

-- Seed the catalog. ON CONFLICT so re-running the migration is a no-op, matching how the
-- rest of the migrations in this directory behave.
insert into games (slug, name, category, min_players, max_players, icon_key) values
  ('tictactoe', 'Tic Tac Toe', 'board', 2, 2, 'game_tictactoe'),
  ('rps',       'Rock Paper Scissors', 'board', 2, 2, 'game_rps')
on conflict (slug) do nothing;
