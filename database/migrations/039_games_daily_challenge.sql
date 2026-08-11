-- The daily challenge (docs/games/CROSS_CUTTING.md §5, SNAKE_COMPETITIVE_PARITY.md §4 P3.8).
--
-- One seeded Snake arena per day, identical for everyone, board resets at midnight.
--
-- THERE IS NO SCORES TABLE HERE, ON PURPOSE. Every finished match already writes a row to
-- `game_match_results` with the player's score, so a daily board is a query over rows that
-- exist rather than a second place scores are recorded. A parallel table would be a second
-- source of truth for the same number, and the day the two disagree the leaderboard is lying.
--
-- What was genuinely missing is which day a match belongs to, which is what this adds.

-- The challenge day, as a date in UTC. Null for every ordinary match, which is all of them
-- so far — this is additive and rewrites nothing.
--
-- A COLUMN RATHER THAN A DERIVED `date(created_at)`. The day a match COUNTS FOR is not the day
-- it was created: a player who starts at 23:59:58 is playing today's arena, and deriving the
-- day from a timestamp would file their result under tomorrow. The server stamps the day it
-- issued the seed for, and that is the day it counts for however long the match runs.
alter table game_matches add column if not exists challenge_day date;

-- Ranking scans one day at a time, so the day leads. `status` is in the index because the
-- board counts finished matches only and an unfinished one is not a score yet.
create index if not exists game_matches_challenge_day_idx
  on game_matches (challenge_day, status)
  where challenge_day is not null;

-- ONE ATTEMPT PER PERSON PER DAY, enforced by the database rather than by the route.
--
-- The whole point of a shared seed is that everyone plays the same arena, and the whole point
-- of a leaderboard is that the scores are comparable. Unlimited retries destroy both: the board
-- becomes a ranking of who replayed most, and a player who is behind can simply grind until the
-- RNG cooperates. Route-level checks lose that race under two taps in flight; a unique index
-- does not.
--
-- On `created_by` rather than on every seat: a daily match is solo (one human, server bots), so
-- the creator is the player.
create unique index if not exists game_matches_challenge_one_per_day_idx
  on game_matches (created_by, challenge_day)
  where challenge_day is not null;
