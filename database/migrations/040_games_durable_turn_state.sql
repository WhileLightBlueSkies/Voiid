-- Durable turn-based match state (docs/games/future/README.md §2.2).
--
-- WHY THIS EXISTS. Live match state is a Redis key with a one-hour TTL (backend/games/src/
-- redis.ts). That is the right trade for an arcade match: GAMES.md §5 already accepts that a
-- games-process restart loses in-flight Snake, and a 3-minute match is not worth a durable
-- scheduler. It is the wrong trade for a game played across a working day. An unfinished Sea
-- Battle evaporates while its opponent is at lunch, and so does an unfinished chess game.
--
-- RAISING THE TTL IS NOT THE FIX. Redis is not the place to store something that has to
-- survive a week; a longer TTL just moves the cliff. Redis stays the hot path and this table
-- is the fallback loadMatch() reads on a miss.
--
-- SCOPED TO TURN-BASED GAMES DELIBERATELY, and the runtime enforces that by writing here only
-- for factories with no tickHz. index.ts already documents why a continuous game must not
-- persist per input: Snake's serialize() captures ~260 food items plus every body polyline,
-- ten to fifteen times a second per steering player. A turn-based game moves every few seconds
-- and is nowhere near a budget — the same reasoning that leaves those games round-tripping
-- through Redis on every input today.
create table if not exists game_match_state (
  match_id uuid primary key references game_matches(id) on delete cascade,

  -- The public serialize() shape, verbatim. Handed straight back to factory.restore().
  state jsonb not null,

  -- serializeSecret(), in the SAME ROW as the state it belongs to.
  --
  -- Same row, same statement, on purpose. Sea Battle's secret is the entire fleet layout, and a
  -- restore that has the state but not the secret cannot invent one — there would no longer be
  -- any fact about where the ships are, so every subsequent shot would have to be a miss. Split
  -- across two writes, a crash between them produces exactly that. One row makes the pairing
  -- atomic and the failure unreachable rather than merely unlikely.
  secret jsonb,

  -- Mirrors LiveMatch.seq so a client can still discard a late frame after a cold restore.
  seq integer not null default 0,

  -- Who has actually joined. A match is only playable once every seat is filled, and that fact
  -- has to survive with the rest of the state or a restore restarts an in-progress match.
  joined jsonb not null default '[]'::jsonb,

  updated_at timestamptz not null default now()
);

-- Deadline sweep recovery, not a query the hot path makes.
--
-- The live deadline set is Redis (`games:deadlines`), which is what the 1s sweeper reads. This
-- index exists for the case that set is lost — a flush, a fresh Redis — so the deadlines can be
-- rebuilt from the state rows rather than every open match silently never timing out again.
-- Partial, because a null deadline is the overwhelmingly common row and does not belong in it.
create index if not exists game_match_state_deadline_idx
  on game_match_state (((state->>'deadlineAt')::bigint))
  where state->>'deadlineAt' is not null;
