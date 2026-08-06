// Bracket advancement — what happens to a TOURNAMENT when one of its matches finalizes.
//
// ── WHY THIS LIVES IN THE REFEREE AND NOT IN THE API ─────────────────────────────
//
// A match only ever ends here. `finishMatch()` is the single durable write in a match's life
// (matches.ts), so "the round is now complete" is a fact this process learns first and the
// API would have to poll for. Putting advancement anywhere else would mean either a poller or
// a callback into the API, and both are machinery in place of a function call.
//
// The API keeps exactly one piece of bracket knowledge — SEEDING (routes/tournaments.ts) —
// because seeding must commit in the same transaction that flips the tournament to 'active',
// and that transaction belongs to the request that started it. The two halves do not overlap:
// seeding maps SEED -> SLOT once, advancement maps SLOT -> PARENT SLOT forever. Neither can
// drift into the other because neither can express the other's question.
//
// ── THE ONE INVARIANT EVERYTHING HERE RESTS ON ───────────────────────────────────
//
// 031_tournaments.sql puts a unique index on (tournament_id, round, slot, attempt). Two
// matches in the same round can finish in the same millisecond in two different processes;
// both will then observe a complete round and both will try to create the next one. The
// index decides it and `on conflict do nothing` makes the loser a no-op. NOTHING in this file
// serialises with a SELECT, because a SELECT cannot serialise that.
import { query, pool } from './db';

/** A bracket coordinate plus the outcome that was recorded against it. */
interface BracketMatch {
  id: string;
  round: number;
  slot: number;
  attempt: number;
  status: string;
  winner_id: string | null;
  player_ids: string[];
}

interface TournamentRow {
  id: string;
  game_id: string;
  created_by: string;
  format: string;
  status: string;
}

/**
 * Advance the bracket that `matchId` belongs to, if it belongs to one.
 *
 * Safe to call for every match that ends: an ordinary friendly match has a null tournament_id
 * and costs one indexed lookup.
 */
export async function advanceTournamentForMatch(matchId: string): Promise<void> {
  const row = (
    await query<{ tournament_id: string | null }>(
      `select tournament_id from game_matches where id = $1`,
      [matchId]
    )
  )[0];
  if (!row?.tournament_id) return;
  await advanceTournament(row.tournament_id);
}

/**
 * Re-derive the state of one tournament from its match rows and take the single next step.
 *
 * Deliberately DERIVED, never incremental. There is no "current round" column to fall out of
 * sync, and calling this twice, or ten times, or after a crash halfway through, converges on
 * the same bracket — which is what makes it safe to fire from a finish path, from a forfeit,
 * and from an operator retry without any of them coordinating.
 */
export async function advanceTournament(tournamentId: string): Promise<void> {
  const t = (
    await query<TournamentRow>(
      `select id, game_id, created_by, format, status from tournaments where id = $1`,
      [tournamentId]
    )
  )[0];
  // 'open' cannot have matches; 'finished'/'cancelled' are terminal. Only a live bracket moves.
  if (!t || t.status !== 'active') return;

  const matches = await query<BracketMatch>(
    `select id,
            tournament_round   as round,
            tournament_slot    as slot,
            tournament_attempt as attempt,
            status,
            winner_id,
            player_ids
       from game_matches
      where tournament_id = $1
      order by tournament_round, tournament_slot, tournament_attempt`,
    [tournamentId]
  );
  if (matches.length === 0) return;

  // The DECIDING match for a slot is its highest attempt — a drawn knockout match is replayed
  // in the same slot, so a slot can legitimately hold several rows and only the last one counts.
  // The query above is ordered by attempt, so the last write per key wins.
  const deciding = new Map<string, BracketMatch>();
  for (const m of matches) deciding.set(`${m.round}:${m.slot}`, m);

  if (t.format === 'round_robin') {
    await advanceRoundRobin(t, [...deciding.values()]);
    return;
  }
  await advanceSingleElim(t, [...deciding.values()]);
}

// ─────────────────────────────────────────────────────────────────────────────────
// SINGLE ELIMINATION
// ─────────────────────────────────────────────────────────────────────────────────

