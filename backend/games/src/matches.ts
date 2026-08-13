// Match lifecycle: the Redis live-state record and the two Postgres writes that bracket it.
import { query } from './db';
import { state, stateKey, STATE_TTL_SECONDS, DEADLINES_KEY } from './redis';
import { factoryFor } from './engine/registry';
import { advanceTournamentForMatch } from './tournaments';
import type { GameOutcome, GameStatePayload } from './engine/GameEngine';

/**
 * The live record. `slug` and `players` ride along with the state because the runtime must
 * know which rules module to rebuild with, and who is allowed to send input, WITHOUT
 * hitting Postgres on every move — that lookup is the one thing that would put a query
 * back in the hot path.
 */
export interface LiveMatch {
  matchId: string;
  slug: string;
  players: string[];
  /** Monotonic per match, so a client can discard a state frame that arrives late. */
  seq: number;
  state: GameStatePayload;
  /**
   * User ids that have actually joined. A match is only PLAYABLE once every seat is filled.
   *
   * Needed because the creator joins the moment they create — so "a live record exists" is not the
   * same as "both players are here". Without this the first join broadcast an opening board to the
   * creator alone, their lobby saw a state frame and handed off to the board, and the game started
   * before the opponent had accepted anything.
   */
  joined?: string[];
  /**
   * SERVER-ONLY state (see GameEngine.serializeSecret) — a simultaneous game's hidden picks.
   *
   * Stored in Redis with the public state because the runtime rebuilds the engine on every input,
   * so anything not persisted here is forgotten between one pick and the next. NEVER included in a
   * broadcast: `broadcast()` sends `state`, and this field is deliberately not part of it.
   */
  secret?: GameStatePayload;
}

/**
 * True when this game persists durably (docs/games/future/README.md §2.2).
 *
 * Keyed on tickHz being ABSENT rather than on a list of slugs, exactly as the tick loop is
 * keyed on it being present. A turn-based game moves every few seconds and is nowhere near a
 * write budget; a continuous one would put a full-world Postgres write next to a tick loop
 * that already throttles its Redis writes to every 5th tick to avoid that cost.
 */
function isDurable(slug: string): boolean {
  const f = factoryFor(slug);
  return !!f && f.tickHz === undefined;
}

/**
 * A tiny, long-lived marker saying "this match has a Postgres row worth reading".
 *
 * It exists purely so the Redis-miss path can be gated without a query. The state key it shadows
 * expires after an hour; this one deliberately outlives it, because the whole point is to still
 * be here when the state key is not.
 *
 * Losing it is safe in the direction that matters: a lost marker means one async match fails to
 * resume, and the deadline sweeper still eventually forfeits it rather than leaving it hanging.
 * A marker that wrongly persisted would cost one join against a row that is not there.
 */
const durableKey = (matchId: string) => `match:${matchId}:durable`;

/** Comfortably longer than any deadline in the app; the row, not this, is the source of truth. */
const DURABLE_MARKER_TTL_SECONDS = 30 * 24 * 60 * 60;

export async function loadMatch(matchId: string): Promise<LiveMatch | null> {
  const raw = await state.get(stateKey(matchId));
  if (raw) {
    try {
      return JSON.parse(raw) as LiveMatch;
    } catch {
      // Corrupt value is treated as absent rather than crashing the service: one bad key
      // must not take games down for everyone. Fall through to the durable copy, which is
      // the whole reason there is one.
    }
  }

  // REDIS MISS IS NOT THE SAME AS "MATCH OVER" for a turn-based game.
  //
  // Before the durable table, a miss meant the one-hour TTL had elapsed and the match was gone —
  // which for an async game is the normal case, not an edge case, because the interval between
  // two turns is routinely longer than the TTL. Postgres is the fallback and Redis is rehydrated
  // from it, so the next turn in the same match pays this cost once rather than every time.
  //
  // THE MISS PATH IS NOT FREE, WHICH IS WHY IT IS GATED. Several callers invoke loadMatch
  // speculatively for a match that may legitimately not exist — an input for an expired arcade
  // match, a tick after a match was finished elsewhere — and before this change each of those
  // cost one null Redis read. Falling through unconditionally would turn every one of them into
  // a three-table join, on paths that run at tick rate. The lookup below cannot answer "is this
  // durable?" without doing the query it is deciding whether to do, so the answer comes from the
  // one thing we can know cheaply: a durable match leaves a marker key behind it.
  if (!(await state.exists(durableKey(matchId)))) return null;

  const rows = await query<{
    slug: string;
    player_ids: string[];
    status: string;
    state: GameStatePayload;
    secret: GameStatePayload | null;
    seq: number;
    joined: string[];
  }>(
    `select g.slug, m.player_ids, m.status, s.state, s.secret, s.seq, s.joined
       from game_match_state s
       join game_matches m on m.id = s.match_id
       join games g on g.id = m.game_id
      where s.match_id = $1`,
    [matchId]
  );
  const row = rows[0];
  if (!row) return null;
  // A finished match has a result row and must not be resumable. The state row is cascade-
  // deleted on finish, so this is belt-and-braces against a partial cleanup rather than an
  // expected path.
  if (row.status === 'finished' || row.status === 'abandoned') return null;

  const m: LiveMatch = {
    matchId,
    slug: row.slug,
    players: row.player_ids,
    seq: row.seq,
    state: row.state,
    secret: row.secret ?? undefined,
    joined: row.joined ?? [],
  };
  // Rehydrate the hot path so the rest of this turn, and the next few, are served from Redis.
  await state.set(stateKey(matchId), JSON.stringify(m), 'EX', STATE_TTL_SECONDS);
  return m;
}

