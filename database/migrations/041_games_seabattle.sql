-- Sea Battle (docs/games/future/SEA_BATTLE.md) — the first async game.
--
-- Additive-only, like 026: earlier migrations are already applied on dev and the runner tracks
-- applied files by name, so editing one would never re-run.
--
-- Strictly 1:1, so min/max both 2 — the existing single-select opponent picker works unchanged
-- and this game is not blocked on the multi-seat lobby work Ludo and Voiid Cards need.
--
-- Category 'board' rather than 'arcade': the category drives whether the runtime starts a tick
-- loop's worth of client machinery, and this game has no clock. A turn is one tap and the
-- interval between two turns is routinely hours, which is the whole point of it.
insert into games (slug, name, category, min_players, max_players, icon_key) values
  ('seabattle', 'Sea Battle', 'board', 2, 2, 'game_seabattle')
on conflict (slug) do nothing;
