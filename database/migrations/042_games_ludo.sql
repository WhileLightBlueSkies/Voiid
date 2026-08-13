-- Ludo (docs/games/future/LUDO.md) — the first catalog row with more than two seats.
--
-- Additive-only, like 026 and 041: earlier migrations are already applied and the runner tracks
-- applied files by name, so editing one would never re-run.
--
-- min_players 2, max_players 4. THE ENGINE AND THE API ALREADY HANDLE THIS; the gap is the
-- client picker, which is single-select on both platforms (README.md §2.4). So a 2-player Ludo
-- is fully playable on the existing lobby the day this row lands, and 3-4 players follows when
-- the multi-seat picker does — which is why the row allows 4 now rather than being widened later.
--
-- Category 'board': turn-based, no clock, no tick loop.
insert into games (slug, name, category, min_players, max_players, icon_key) values
  ('ludo', 'Ludo', 'board', 2, 4, 'game_ludo')
on conflict (slug) do nothing;