export async function saveMatch(m: LiveMatch): Promise<void> {
  await state.set(stateKey(m.matchId), JSON.stringify(m), 'EX', STATE_TTL_SECONDS);
  if (isDurable(m.slug)) await saveDurable(m);
}

/**
 * The Postgres copy. State and secret in ONE statement — see 040's comment on why splitting
 * them is how a Sea Battle match ends up with a board whose ships no longer exist anywhere.
 */
async function saveDurable(m: LiveMatch): Promise<void> {
  await query(
    `insert into game_match_state (match_id, state, secret, seq, joined, updated_at)
     values ($1, $2, $3, $4, $5, now())
     on conflict (match_id) do update
       set state = excluded.state,
           secret = excluded.secret,
           seq = excluded.seq,
           joined = excluded.joined,
           updated_at = now()`,
    [
      m.matchId,
      JSON.stringify(m.state),
      m.secret === undefined ? null : JSON.stringify(m.secret),
      m.seq,
      JSON.stringify(m.joined ?? []),
    ]
  );
  // Written after the row, so the marker never claims a row that does not exist yet.
  await state.set(durableKey(m.matchId), '1', 'EX', DURABLE_MARKER_TTL_SECONDS);
}

/**
 * Register (or clear) this match's pending turn deadline.
 *
 * Idempotent by construction: zadd on the same member overwrites the score, so a match that
 * re-announces the same deadline on every input converges rather than accumulating entries.
 */
export async function setDeadline(matchId: string, at: number | null): Promise<void> {
  if (at === null) {
    await state.zrem(DEADLINES_KEY, matchId);
    return;
  }
  await state.zadd(DEADLINES_KEY, at, matchId);
}

/** Match ids whose deadline has passed, popped so two sweeper ticks cannot double-fire one. */
export async function popDueDeadlines(now: number, limit = 50): Promise<string[]> {
  const due = await state.zrangebyscore(DEADLINES_KEY, '-inf', now, 'LIMIT', 0, limit);
  if (due.length === 0) return [];
  // Remove BEFORE handling. A match that is still on the clock re-registers its next deadline
  // as part of handling; one that is not should not be swept twice. The engine's own moveCount
  // idempotency check (SEA_BATTLE.md §13.2) is the second line of defence behind this one.
  await state.zrem(DEADLINES_KEY, ...due);
  return due;
}

export async function clearMatch(matchId: string): Promise<void> {
  await state.del(stateKey(matchId), durableKey(matchId));
  await state.zrem(DEADLINES_KEY, matchId);
  // The durable row goes with it. A finished match's record is game_match_results; keeping the
  // in-progress state would leave a resumable copy of a match that is over.
  await query(`delete from game_match_state where match_id = $1`, [matchId]);
}

/** Marks the match active in Postgres. Called once, when the second player joins. */
export async function markStarted(matchId: string): Promise<void> {
  await query(
    `update game_matches set status = 'active', started_at = now()
      where id = $1 and status = 'waiting'`,
    [matchId]
  );
}

/**
 * The only durable write in a match's life. Records the result and per-player rows, then
 * drops the Redis key — the match is history from here.
 */
export async function finishMatch(
  matchId: string,
  players: string[],
  outcome: GameOutcome
): Promise<void> {
  await query(
    `update game_matches
        set status = 'finished', ended_at = now(), winner_id = $2
      where id = $1 and status <> 'finished'`,
    [matchId, outcome.winnerId]
  );

  for (const uid of players) {
    const score = outcome.scores[uid] ?? 0;
    // placement: 1 for the winner, 2 for the loser, null on a draw — a draw has no
    // ordering and inventing one would corrupt any future leaderboard.
    const placement =
      outcome.winnerId === null ? null : uid === outcome.winnerId ? 1 : 2;
    await query(
      `insert into game_match_results (match_id, user_id, score, placement)
       values ($1, $2, $3, $4)
       on conflict (match_id, user_id) do nothing`,
      [matchId, uid, score, placement]
    );
  }

  await clearMatch(matchId);

  // BRACKET ADVANCEMENT HANGS OFF THE ORDINARY FINISH PATH, and only off it.
  //
  // A tournament match is the same object as a friendly one — same engine, same Redis state,
  // same result rows — so "this was a tournament match" is a fact discovered here rather than
  // a second lifecycle running alongside. A friendly match pays one indexed lookup for the
  // null tournament_id and nothing else.
  //
  // WRAPPED, AND THE MATCH STILL COUNTS AS FINISHED IF THIS THROWS. The writes above are the
  // ones that must not be lost: they are the players' result. A bug in bracket arithmetic must
  // not be able to roll back a game that was actually played, and advancement is idempotent —
  // it re-derives the whole bracket from the match rows — so the next finished match in the
  // round, or an operator re-running it, repairs the gap.
  try {
    await advanceTournamentForMatch(matchId);
  } catch (e) {
    console.error('[games] tournament advance failed for', matchId, e);
  }
}