async function advanceSingleElim(t: TournamentRow, deciding: BracketMatch[]): Promise<void> {
  const maxRound = Math.max(...deciding.map((m) => m.round));
  const current = deciding.filter((m) => m.round === maxRound).sort((a, b) => a.slot - b.slot);

  // Still being played. Nothing to decide and, importantly, nothing to create — a partially
  // finished round must never produce a next round with holes in it.
  if (current.some((m) => m.status === 'waiting' || m.status === 'active')) return;

  // A slot that ended without a winner does not advance anybody, and the bracket would simply
  // stop. Two causes, one remedy:
  //   * a DRAW — Tic Tac Toe draws constantly, and 024_games.sql already treats "finished" and
  //     "has a winner" as separate facts;
  //   * an ABANDONED row — POST /games/matches/:id/decline can still mark a waiting match
  //     abandoned, so a player who declines their fixture must not be able to freeze the whole
  //     tournament for everyone else.
  // Both become a replay in the SAME slot at attempt+1, which is exactly what the slot/attempt
  // pair in 031 exists for.
  const replays = current.filter((m) => !m.winner_id);
  if (replays.length > 0) {
    await createMatches(
      t,
      replays.map((m) => ({
        players: m.player_ids,
        round: m.round,
        slot: m.slot,
        attempt: m.attempt + 1,
      }))
    );
    return;
  }

  // Every slot has a winner. Record who went out in this round before creating the next one:
  // a bye has a single entry in player_ids and therefore no loser, which is why this is a
  // subtraction rather than "the other player".
  const eliminated: string[] = [];
  for (const m of current) {
    for (const uid of m.player_ids) if (uid !== m.winner_id) eliminated.push(uid);
  }
  if (eliminated.length > 0) {
    await query(
      `update tournament_players
          set eliminated_in_round = $2
        where tournament_id = $1
          and user_id = any($3::uuid[])
          and eliminated_in_round is null`,
      [t.id, maxRound, eliminated]
    );
  }

  // One slot left and it is decided: that is the title.
  if (current.length === 1) {
    await finishTournament(t.id, current[0].winner_id);
    return;
  }

  // Pair the winners. The arithmetic is the whole reason `tournament_slot` exists: the winner
  // of round r slot k meets the winner of round r slot k^1 in round r+1 slot k>>1, and that
  // holds for every round of every bracket without a lookup table. Ordering by created_at
  // instead — which the plan's (tournament_id, round) sketch would have forced — changes under
  // a retry, because four rows inserted by one statement share a timestamp.
  const next: NewMatch[] = [];
  for (let k = 0; k + 1 < current.length; k += 2) {
    const a = current[k].winner_id!;
    const b = current[k + 1].winner_id!;
    next.push({ players: [a, b], round: maxRound + 1, slot: k / 2, attempt: 1 });
  }
  await createMatches(t, next);
}

// ─────────────────────────────────────────────────────────────────────────────────
// ROUND ROBIN
//
// Every fixture is created up front by the seeding transaction, so there is no next round to
// build — this half only has to notice that the last fixture has been played and crown someone.
// ─────────────────────────────────────────────────────────────────────────────────

async function advanceRoundRobin(t: TournamentRow, deciding: BracketMatch[]): Promise<void> {
  // A DRAW IS A RESULT HERE, not a stall — it is worth a point in the standings view and the
  // table still resolves. Only a match that never reached a conclusion needs replaying, and an
  // abandoned fixture is the one way that happens.
  const replays = deciding.filter((m) => m.status === 'abandoned');
  if (replays.length > 0) {
    await createMatches(
      t,
      replays.map((m) => ({
        players: m.player_ids,
        round: m.round,
        slot: m.slot,
        attempt: m.attempt + 1,
      }))
    );
    return;
  }
  if (deciding.some((m) => m.status !== 'finished')) return;

  // The table decides. Ordering matches the view's own vocabulary: points first (3/1/0), then
  // aggregate score, then outright wins.
  const table = await query<{ user_id: string; points: number; score: string; wins: number }>(
    `select user_id, points, score, wins
       from tournament_standings
      where tournament_id = $1
      order by points desc, score desc, wins desc`,
    [t.id]
  );

  // A LEVEL TABLE HAS NO WINNER, and saying so is the honest answer. 031 makes
  // winner_user_id nullable forever precisely so a tied round robin does not have to invent
  // one — inventing a champion out of row order would be arbitrary and irreversible.
  let winner: string | null = null;
  if (table.length === 1) {
    winner = table[0].user_id;
  } else if (table.length > 1) {
    const [first, second] = table;
    const level =
      first.points === second.points &&
      String(first.score) === String(second.score) &&
      first.wins === second.wins;
    winner = level ? null : first.user_id;
  }

  await finishTournament(t.id, winner);
}

