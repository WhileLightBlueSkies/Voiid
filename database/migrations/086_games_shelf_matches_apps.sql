-- The catalog, brought in line with the shelf the apps actually show.
--
-- ── WHY ───────────────────────────────────────────────────────────────────────────
-- Until now both apps drew their Games tab from a list compiled into the build and never
-- read GET /games, so the admin panel's release controls (hidden / announced / live, the
-- emergency pull, min_app) changed nothing a player could see. The apps now build the shelf
-- from this table. For that to be a no-op on day one, the table has to describe today's
-- shelf:
--
--   Playable   — Ludo, Snake, Carrom (Carrom on iOS; Android lists it as coming soon,
--                because its build has no Carrom screen and shows a live row it cannot
--                open under "Coming soon").
--   Announced  — Word Duel, Quiz Night.
--   Not shown  — Tic Tac Toe, Rock Paper Scissors, Hand Cricket, Sea Battle.
--
-- ── WHAT "HIDDEN" DOES AND DOES NOT DO TO THE FOUR ────────────────────────────────
-- Hidden removes them from GET /games — the shelf, and iOS's tournament picker. It does NOT
-- stop a match: POST /games/matches refuses only a pulled (enabled = false) or announced
-- game, so a chat duel that names one of them keeps working. Turn any of them back on from
-- the admin panel; that is now a real switch.
--
-- ── CARROM IS ONE SEAT ─────────────────────────────────────────────────────────────
-- Carrom is you against an on-device bot, with no server engine. max_players = 1 keeps it
-- out of anything that seats two people server-side (the tournament picker filters on
-- min <= 2 <= max), where it could only fail.

insert into games (slug, name, category, min_players, max_players, icon_key, release_state, teaser)
values
  ('carrom', 'Carrom',     'board',  1, 1, 'game_carrom', 'live',      null),
  ('word',   'Word Duel',  'trivia', 2, 2, 'game_word',   'announced', 'Two players, one board, seven letters.'),
  ('quiz',   'Quiz Night', 'trivia', 2, 8, 'game_quiz',   'announced', 'Ten questions, everyone at once.')
on conflict (slug) do nothing;

update games
   set release_state = 'hidden'
 where slug in ('tictactoe', 'rps', 'cricket', 'seabattle')
   and release_state = 'live';
