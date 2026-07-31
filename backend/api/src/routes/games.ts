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
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const { slug, opponent_ids, options } = req.body ?? {};

    if (typeof slug !== 'string' || !Array.isArray(opponent_ids)) {
      return res.status(400).json({ error: 'slug and opponent_ids required' });
    }
    // Per-game settings chosen at creation (hand cricket's over count). Stored opaquely and
    // validated by the ENGINE, not here: this router deliberately knows no game's rules, and
    // a whitelist of every game's settings would be rules knowledge in a second place.
    // A non-object is dropped rather than 400'd — it is optional, and an old client that
    // omits it must keep working.
    const matchOptions =
      options !== null && typeof options === 'object' && !Array.isArray(options) ? options : {};
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
      `insert into game_matches (game_id, player_ids, created_by, status, options)
       values ($1, $2::jsonb, $3, 'waiting', $4::jsonb)
       returning id`,
      [game.id, JSON.stringify(players), userId, JSON.stringify(matchOptions)]
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
    const { user_id: userId } = (req as any).auth as { user_id: string };
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

/**
 * GET /games/invites — matches the caller has been invited to but hasn't joined.
 *
 * Drives the banners on the games home screen. Two buckets, split by age rather than by a
 * separate state column: an invite younger than INVITE_TTL_MS is LIVE, older is MISSED. Deriving
 * it from `created_at` means no background job has to age rows out, and a client whose clock is
 * off still gets the server's opinion.
 *
 * EXCLUDES matches the caller created. A creator sitting in the lobby is not "invited" — they
 * already know, and showing them their own invite as an incoming banner would be nonsense.
 *
 * `status = 'waiting'` is the whole filter for "not joined": the games service flips a match to
 * 'active' the moment anyone joins (markStarted), so a waiting row is by definition one nobody
 * has entered.
 */
const INVITE_TTL_MS = 10 * 60 * 1000;

router.get(
  '/invites',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const rows = await query<{
      id: string;
      slug: string;
      name: string;
      icon_key: string | null;
      options: Record<string, unknown> | null;
      created_by: string;
      created_at: Date;
      inviter_name: string | null;
      inviter_username: string | null;
    }>(
      `select m.id, g.slug, g.name, g.icon_key, m.options, m.created_by, m.created_at,
              u.full_name as inviter_name, u.username as inviter_username
         from game_matches m
         join games g on g.id = m.game_id
         left join users u on u.id = m.created_by
        where m.status = 'waiting'
          -- ::uuid, not a bare parameter. created_by is a uuid column and pg infers an untyped
          -- parameter as text, and there is no uuid <> text operator — so this comparison made the
          -- whole query fail and the endpoint 500 on every call, which is what left the invite
          -- banners permanently empty. Same class of bug as the leaderboard's $3/$4 split.
          and m.created_by <> $1::uuid
          and m.player_ids @> $2::jsonb
        order by m.created_at desc
        limit 20`,
      [userId, JSON.stringify([userId])]
    );

    const now = Date.now();
    const invites = rows.map((r) => {
      const sentAt = new Date(r.created_at).getTime();
      const age = now - sentAt;
      // `overs` is lifted out of the options bag into a typed field: every client renders it on
      // the banner, and making each one dig through an untyped map for the one setting they all
      // care about is how three platforms end up parsing it three subtly different ways.
      const overs = Number((r.options as { overs?: unknown } | null)?.overs);
      return {
        match_id: r.id,
        slug: r.slug,
        name: r.name,
        icon_key: r.icon_key,
        overs: Number.isFinite(overs) && overs > 0 ? overs : 0,
        options: r.options ?? {},
        inviter_id: r.created_by,
        inviter_name: r.inviter_name ?? r.inviter_username ?? null,
        sent_at: sentAt,
        expires_at: sentAt + INVITE_TTL_MS,
        missed: age > INVITE_TTL_MS,
      };
    });
    res.json({ invites });
  })
);

/**
 * POST /games/matches/:id/decline — turn down an invite, or abandon a lobby nobody joined.
 *
 * One route for both because they are the same state change: a 'waiting' match that will never
 * start. Marking it 'abandoned' rather than deleting keeps the row for history and, critically,
 * keeps it out of the leaderboard — which counts only `status = 'finished'`.
 */
router.post(
  '/matches/:id/decline',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const matchId = req.params.id;
    if (!UUID_RE.test(matchId)) return res.status(400).json({ error: 'bad match id' });

    const rows = await query<{ player_ids: string[]; status: string }>(
      `select player_ids, status from game_matches where id = $1`,
      [matchId]
    );
    const match = rows[0];
    if (!match) return res.status(404).json({ error: 'no such match' });
    if (!match.player_ids.includes(userId)) {
      return res.status(403).json({ error: 'not a player in this match' });
    }
    // Only a match that never started can be declined. An in-progress game is left alone rather
    // than 400'd, so a duplicate tap from a racing client is harmless.
    if (match.status === 'waiting') {
      await query(
        `update game_matches set status = 'abandoned', ended_at = now() where id = $1`,
        [matchId]
      );
    }
    res.json({ ok: true });
  })
);

/** GET /games/matches — the caller's recent matches, newest first. */
router.get(
  '/matches',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
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
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const slug = typeof req.query.game === 'string' ? req.query.game : null;

    // One pass over the caller's finished matches. `opponent` is derived by expanding
    // player_ids and dropping the caller, so this works unchanged for >2-player games
    // later (each opponent gets a row).
    //
    // WRAPPED IN A TRY, and the catch LOGS. This query silently failed for its entire life — a
    // uuid/text comparison error that surfaced to users as "Couldn't load the leaderboard" with
    // nothing in any log to say why. A bad query here is a bug, not a user's problem, so it gets
    // recorded server-side rather than swallowed into a generic 500.
    let rows;
    try {
      rows = await runLeaderboard(userId, slug);
    } catch (e) {
      const err = e as Error & { code?: string; detail?: string; hint?: string; position?: string };
      // LOGGED, NOT RETURNED. A database message names columns and constraints, so it belongs in
      // the server's log and never in a response — an earlier version returned it to debug this
      // endpoint, which was expedient and is not shippable. The client gets a plain 500 from the
      // global handler; the operator gets the code and position.
      console.error(
        '[games] leaderboard query failed:',
        err.code, err.message, err.detail, err.hint, err.position,
      );
      throw e;
    }
    res.json({ leaderboard: rows });
  })
);

/** The leaderboard query itself, split out so the route above can log a failure with context. */
async function runLeaderboard(userId: string, slug: string | null) {
  return query(
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
              count(*)::int                                                    as played,
              -- TWO PARAMETERS FOR ONE VALUE, deliberately. The caller's id is needed as TEXT
              -- above (opponent_id comes out of jsonb as text) and as UUID here (winner_id is a
              -- uuid column, and Postgres has no uuid = text operator). Reusing one parameter and
              -- casting it both ways is what kept this query failing: Postgres infers ONE type
              -- per parameter, so casting it to text in one place and uuid in another is a
              -- contradiction, not a conversion. Hence $3 (text) and $4 (uuid), same value.
              count(*) filter (where p.winner_id = $4::uuid)::int              as wins,
              count(*) filter (where p.winner_id is null)::int                 as draws,
              count(*) filter (where p.winner_id = p.opponent_id::uuid)::int   as losses
         from pairs p
         left join users u on u.id = p.opponent_id::uuid
        group by p.opponent_id, u.full_name, u.username
        order by wins desc, played desc`,
      [JSON.stringify([userId]), slug, userId, userId]
  );
}

export default router;
