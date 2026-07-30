// Games — catalog and match lifecycle (docs/GAMES.md §3).
//
// This router handles the parts of a game that are SLOW and DURABLE: what games exist,
// creating a match, joining one, listing your history. It deliberately does NOT handle
// moves. Moves go over the WebSocket relay to backend/games, because a move is a 30-byte
// frame in a conversation that might carry hundreds of them — HTTP round-trips would add
// latency to the one thing in a game that must feel instant.
//
// There is DELIBERATELY no `POST /games/matches/:id/move` route, for the same reason
// routes/location.ts has no `/location/update`: if one existed, someone would eventually
// use it, and the move path would end up split across two transports with two different
// rate limits and two different validation paths.
//
// THE E2EE EXCEPTION, STATED ONCE MORE: game state is readable by the server (it referees),
// unlike every message surface in this API. The INVITE, however, is an ordinary E2EE
// message sent by the client over the normal message pipe — this router never sees it. All
// it does is mint the match row the invite points at.
import { Router } from 'express';
import { query } from '../db';
import { publisher } from '../redis';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Mirrors backend/games' subscription. A join is published here rather than handled here
// because only the games service knows what a fresh board looks like — that is rules
// knowledge, and it lives in exactly one place.
const GAMES_INPUT_CHANNEL = 'channel:games:input';

/** GET /games — the catalog. Static, tiny, and the client caches it. */
router.get(
  '/',
  requireAuth,
  asyncHandler(async (_req, res) => {
    const rows = await query(
      `select id, slug, name, category, min_players, max_players, icon_key
         from games where enabled = true order by name`
    );
    res.json({ games: rows });
  })
);

/**
 * POST /games/matches — create a match and invite one or more opponents.
 * Body: { slug, opponent_ids: [uuid, ...] }
 *
 * Returns the match id. The CLIENT then sends the actual invite as a normal E2EE message
 * carrying that id, which is why no notification is sent from here: the message pipe
 * already does wake/push correctly, and duplicating it would mean two notifications for
 * one invite.
 */
router.post(
  '/matches',
  requireAuth,
  asyncHandler(async (req, res) => {
    const userId = (req as any).user.user_id as string;
    const { slug, opponent_ids } = req.body ?? {};

    if (typeof slug !== 'string' || !Array.isArray(opponent_ids)) {
      return res.status(400).json({ error: 'slug and opponent_ids required' });
    }
    const opponents = opponent_ids.filter(
      (id: unknown): id is string => typeof id === 'string' && UUID_RE.test(id) && id !== userId
    );
    if (opponents.length === 0) {
      return res.status(400).json({ error: 'at least one opponent required' });
    }

    const games = await query<{ id: string; min_players: number; max_players: number }>(
      `select id, min_players, max_players from games where slug = $1 and enabled = true`,
      [slug]
    );
    const game = games[0];
    if (!game) return res.status(404).json({ error: 'unknown game' });

    // Seat order is fixed at creation and never re-sorted: the rules modules use the index
    // in this array to decide who moves first (X before O), so a stable order is a rule,
    // not a detail. Creator sits first.
    const players = [userId, ...opponents];
    if (players.length < game.min_players || players.length > game.max_players) {
      return res.status(400).json({ error: 'wrong number of players for this game' });
    }

    const rows = await query<{ id: string }>(
      `insert into game_matches (game_id, player_ids, created_by, status)
       values ($1, $2::jsonb, $3, 'waiting')
       returning id`,
      [game.id, JSON.stringify(players), userId]
    );

    res.status(201).json({ match_id: rows[0].id, players });
  })
);

/**
 * POST /games/matches/:id/join — accept an invite and enter the match.
 *
 * This is the wake-then-fetch shape Stories already uses: the invite that arrived over the
 * message pipe is a lightweight pointer, and the real session begins here. Publishing
 * `game_join` hands the match to backend/games, which builds the board and broadcasts the
 * opening state to every player.
 */
