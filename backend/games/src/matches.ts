// Match lifecycle: the Redis live-state record and the two Postgres writes that bracket it.
import { query } from './db';
import { state, stateKey, STATE_TTL_SECONDS } from './redis';
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
}

export async function loadMatch(matchId: string): Promise<LiveMatch | null> {
  const raw = await state.get(stateKey(matchId));
  if (!raw) return null;
  try {
    return JSON.parse(raw) as LiveMatch;
  } catch {
    // Corrupt value is treated as absent rather than crashing the service: one bad key
    // must not take games down for everyone.
    return null;
  }
}

export async function saveMatch(m: LiveMatch): Promise<void> {
  await state.set(stateKey(m.matchId), JSON.stringify(m), 'EX', STATE_TTL_SECONDS);
}

export async function clearMatch(matchId: string): Promise<void> {
  await state.del(stateKey(matchId));
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
}
