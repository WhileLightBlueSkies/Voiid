-- Game release state — ship every game in the binary, decide from the server which ones
-- a given build may see.
--
-- ── THE PROBLEM ────────────────────────────────────────────────────────────────────
-- `games.enabled` was a two-state switch: in the catalog, or not. That answers "is this
-- game broken" and nothing else. It cannot express the three things release actually needs:
--
--   * a game that EXISTS in the binary but is not good enough to show yet;
--   * a game whose polish landed in a LATER build than the one a user is running;
--   * a game that is not built at all, but should appear as a teaser.
--
-- Native game code cannot be delivered out of band on iOS (App Store Guideline 2.5.2), so
-- every game ships inside the app and the server decides what is visible. That is not a
-- workaround — it is the only compliant shape, and it is also the better one: a flip is
-- instant, reversible, and needs no review.
--
-- ── THE THREE-STATE MODEL ──────────────────────────────────────────────────────────
--   'hidden'    — not on the shelf at all. The default for anything unfinished.
--   'announced' — a teaser. Drawn dimmed with a badge and NOT tappable, because there may
--                 be no code behind it in any build. The client renders it from THIS row's
--                 name/icon/blurb and never resolves it to a local renderer, so a game the
--                 app has never heard of can still be announced.
--   'live'      — playable, subject to min_app below.
--
-- ── min_app IS A QUALITY GATE, NOT A PRESENCE GATE ─────────────────────────────────
-- The subtlety that makes the whole thing work. It is NOT "the version where this game's
-- code first appeared" — it is "the version where this game is good enough to show".
--
-- Ship Snake hidden in 1.5 because its UI is rough. Polish it in 1.6. Set state='live',
-- min_app='1.6.0'. A user on 1.5 HAS Snake in their binary and still sees "Update to play",
-- which is correct: the copy in their build is the one you decided was not ready.
--
-- The same lever works after release. Find a bug in 1.6, fix it in 1.7, raise min_app —
-- 1.6 users are held at "Update to play" until they move, without pulling the game from
-- everyone.
--
-- NULL means no floor: every build that has the game may play it.
--
-- ── WHY THE CLIENT IS NEVER TOLD "UPDATE" WHEN IT ALREADY HAS THE GOOD BUILD ───────
-- The client compares min_app against its OWN version. A user already on 1.6 is never
-- shown an update prompt for a 1.6 game — the comparison cannot produce one. This is the
-- whole reason min_app lives here rather than a boolean "needs_update" flag, which would
-- have been a lie to exactly the users who had done nothing wrong.

alter table games
  add column if not exists release_state text not null default 'live'
    check (release_state in ('hidden', 'announced', 'live')),
  -- Semver 'X.Y.Z'. Text, not a composite: it is compared by the same cmpVersion the
  -- force-update path already uses, and storing it as a string keeps one representation
  -- of an app version across the whole system.
  add column if not exists min_app text
    check (min_app is null or min_app ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  -- Shown under an announced game's name. Optional, and worth setting: an announced game
  -- with no date reads as abandoned rather than as coming, the longer it sits there.
  add column if not exists teaser text,
  -- ── THE GAME'S OWN VERSION, SEPARATE FROM THE APP'S ─────────────────────────────
  -- Games iterate on their own clock. Snake can go through four visual passes while the
  -- app ships twice, and "which Snake is this?" is then unanswerable from the app version
  -- alone — 1.6.0 tells you when the binary was cut, not which board the user is looking
  -- at.
  --
  -- So each game carries its own semver, bumped when the GAME changes rather than when the
  -- app does. Three things this buys:
  --
  --   * a bug report says "Snake 2.1.0" instead of "the app version where Snake was
  --     probably the second one";
  --   * the admin panel shows what is actually live per game, at a glance;
  --   * min_app and game_version answer different questions and stay honest about it —
  --     min_app is "which BUILD may show this", game_version is "which ITERATION this is".
  --
  -- Server-side and descriptive: the client does not gate on it. Gating stays with
  -- min_app, because the client can only reason about its own app version.
  add column if not exists game_version text not null default '1.0.0'
    check (game_version ~ '^[0-9]+\.[0-9]+\.[0-9]+$');

-- `enabled` stays and keeps its original meaning — the emergency pull. A game is visible
-- only if enabled AND its release_state allows it, so the kill switch still works on a
-- game that is otherwise live, and nothing about the existing behaviour changes for rows
-- that never set the new columns.
comment on column games.release_state is
  'hidden | announced | live — see 064_game_release_state.sql';
comment on column games.min_app is
  'Minimum app version at which this game is considered good enough to play. NULL = no floor.';
comment on column games.game_version is
  'The GAME''s own semver, bumped when the game changes — not the app''s. Descriptive: gating is min_app.';

-- Everything currently in the catalog keeps behaving exactly as it does today.
update games set release_state = 'live' where release_state is null;