router.post(
  '/matches/:id/join',
  requireAuth,
  asyncHandler(async (req, res) => {
    const userId = (req as any).user.user_id as string;
    const matchId = req.params.id;
    if (!UUID_RE.test(matchId)) return res.status(400).json({ error: 'bad match id' });

    const rows = await query<{ player_ids: string[]; status: string }>(
      `select player_ids, status from game_matches where id = $1`,
      [matchId]
    );
    const match = rows[0];
    if (!match) return res.status(404).json({ error: 'no such match' });

    // Authorization happens HERE, once, and is what makes the WS path safe to keep thin —
    // the same division of labour location sharing uses.
    if (!match.player_ids.includes(userId)) {
      return res.status(403).json({ error: 'not a player in this match' });
    }
    if (match.status === 'finished' || match.status === 'abandoned') {
      return res.status(409).json({ error: 'match is over' });
    }

    await publisher.publish(
      GAMES_INPUT_CHANNEL,
      JSON.stringify({ type: 'game_join', match_id: matchId, from_user_id: userId })
    );

    res.json({ ok: true, match_id: matchId });
  })
);

/** GET /games/matches — the caller's recent matches, newest first. */
router.get(
  '/matches',
  requireAuth,
  asyncHandler(async (req, res) => {
    const userId = (req as any).user.user_id as string;
    const rows = await query(
      `select m.id, g.slug, g.name, m.status, m.player_ids, m.winner_id,
              m.created_at, m.started_at, m.ended_at
         from game_matches m join games g on g.id = m.game_id
        where m.player_ids @> $1::jsonb
        order by m.created_at desc
        limit 50`,
      [JSON.stringify([userId])]
    );
    res.json({ matches: rows });
  })
);

/**
 * GET /games/leaderboard — wins per person, among people the caller has actually played.
 *
 * SCOPED TO OPPONENTS, NOT GLOBAL, and that is the whole design. A global leaderboard in a
 * private messaging app would rank you against strangers you have no relationship with,
 * which is both meaningless and a quiet privacy leak (it exposes that two accounts exist
 * and how active they are). This one only ever contains people who appear in a finished
 * match alongside the caller, so it can never surface anyone they haven't already played.
 *
 * Counts FINISHED matches only — an abandoned or in-progress game has no result to rank.
 * Draws are counted separately rather than folded into losses, because "we drew four
 * times" is a different fact from "I lost four times", and Tic Tac Toe draws constantly.
 */
router.get(
  '/leaderboard',
  requireAuth,
  asyncHandler(async (req, res) => {
    const userId = (req as any).user.user_id as string;
    const slug = typeof req.query.game === 'string' ? req.query.game : null;

    // One pass over the caller's finished matches. `opponent` is derived by expanding
    // player_ids and dropping the caller, so this works unchanged for >2-player games
    // later (each opponent gets a row).
    const rows = await query(
      `with mine as (
         select m.id, m.winner_id, m.player_ids
           from game_matches m
           join games g on g.id = m.game_id
          where m.status = 'finished'
            and m.player_ids @> $1::jsonb
            and ($2::text is null or g.slug = $2::text)
       ),
       pairs as (
         select mine.id,
                mine.winner_id,
                opponent.value #>> '{}' as opponent_id
           from mine, jsonb_array_elements(mine.player_ids) as opponent
          where opponent.value #>> '{}' <> $3::text
       )
       select p.opponent_id,
              u.full_name,
              u.username,
              count(*)::int                                              as played,
              count(*) filter (where p.winner_id = $3::text)::int         as wins,
              count(*) filter (where p.winner_id is null)::int            as draws,
              count(*) filter (where p.winner_id = p.opponent_id)::int    as losses
         from pairs p
         left join users u on u.id = p.opponent_id::uuid
        group by p.opponent_id, u.full_name, u.username
        order by wins desc, played desc`,
      [JSON.stringify([userId]), slug, userId]
    );

    res.json({ leaderboard: rows });
  })
);

export default router;
