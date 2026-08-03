-- Snake (docs/GAMES.md §80, §137) — the first ARCADE game and the first continuous one.
--
-- Additive-only, like 025: 024 and 025 are already applied on dev and the runner tracks
-- applied files by name, so an edit to either would never re-run.

-- Snake is the first catalog row with min_players = 1.
--
-- Every game so far has been strictly 1:1, so `min_players default 2` was a safe assumption.
-- Snake's practice mode is a genuine single-player match — one human against server-side
-- bots — and it is a real match row, not a client-side simulation, because the rules live on
-- the server for every mode (the alternative would be a second copy of the rules on the
-- client, which is precisely what server-authority exists to avoid).
--
-- max_players 6 rather than the .io genre's usual 25: each additional snake costs a full
-- body polyline in every broadcast at 12 Hz, so the ceiling is a bandwidth decision, not a
-- gameplay one. Bots fill the arena beyond the human count at no wire cost, since they are
-- simulated server-side and serialize identically to a human snake.
insert into games (slug, name, category, min_players, max_players, icon_key) values
  ('snake', 'Snake', 'arcade', 1, 6, 'game_snake')
on conflict (slug) do nothing;
