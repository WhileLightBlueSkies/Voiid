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

// ─────────────────────────────────────────────────────────────────────────────────
// REACHABILITY GATE — the same hole that was closed on the call path (POST /calls/ring),
// closed here for the same reason.
//
// Minting a match row is not a neutral act: GET /games/invites is keyed only on
// `player_ids @> [me]`, so naming someone in a match puts a banner carrying the creator's
// profile name on their games screen. Without this check anyone who learns or enumerates a
// user id could do that to a stranger, bypassing the mutual-contact and username+PIN gates
// every ordinary message has to pass. The E2EE invite message would fail for lack of a
// session, but the banner is driven by the row alone and would appear regardless.
//
// 'accepted' on BOTH sides, not just membership. reachability.ts opens a direct conversation
// for the sender the moment they send a request — the recipient sits at 'pending' until they
// agree. Accepting only membership would therefore let an unanswered request act as a permit,
// which is exactly the state a spammer can create for themselves at will.
//
// Returns the subset that IS reachable rather than a boolean, so the caller can gate the
// whole array in one round trip.
// ─────────────────────────────────────────────────────────────────────────────────
async function reachableOpponents(userId: string, opponentIds: string[]): Promise<Set<string>> {
  if (opponentIds.length === 0) return new Set();
  const rows = await query<{ user_id: string }>(
    `select distinct m2.user_id
       from conversations c
       join conversation_members m1
            on m1.conversation_id = c.id and m1.user_id = $1
           and m1.left_at is null and m1.request_state = 'accepted'
       join conversation_members m2
            on m2.conversation_id = c.id and m2.user_id = any($2::uuid[])
           and m2.left_at is null and m2.request_state = 'accepted'
      where c.type = 'direct'`,
    [userId, opponentIds]
  );
  return new Set(rows.map((r) => r.user_id));
}

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
    const { slug, opponent_ids, options, skin } = req.body ?? {};

    if (typeof slug !== 'string' || !Array.isArray(opponent_ids)) {
      return res.status(400).json({ error: 'slug and opponent_ids required' });
    }
    // Per-game settings chosen at creation (hand cricket's over count). Stored opaquely and
    // validated by the ENGINE, not here: this router deliberately knows no game's rules, and
    // a whitelist of every game's settings would be rules knowledge in a second place.
    // A non-object is dropped rather than 400'd — it is optional, and an old client that
    // omits it must keep working.
    const matchOptions: Record<string, unknown> =
      options !== null && typeof options === 'object' && !Array.isArray(options)
        ? { ...options }
        : {};
    // Snake's skin rides alongside the numeric options rather than inside them, because the
    // clients type `options` as a string->int map. Stored opaquely and validated by the
    // ENGINE, exactly like every other per-game setting — this router still knows no rules.
    if (typeof skin === 'string' && skin.length <= 32) matchOptions.skin = skin;
    const opponents = opponent_ids.filter(
      (id: unknown): id is string => typeof id === 'string' && UUID_RE.test(id) && id !== userId
    );

    // NO blanket "at least one opponent" check here.
    //
    // That guard was correct while every game was strictly 1:1, but it rejected a solo match
    // BEFORE the min_players check below could allow one — so Snake's practice mode (one
    // human, server-side bots) 400'd on every attempt even though its catalog row sets
    // min_players = 1. The catalog is the authority on how many seats a game needs; encoding
    // that a second time here just meant two sources of truth disagreeing.
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

    // AUTHORIZATION — see reachableOpponents() above. Runs BEFORE the insert so an
    // unauthorized attempt leaves no row, and therefore no invite banner and no history
    // entry, on anyone's screen. Solo matches skip it for free: opponents is empty.
    if (opponents.length > 0) {
      const reachable = await reachableOpponents(userId, opponents);
      if (opponents.some((id) => !reachable.has(id))) {
        // 403 for the whole request, and deliberately WITHOUT naming which opponent failed.
        // Saying which one would turn this endpoint into an oracle for "is this user id real,
        // and are they in my contacts" — the same reasoning as the call path's opaque 403.
        return res.status(403).json({ error: 'not permitted to invite one of these players' });
      }
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
 * POST /games/matches/:id/leave — a player is deliberately backing out of the game screen.
 *
 * WHY THIS EXISTS: `game_join` starts a match. Nothing ever told the server the reverse — a
 * player closing Snake's arena screen only cleared CLIENT-side state (GamesEngine.leave() on
 * both platforms), so a continuous game's tick loop kept running and broadcasting `game_state`
 * at its full rate to a socket showing a completely different screen. Every solo Snake
 * practice run left one of these ticking for up to its full 60-600s duration — and because
 * the tick loop refreshes its own Redis TTL on every persist, an abandoned match was never
 * actually "stale" from the server's point of view until its own clock ran out. See
 * docs/GAMES_SNAKE_BUGS.md for the incident this closes.
 *
 * SCOPED TO SOLO MATCHES ONLY (backend/games' handleLeave rejects anything else). Ending a
 * multiplayer match the instant one player backs out would penalize whoever is still playing;
 * that is a real feature (forfeit/abandonment handling, GAMES.md §7) this endpoint
 * deliberately does not attempt — it only stops the specific flood a solo player leaving
 * causes, since a solo match has no second player to protect.
 */
router.post(
  '/matches/:id/leave',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const matchId = req.params.id;
    if (!UUID_RE.test(matchId)) return res.status(400).json({ error: 'bad match id' });

    const rows = await query<{ player_ids: string[] }>(
      `select player_ids from game_matches where id = $1`,
      [matchId]
    );
    const match = rows[0];
    // A leave for a match that is already gone (finished, or never existed) is not an error —
    // the client's goal (this match should stop mattering to me) is already true.
    if (!match) return res.json({ ok: true, match_id: matchId });

    if (!match.player_ids.includes(userId)) {
      return res.status(403).json({ error: 'not a player in this match' });
    }

    await publisher.publish(
      GAMES_INPUT_CHANNEL,
      JSON.stringify({ type: 'game_leave', match_id: matchId, from_user_id: userId })
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

/**
 * POST /games/matches/:id/rematch — play the same people again, at the same settings.
 *
 * THE HIGHEST-VALUE MISSING BUTTON IN THE PRODUCT (docs/games/CROSS_CUTTING.md §1). Two people
 * who just finished a match are the two most likely to play another in the next thirty seconds,
 * and until now that took six taps through three screens plus a fresh invite the opponent had to
 * accept — by which point they have put the phone down.
 *
 * A CLONE, NOT A RESET. The finished row is left exactly as it is: it holds the result, the
 * leaderboard counts it, and history shows it. This mints a NEW match with the same game, the
 * same players and the same options. Mutating the old row would silently rewrite a result
 * somebody already saw.
 *
 * SEAT ORDER IS PRESERVED, deliberately, including who sits first. For Tic Tac Toe that means
 * the same player is X again — which is a known unfairness (TICTACTOE.md §2.3 wants alternation)
 * but it is the EXISTING unfairness, and changing who goes first as a side effect of adding a
 * button would be a rules change smuggled in under a convenience feature. Alternation is its own
 * task.
 */
router.post(
  '/matches/:id/rematch',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const matchId = req.params.id;
    if (!UUID_RE.test(matchId)) return res.status(400).json({ error: 'bad match id' });

    const rows = await query<{
      game_id: string;
      player_ids: string[];
      status: string;
      options: Record<string, unknown> | null;
      min_players: number;
      max_players: number;
      enabled: boolean;
    }>(
      `select m.game_id, m.player_ids, m.status, m.options,
              g.min_players, g.max_players, g.enabled
         from game_matches m
         join games g on g.id = m.game_id
        where m.id = $1`,
      [matchId]
    );
    const prev = rows[0];
    if (!prev) return res.status(404).json({ error: 'no such match' });
    if (!prev.player_ids.includes(userId)) {
      return res.status(403).json({ error: 'not a player in this match' });
    }
    // A game pulled from the catalog since the last match must not be re-enterable through a
    // rematch button — that is the whole point of the `enabled` flag.
    if (!prev.enabled) return res.status(404).json({ error: 'unknown game' });

    // Only a match that is genuinely OVER can be replayed. Rematching a live game would leave
    // two matches open between the same people and the clients would have no way to say which
    // one a later invite refers to.
    if (prev.status !== 'finished') {
      return res.status(409).json({ error: 'match is not finished' });
    }

    // RE-AUTHORIZED, not grandfathered. Permission to invite someone is checked at creation
    // (see reachableOpponents), and a rematch is a creation. If the other player has since
    // blocked the caller or the conversation is gone, this must fail exactly as a fresh invite
    // would — otherwise a stale match id becomes a permanent bypass of that check.
    const opponents = prev.player_ids.filter((id) => id !== userId);
    if (opponents.length > 0) {
      const reachable = await reachableOpponents(userId, opponents);
      if (opponents.some((id) => !reachable.has(id))) {
        return res.status(403).json({ error: 'not permitted to invite one of these players' });
      }
    }

    // THE REQUESTER SITS WHERE THEY SAT. Re-using player_ids verbatim keeps seat order stable
    // rather than putting whoever tapped Rematch first, which would hand them X every time.
    const insert = await query<{ id: string }>(
      `insert into game_matches (game_id, player_ids, created_by, status, options)
       values ($1, $2::jsonb, $3, 'waiting', $4::jsonb)
       returning id`,
      [prev.game_id, JSON.stringify(prev.player_ids), userId,
       JSON.stringify(prev.options ?? {})]
    );

    res.status(201).json({ match_id: insert[0].id, players: prev.player_ids });
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

// ─────────────────────────────────────────────────────────────────────────────────
// THE DAILY CHALLENGE (docs/games/CROSS_CUTTING.md §5, SNAKE_COMPETITIVE_PARITY.md §4 P3.8).
//
// One seeded Snake arena a day, the same for everyone, board resets at midnight.
//
// THE SEED IS DERIVED HERE AND NEVER ACCEPTED FROM A CLIENT. `POST /games/matches` passes its
// `options` bag through to the engine untouched — deliberately, because this router knows no
// game's rules — and the snake engine reads `options.seed`. That is harmless for an ordinary
// match, where a reproducible arena is a testing convenience. It is fatal for a ranked one:
// a player could roll seeds locally until they found a generous food layout and then send it.
//
// So the daily has its own route. It never reads a seed off the request, and it stamps
// `challenge_day` itself.

/** The challenge day, in UTC. Chosen so the reset is the same instant worldwide. */
function challengeDay(now = new Date()): string {
  return now.toISOString().slice(0, 10);
}

/**
 * The day's seed. A pure function of the date and a fixed salt, so every server process and
 * every restart derives the same arena without storing anything, and tomorrow's is not
 * predictable-in-a-useful-way from today's — there is nothing to gain from predicting it
 * anyway, since the arena is identical for everyone by design.
 */
function challengeSeed(day: string): number {
  // FNV-1a. Not for security: this needs to be stable and identical across processes, which a
  // hash with a runtime-salted implementation (or anything in Math.random's family) is not.
  let h = 0x811c9dc5;
  const input = `voiid.snake.daily.${day}`;
  for (let i = 0; i < input.length; i++) {
    h ^= input.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  // The engine treats a non-positive seed as "roll one" and would silently make the arena
  // random, so 0 is mapped away rather than left to fall through that branch.
  return (h >>> 0) || 0x9e3779b9;
}

/**
 * POST /games/daily — start today's challenge run.
 *
 * ONE PER PERSON PER DAY, and the unique index is what enforces it, not this handler. Two taps
 * in flight both pass a `select` and both insert; only one survives a unique index. The 409
 * below is the loser of that race being reported honestly rather than being handed a second
 * arena.
 */
router.post(
  '/daily',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const day = challengeDay();

    const games = await query<{ id: string }>(
      `select id from games where slug = 'snake' and enabled = true`
    );
    const game = games[0];
    if (!game) return res.status(404).json({ error: 'unknown game' });

    // Everything about the arena is fixed by the server. Only the skin is the player's, and
    // only because it changes nothing about the match — it is what their snake looks like.
    const skin = typeof req.body?.skin === 'string' && req.body.skin.length <= 32
      ? req.body.skin
      : undefined;
    const options: Record<string, unknown> = {
      seed: challengeSeed(day),
      // Same arena means the same bots, and the same number of them. Difficulty is not the
      // player's to choose on a ranked board.
      bots: 5,
      ...(skin ? { skin } : {}),
    };

    let rows;
    try {
      rows = await query<{ id: string }>(
        `insert into game_matches
           (game_id, player_ids, created_by, status, options, challenge_day)
         values ($1, $2::jsonb, $3, 'waiting', $4::jsonb, $5::date)
         returning id`,
        [game.id, JSON.stringify([userId]), userId, JSON.stringify(options), day]
      );
    } catch (e) {
      // 23505 = unique_violation, which here means exactly one thing: they already played.
      if ((e as { code?: string }).code === '23505') {
        return res.status(409).json({ error: 'already played today', day });
      }
      throw e;
    }

    res.status(201).json({ match_id: rows[0].id, day });
  })
);

/**
 * GET /games/daily — today's board, and whether the caller has played.
 *
 * GLOBAL, unlike `GET /games/leaderboard`, and that is not an inconsistency. The ordinary board
 * is scoped to people you have actually played because a global ranking of a two-player game is
 * a list of strangers you cannot challenge. The daily is the opposite: everyone played the SAME
 * arena, so the comparison is meaningful precisely BECAUSE it is global. That is the whole
 * feature.
 *
 * Capped at the top 50. A board nobody can reach the bottom of is a wall of names.
 */
router.get(
  '/daily',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const day = challengeDay();

    const board = await query<{
      user_id: string;
      full_name: string | null;
      username: string | null;
      score: number;
    }>(
      `select r.user_id, u.full_name, u.username, r.score
         from game_matches m
         join game_match_results r on r.match_id = m.id
         left join users u on u.id = r.user_id
        where m.challenge_day = $1::date
          and m.status = 'finished'
        order by r.score desc
        limit 50`,
      [day]
    );

    // Reported separately from the board, because a player can have played and still not be in
    // the top 50 — and "you already played" is the fact the button needs, not "you are ranked".
    const mine = await query<{ score: number | null; status: string }>(
      `select r.score, m.status
         from game_matches m
         left join game_match_results r on r.match_id = m.id and r.user_id = $2
        where m.challenge_day = $1::date
          and m.created_by = $2
        limit 1`,
      [day, userId]
    );

    res.json({
      day,
      seed: challengeSeed(day),
      leaderboard: board,
      // Null when they have not started one. `score` stays null for a run in progress, which
      // is how the client tells "playing" from "played".
      mine: mine[0] ? { score: mine[0].score, status: mine[0].status } : null,
    });
  })
);

export default router;
