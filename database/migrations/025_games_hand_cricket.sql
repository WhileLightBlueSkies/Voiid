-- Hand Cricket (docs/GAMES_HAND_CRICKET.md).
--
-- Two changes, both additive: a per-match options bag, and the catalog row.
--
-- WHY A NEW MIGRATION RATHER THAN EDITING 024: 024 is already applied on dev, and the
-- runner tracks applied files by name — an edit would never re-run. Additive forward
-- migrations are the only safe shape once a file has shipped.

-- Per-match settings chosen at creation, before any state exists.
--
-- Hand cricket needs the over count (1-5) to build its opening state, and the match is
-- constructed LAZILY on first join (backend/games reads this row), so the value cannot live
-- in the client or in the invite — it has to be durable on the match itself.
--
-- jsonb rather than an `overs int` column, deliberately: this is per-GAME configuration, and
-- a dedicated column per game's settings would mean a migration for every future game that
-- has any. The engines validate what they read, exactly as they validate client input.
alter table game_matches
  add column if not exists options jsonb not null default '{}'::jsonb;

-- Hand cricket. min/max 2 players like the other two: the whole invite model is 1:1.
insert into games (slug, name, category, min_players, max_players, icon_key) values
  ('cricket', 'Hand Cricket', 'board', 2, 2, 'game_cricket')
on conflict (slug) do nothing;
