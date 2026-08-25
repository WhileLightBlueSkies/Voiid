-- 051_games_featured.sql — editorial control over the Games carousel.
--
-- ── WHY THIS EXISTS ─────────────────────────────────────────────────────────────
-- The Games home has a featured carousel, ported from the design reference. The
-- reference is a mockup: its "featured" games are a hardcoded array with FEATURED /
-- NEW / EVENT badges attached by hand.
--
-- The `games` table has no notion of promotion, so the client currently shows the
-- FIRST THREE CATALOG ROWS in server order and says so in a comment. That is honest,
-- but it means the most prominent surface on the tab is ordered by whatever `select`
-- happens to return — nobody chose it, and promoting a new game means re-ordering the
-- catalog itself.
--
-- One nullable column fixes that.
--
-- ── WHY A TIMESTAMP AND NOT A BOOLEAN ───────────────────────────────────────────
-- `featured boolean` answers "is it featured" and nothing else. A timestamp answers
-- "since when", which is what the carousel actually needs: most-recently-promoted
-- first is a sensible default order, and it makes "what did we feature last month" a
-- query rather than a guess. Un-featuring is `set featured_at = null`, so the column
-- is also its own audit trail while the row is live.
--
-- NULL means not featured. That is the default, so this migration promotes nothing —
-- the carousel keeps its current fallback until someone deliberately sets a value.
--
-- ── WHAT THIS DELIBERATELY DOES NOT ADD ─────────────────────────────────────────
-- No badge column (FEATURED / NEW / EVENT). The client renders the game's CATEGORY
-- there instead, which is real. A badge vocabulary is a marketing decision that would
-- need its own enum and a migration every time the vocabulary grows; the reference's
-- three values are not a schema.
--
-- No `featured_copy` / blurb. `games` has no description column at all, and inventing
-- one for the carousel alone would leave every other surface without it.

alter table games
    -- When this game was promoted to the featured carousel. NULL = not featured.
    add column if not exists featured_at timestamptz;

-- The carousel's only query: promoted games, most recent first. Partial, because the
-- overwhelming majority of rows are NULL and never belong in this index.
create index if not exists games_featured_idx
    on games (featured_at desc)
    where featured_at is not null;