// ─────────────────────────────────────────────────────────────────────────────────
// Shared writes
// ─────────────────────────────────────────────────────────────────────────────────

interface NewMatch {
  players: string[];
  round: number;
  slot: number;
  attempt: number;
}

/**
 * Insert a whole round in ONE statement.
 *
 * One statement rather than a loop because a round must appear whole or not at all: a process
 * that died between slot 1 and slot 2 would leave a round nothing will ever complete, and
 * nothing here re-runs. A multi-row INSERT is atomic on its own, so this needs no explicit
 * transaction — which also keeps it callable from the finish path without holding a connection.
 *
 * Every row created here has two players and is 'waiting'. BYES ARE NOT CREATED IN THIS
 * SERVICE and cannot be: a bye only ever arises when a field is rounded up to a power of two,
 * which happens once, during seeding, in the API. Round r+1 pairs two winners and a replay
 * re-pairs the same two players, so a one-player row can never be produced from here.
 */
async function createMatches(
  t: Pick<TournamentRow, 'id' | 'game_id' | 'created_by'>,
  rows: NewMatch[]
): Promise<void> {
  if (rows.length === 0) return;

  const values: string[] = [];
  const params: unknown[] = [t.game_id, t.created_by, t.id];
  for (const r of rows) {
    const p = params.length;
    values.push(`($1, $${p + 1}::jsonb, $2, 'waiting', $3, $${p + 2}, $${p + 3}, $${p + 4})`);
    params.push(JSON.stringify(r.players), r.round, r.slot, r.attempt);
  }

  await query(
    `insert into game_matches
       (game_id, player_ids, created_by, status,
        tournament_id, tournament_round, tournament_slot, tournament_attempt)
     values ${values.join(', ')}
     -- Named against the PARTIAL unique index in 031, predicate included: Postgres will not
     -- infer a partial index without it, and without inference this becomes a plain insert —
     -- the same "the conflict target never matched" failure shape as a NULL in a unique key.
     on conflict (tournament_id, tournament_round, tournament_slot, tournament_attempt)
       where tournament_id is not null
       do nothing`,
    params
  );
}

/**
 * Close a tournament out. Conditional on 'active' so a double advance — two processes finishing
 * the last two fixtures at once — cannot rewrite a winner that is already recorded.
 */
async function finishTournament(tournamentId: string, winnerUserId: string | null): Promise<void> {
  await query(
    `update tournaments
        set status = 'finished', finished_at = now(), winner_user_id = $2
      where id = $1 and status = 'active'`,
    [tournamentId, winnerUserId]
  );
}

/**
 * Turn a withdrawn player's outstanding fixtures into WALKOVERS.
 *
 * Called by the API's withdraw path (via the `tournament_forfeit` frame) rather than
 * implemented there, so the rule that a walkover scores nothing lives in one place.
 *
 * A walkover writes NO game_match_results rows, which is the same treatment 031 gives a bye,
 * for the same reason: standings and the global leaderboard both read results, so a match
 * nobody played must not appear in either. The opponent advances; they do not get a "win" on
 * their record for someone else quitting.
 */
export async function forfeitFixtures(tournamentId: string, userId: string): Promise<number> {
  const client = await pool.connect();
  try {
    await client.query('begin');
    const open = (
      await client.query<{ id: string; player_ids: string[] }>(
        `select id, player_ids
           from game_matches
          where tournament_id = $1
            and status in ('waiting', 'active')
            and player_ids @> $2::jsonb
          for update`,
        [tournamentId, JSON.stringify([userId])]
      )
    ).rows;

    for (const m of open) {
      const opponent = m.player_ids.find((p) => p !== userId) ?? null;
      await client.query(
        `update game_matches
            set status = 'finished', ended_at = now(), winner_id = $2
          where id = $1 and status in ('waiting', 'active')`,
        [m.id, opponent]
      );
    }
    await client.query('commit');
    return open.length;
  } catch (e) {
    await client.query('rollback');
    throw e;
  } finally {
    client.release();
  }
}
