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
import { createHash, randomInt } from 'node:crypto';
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

/** Invite lifetime is EXACTLY 10 minutes from server created_at (LUDO_GAME_SPEC.md §8.1). */
const LUDO_INVITE_TTL_MS = 10 * 60 * 1000;

const LUDO_STARTS = [0, 13, 26, 39];
const LUDO_SAFE = new Set([0, 8, 13, 21, 26, 34, 39, 47]);
function ludoDestination(position: number, die: number, seat: number): number | null {
  if (position === 200) return null;
  if (position === -1) return die === 6 ? LUDO_STARTS[seat] : null;
  if (position >= 100 && position <= 104) {
    const next = position - 100 + die;
    return next === 5 ? 200 : next < 5 ? 100 + next : null;
  }
  const progress = (position - LUDO_STARTS[seat] + 52) % 52;
  const next = progress + die;
  if (next === 57) return 200;
  if (next > 57) return null;
  if (next >= 52) return 100 + next - 52;
  return (LUDO_STARTS[seat] + next) % 52;
}
function ludoPath(position: number, die: number, seat: number): number[] {
  if (position === -1) { const to = ludoDestination(position, die, seat); return to === null ? [] : [to]; }
  const result: number[] = [];
  for (let step = 1; step <= die; step++) {
    const to = ludoDestination(position, step, seat); if (to !== null) result.push(to);
  }
  return result;
}

/**
 * Publish an invite-card state change to every seat (§7.2). One frame per copy of the card:
 * waiting/live invite, declined/cancelled, expired and finished states are all driven by
 * this plus game_ended, so every device renders the same truth.
 */
async function publishInviteStatus(
  matchId: string,
  playerIds: string[],
  status: 'waiting' | 'declined' | 'cancelled' | 'expired' | 'active' | 'finished',
  acceptedSeats = 0,
  expiresAt?: number
): Promise<void> {
  const frame = JSON.stringify({
      type: 'game_invite_status',
      match_id: matchId,
      status,
      accepted_seats: acceptedSeats,
      total_seats: playerIds.length,
      expires_at: expiresAt ?? Date.now() + LUDO_INVITE_TTL_MS,
  });
  await Promise.all(playerIds.map((id) => publisher.publish(`channel:user:${id}`, frame)));
}

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

    // ── LUDO SCHEMA-V3 VALIDATION (§7.1, §8.1) ────────────────────────────────────────
    let ludoMode: 'duel' | 'four' | null = null;
    let sourceConversationId: string | null = null;
    let idempotencyKey: string | null = null;
    let ludoRoster: Array<{ kind: 'human'; userId: string } | { kind: 'bot'; difficulty: 'relaxed' | 'balanced' | 'sharp' }> | null = null;
    let ludoHumanIds: string[] | null = null;
    if (slug === 'ludo') {
      const rawMode = (req.body?.mode ?? matchOptions.mode) as unknown;
      if (rawMode !== 'duel' && rawMode !== 'four') {
        return res.status(400).json({ error: "ludo requires mode 'duel' or 'four'" });
      }
      ludoMode = rawMode;
      const rawRoster = req.body?.roster;
      const expectedSeats = ludoMode === 'duel' ? 2 : 4;
      if (!Array.isArray(rawRoster) || rawRoster.length !== expectedSeats) {
        return res.status(400).json({ error: `ludo ${ludoMode} requires exactly ${expectedSeats} roster entries` });
      }
      ludoRoster = [];
      for (const raw of rawRoster) {
        if (!raw || typeof raw !== 'object') return res.status(400).json({ error: 'invalid ludo roster' });
        if (raw.kind === 'human' && typeof raw.user_id === 'string' && UUID_RE.test(raw.user_id)) {
          ludoRoster.push({ kind: 'human', userId: raw.user_id });
        } else if (raw.kind === 'bot' && ['relaxed', 'balanced', 'sharp'].includes(raw.difficulty)) {
          ludoRoster.push({ kind: 'bot', difficulty: raw.difficulty });
        } else {
          return res.status(400).json({ error: 'invalid ludo roster entry' });
        }
      }
      ludoHumanIds = ludoRoster.filter((r): r is { kind: 'human'; userId: string } => r.kind === 'human').map((r) => r.userId);
      if (ludoHumanIds.filter((id) => id === userId).length !== 1) {
        return res.status(400).json({ error: 'caller must appear exactly once in ludo roster' });
      }
      if (new Set(ludoHumanIds).size !== ludoHumanIds.length) {
        return res.status(400).json({ error: 'duplicate human in ludo roster' });
      }
      const convId = req.body?.conversation_id ?? matchOptions.conversation_id;
      const hasInvitedHuman = ludoHumanIds.some((id) => id !== userId);
      if (hasInvitedHuman && (typeof convId !== 'string' || !UUID_RE.test(convId))) {
        return res.status(400).json({ error: 'ludo with invited humans requires a valid conversation_id' });
      }
      sourceConversationId = typeof convId === 'string' && UUID_RE.test(convId) ? convId : null;
      matchOptions.mode = ludoMode;
      matchOptions.roster = ludoRoster;
      if (sourceConversationId) matchOptions.conversation_id = sourceConversationId;

      const idem = req.body?.idempotency_key;
      if (idem !== undefined && (typeof idem !== 'string' || !UUID_RE.test(idem))) {
        return res.status(400).json({ error: 'invalid idempotency_key' });
      }
      idempotencyKey = typeof idem === 'string' ? idem : null;

      // EVERY participant must be a CURRENT accepted member of the source conversation.
      // The client list is convenience only; this is the check that matters.
      const members = sourceConversationId ? await query<{ user_id: string }>(
        `select user_id from conversation_members
          where conversation_id = $1::uuid and left_at is null and request_state = 'accepted'`,
        [sourceConversationId]
      ) : [];
      const memberSet = new Set(members.map((m) => m.user_id));
      const everyone = ludoHumanIds;
      for (const uid of everyone) {
        if (sourceConversationId && !memberSet.has(uid)) {
          return res.status(403).json({ error: 'all players must be current members of the conversation' });
        }
      }
      // Blocks in either direction between ANY pair kill the invite.
      const blocks = await query<{ blocker_user_id: string; blocked_user_id: string }>(
        `select blocker_user_id, blocked_user_id from user_blocks
          where blocker_user_id = any($1::uuid[]) and blocked_user_id = any($1::uuid[])`,
        [everyone]
      );
      if (blocks.length > 0) {
        return res.status(403).json({ error: 'not permitted to invite one of these players' });
      }

      // IDEMPOTENT CREATE: a retried key returns the SAME waiting match instead of minting
      // a second lobby nobody asked for.
      if (idempotencyKey) {
        const existing = await query<{ id: string; status: string; player_ids: string[] }>(
          `select id, status, player_ids from game_matches
            where created_by = $1 and idempotency_key = $2 order by created_at desc limit 1`,
          [userId, idempotencyKey]
        );
        if (existing[0]) {
          return res.status(200).json({
            match_id: existing[0].id,
            players: existing[0].player_ids,
            already_existed: true,
          });
        }
      }
    }

    // Seat order is fixed at creation and never re-sorted: the rules modules use the index
    // in this array to decide who moves first (X before O), so a stable order is a rule,
    // not a detail. Creator sits first.
    const players = ludoHumanIds ?? [userId, ...opponents];
    if (players.length < game.min_players || players.length > game.max_players) {
      return res.status(400).json({ error: 'wrong number of players for this game' });
    }

    // AUTHORIZATION — see reachableOpponents() above. Runs BEFORE the insert so an
    // unauthorized attempt leaves no row, and therefore no invite banner and no history
    // entry, on anyone's screen. Solo matches skip it for free: opponents is empty.
    const humanOpponents = players.filter((id) => id !== userId);
    if (humanOpponents.length > 0 && !ludoMode) {
      const reachable = await reachableOpponents(userId, humanOpponents);
      if (humanOpponents.some((id) => !reachable.has(id))) {
        // 403 for the whole request, and deliberately WITHOUT naming which opponent failed.
        // Saying which one would turn this endpoint into an oracle for "is this user id real,
        // and are they in my contacts" — the same reasoning as the call path's opaque 403.
        return res.status(403).json({ error: 'not permitted to invite one of these players' });
      }
    }

    const insert = await query<{ id: string }>(
      `insert into game_matches
         (game_id, player_ids, created_by, status, options,
          mode, source_conversation_id, rules_version, schema_version, idempotency_key,
          ludo_roster, controller_types, bot_difficulties, bot_policy_version)
       values ($1, $2::jsonb, $3, 'waiting', $4::jsonb,
               $5, $6::uuid, coalesce($7::text, 'legacy'), coalesce($8::int, 1), $9,
               $10::jsonb, $11::jsonb, $12::jsonb, $13)
       returning id`,
      [
        game.id,
        JSON.stringify(players),
        userId,
        JSON.stringify(matchOptions),
        ludoMode,
        sourceConversationId,
        ludoMode ? 'ludo-classic-2' : null,
        ludoMode ? 3 : null,
        idempotencyKey,
        ludoRoster ? JSON.stringify(ludoRoster) : null,
        ludoRoster ? JSON.stringify(ludoRoster.map((entry) => entry.kind)) : null,
        ludoRoster ? JSON.stringify(ludoRoster.map((entry) => entry.kind === 'bot' ? entry.difficulty : null)) : null,
        ludoRoster ? 'ludo-bot-1' : null,
      ]
    );

    if (ludoMode) {
      await publisher.publish(GAMES_INPUT_CHANNEL, JSON.stringify({
        type: 'game_join', match_id: insert[0].id, from_user_id: userId,
      }));
    }
    res.status(201).json({ match_id: insert[0].id, players, roster: ludoRoster ?? undefined });
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

    const rows = await query<{ player_ids: string[]; status: string; created_at: Date }>(
      `select player_ids, status, created_at from game_matches where id = $1`,
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
    if (match.status !== 'waiting' && match.status !== 'active') {
      return res.status(409).json({ error: match.status, status: match.status });
    }
    if (match.status === 'waiting' && Date.now() >= new Date(match.created_at).getTime() + LUDO_INVITE_TTL_MS) {
      await query(`update game_matches set status = 'expired', ended_at = now(), end_reason = 'expired' where id = $1 and status = 'waiting'`, [matchId]);
      await publishInviteStatus(matchId, match.player_ids, 'expired', 0,
        new Date(match.created_at).getTime() + LUDO_INVITE_TTL_MS);
      return res.status(409).json({ error: 'expired', status: 'expired' });
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
        `update game_matches set status = 'declined', ended_at = now(), end_reason = 'declined' where id = $1`,
        [matchId]
      );
      // FIXED SEATS MAKE DECLINE UNAMBIGUOUS (§8.1): one decline cancels the waiting lobby
      // for everyone. Every copy of the chat invite card flips to the cancelled state.
      await publishInviteStatus(matchId, match.player_ids, 'declined');
    } else return res.status(409).json({ error: match.status, status: match.status });
    res.json({ ok: true });
  })
);

/** Creator-only cancellation of a fixed-seat waiting Ludo lobby. */
router.post(
  '/matches/:id/cancel',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const matchId = req.params.id;
    if (!UUID_RE.test(matchId)) return res.status(400).json({ error: 'bad match id' });
    const rows = await query<{ player_ids: string[]; created_by: string; status: string }>(
      `select player_ids, created_by, status from game_matches where id = $1`, [matchId]
    );
    const match = rows[0];
    if (!match) return res.status(404).json({ error: 'no such match' });
    if (match.created_by !== userId) return res.status(403).json({ error: 'creator only' });
    if (match.status !== 'waiting') return res.status(409).json({ error: match.status });
    await query(`update game_matches set status = 'cancelled', ended_at = now(), end_reason = 'cancelled' where id = $1 and status = 'waiting'`, [matchId]);
    await publishInviteStatus(matchId, match.player_ids, 'cancelled');
    res.json({ ok: true, match_id: matchId });
  })
);

/**
 * POST /games/matches/:id/forfeit — deliberate exit from an ACTIVE match (§7.1, §11.5).
 *
 * Distinct from `decline` (a lobby that never started) and from backgrounding the app
 * (never a forfeit). In a duel the opponent wins; in four-player mode only this seat drops
 * and play continues. The games service owns what a drop MEANS; this route owns whether the
 * caller may ask.
 */
router.post(
  '/matches/:id/forfeit',
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
    if (match.status !== 'active') {
      // A waiting lobby uses /decline; a finished match has nothing to forfeit.
      return res.status(409).json({ error: 'match is not active' });
    }

    await publisher.publish(
      GAMES_INPUT_CHANNEL,
      JSON.stringify({ type: 'game_forfeit', match_id: matchId, from_user_id: userId })
    );
    res.json({ ok: true });
  })
);

/**
 * GET /games/matches/:id/snapshot?after_seq=N — the server snapshot is ALWAYS truth (§9).
 *
 * Served from the durable Postgres copy (backend/games persists every accepted turn-based
 * transition before broadcasting), projected per viewer exactly as the live frames are.
 * `204` when N is current, so a client that only needs confirmation pays no payload.
 */
router.get(
  '/matches/:id/snapshot',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const matchId = req.params.id;
    if (!UUID_RE.test(matchId)) return res.status(400).json({ error: 'bad match id' });

    const afterSeq = Number(req.query.after_seq ?? -1);

    const rows = await query<{
      state: Record<string, unknown>;
      secret: Record<string, unknown> | null;
      seq: number;
      player_ids: string[];
      status: string;
      source_conversation_id: string | null;
      slug: string;
    }>(
      `select s.state, s.secret, s.seq, m.player_ids, m.status,
              m.source_conversation_id, g.slug
         from game_match_state s
         join game_matches m on m.id = s.match_id
         join games g on g.id = m.game_id
        where s.match_id = $1`,
      [matchId]
    );
    const row = rows[0];
    if (!row || row.slug !== 'ludo') return res.status(404).json({ error: 'no such match' });

    if (Number.isFinite(afterSeq) && afterSeq >= row.seq) {
      return res.status(204).end();
    }
    if (!row.player_ids.includes(userId)) {
      return res.status(403).json({ error: 'not a player in this match' });
    }

    // ── Per-viewer identity projection (§11.2), same policy as the games service. ──
    const inner = row.state as { ludo?: Record<string, unknown> };
    const ludoState = inner?.ludo;
    if (!ludoState) return res.status(404).json({ error: 'no such match' });
    if (ludoState.schemaVersion !== 3) {
      return res.status(409).json({ error: 'legacyVersionAbandoned' });
    }
    const seatPlayers = (ludoState.humanUserIds as (string | null)[]) ?? [];
    const formerPlayers = (ludoState.formerControllerUserIds as (string | null)[]) ?? [];
    const assigned = (ludoState.assigned as boolean[]) ?? [];
    const controllers = (ludoState.controller as Array<'human' | 'bot'>) ?? [];

    const ids = seatPlayers.filter((p): p is string => p !== null);
    let entitled = new Set<string>();
    try {
      if (row.source_conversation_id) {
        const members = await query<{ user_id: string }>(
          `select user_id from conversation_members
            where conversation_id = $1::uuid and left_at is null and request_state = 'accepted'`,
          [row.source_conversation_id]
        );
        entitled = new Set(members.map((m) => m.user_id));
      }
    } catch {
      entitled = new Set();
    }
    const nameRows = await query<{ id: string; username: string | null; full_name: string | null }>(
      `select id, username, full_name from users where id = any($1::uuid[])`,
      [ids]
    ).catch(() => [] as { id: string; username: string | null; full_name: string | null }[]);
    const usernames = new Map(nameRows.map((r) => [r.id, r.username ? `@${r.username}` : r.full_name ?? '']));
    let blockedPairs = new Set<string>();
    try {
      const blocks = await query<{ blocker: string; blocked: string }>(
        `select blocker_user_id as blocker, blocked_user_id as blocked from user_blocks
          where blocker_user_id = any($1::uuid[]) and blocked_user_id = any($1::uuid[])`,
        [ids]
      );
      blockedPairs = new Set(blocks.flatMap((b) => [`${b.blocker}|${b.blocked}`, `${b.blocked}|${b.blocker}`]));
    } catch {
      blockedPairs = new Set();
    }

    const tokens = (ludoState.tokens as number[][]) ?? [];
    const participation = (ludoState.participation as string[]) ?? [];
    const timeoutStreak = (ludoState.timeoutStreak as number[]) ?? [];
    const captures = (ludoState.captures as number[]) ?? [];
    const botNames = (ludoState.botNames as (string | null)[]) ?? [];
    const botDifficulties = (ludoState.botDifficulty as (string | null)[]) ?? [];
    const seats = assigned.flatMap((isAssigned, seat) => {
      if (!isAssigned) return [];
      const uid = seatPlayers[seat] ?? null;
      const controller = controllers[seat] ?? 'human';
      const maySee = uid === userId || (!!uid && entitled.has(uid) && entitled.has(userId) && !blockedPairs.has(`${userId}|${uid}`));
      return [{
        seat,
        seatId: `seat-${matchId.slice(0, 8)}-${seat}`,
        color: ['red', 'green', 'yellow', 'blue'][seat],
        displayName: controller === 'bot' ? (botNames[seat] ?? `Bot ${seat + 1}`)
          : maySee && uid ? (usernames.get(uid) ?? `Player ${seat + 1}`) : `Player ${seat + 1}`,
        controller,
        botMarker: controller === 'bot' ? 'BOT' : null,
        botDifficulty: controller === 'bot' ? (botDifficulties[seat] ?? 'balanced') : null,
        participation: participation[seat] ?? 'active',
        connection: controller === 'bot' ? 'connected' : 'disconnected',
        timeoutStreak: timeoutStreak[seat] ?? 0,
        finishedPawns: (tokens[seat] ?? []).filter((position) => position === 200).length,
        captures: captures[seat] ?? 0,
      }];
    });

    const activeSeat = Number(ludoState.activeSeat ?? 0);
    const rollValue = typeof ludoState.rollValue === 'number' ? ludoState.rollValue : null;
    const legalMoves = rollValue === null ? [] : ((ludoState.legalTokenIds as number[]) ?? []).map((tokenId) => {
      const from = tokens[activeSeat]?.[tokenId] ?? -1;
      const to = ludoDestination(from, rollValue, activeSeat) ?? from;
      let capture: { seat: number; tokenId: number } | null = null;
      if (to >= 0 && to < 52 && !LUDO_SAFE.has(to)) {
        for (let seat = 0; seat < tokens.length && !capture; seat++) {
          if (seat === activeSeat) continue;
          const pawn = tokens[seat]?.findIndex((position) => position === to) ?? -1;
          if (pawn >= 0) capture = { seat, tokenId: pawn };
        }
      }
      return { tokenId, to, path: ludoPath(from, rollValue, activeSeat), capture, isSafe: LUDO_SAFE.has(to) };
    });
    const currentSeat = seatPlayers.findIndex((uid, seat) => uid === userId && controllers[seat] === 'human');
    const formerSeat = formerPlayers.indexOf(userId);
    const secretSeed = (((row.secret as any)?.ludo?.rng?.seed) as string | undefined);

    const payload: Record<string, unknown> = {
      schemaVersion: 3,
      rulesVersion: ludoState.rulesVersion ?? 'ludo-classic-2',
      mode: ludoState.mode,
      status: row.status === 'finished' ? 'finished' : (ludoState.status ?? 'active'),
      serverNow: Date.now(),
      seq: row.seq,
      viewerSeat: currentSeat >= 0 ? currentSeat : formerSeat >= 0 ? formerSeat : null,
      viewerRole: currentSeat >= 0 ? 'controller' : formerSeat >= 0 ? 'formerController' : 'none',
      seats,
      tokensPerSeat: ludoState.tokensPerSeat ?? 4,
      tokens,
      turn: ludoState.status === 'active' && ludoState.phase !== 'none' ? {
        seat: activeSeat,
        serial: ludoState.turnSerial ?? 0,
        phase: ludoState.phase,
        opensAt: ludoState.opensAt,
        deadlineAt: ludoState.deadlineAt ?? null,
        botActionAt: ludoState.botActionAt ?? null,
        sixStreak: ludoState.sixStreak ?? 0,
        rollId: ludoState.rollId ?? null,
        value: rollValue,
        legalMoves,
        automated: ludoState.automated ?? false,
      } : null,
      lastAction: ludoState.lastAction ?? null,
      winnerSeat: ludoState.winnerSeat ?? null,
      endReason: ludoState.endReason ?? null,
      seedCommitment: secretSeed && /^[0-9a-f]{64}$/.test(secretSeed)
        ? createHash('sha256').update(secretSeed).digest('hex') : null,
    };

    res.json({
      type: 'game_state',
      match_id: matchId,
      game: 'ludo',
      schema_version: 3,
      seq: row.seq,
      server_now: Date.now(),
      payload: { ludoV3: payload },
    });
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
      slug: string;
      mode: string | null;
      source_conversation_id: string | null;
      rules_version: string | null;
      schema_version: number | null;
      ludo_roster: unknown;
      controller_types: unknown;
      bot_difficulties: unknown;
      bot_policy_version: string | null;
    }>(
      `select m.game_id, m.player_ids, m.status, m.options, m.mode,
              m.source_conversation_id, m.rules_version, m.schema_version,
              m.ludo_roster, m.controller_types, m.bot_difficulties, m.bot_policy_version,
              g.slug, g.min_players, g.max_players, g.enabled
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
      `insert into game_matches
         (game_id, player_ids, created_by, status, options, mode, source_conversation_id,
          rules_version, schema_version, ludo_roster, controller_types, bot_difficulties, bot_policy_version)
       values ($1, $2::jsonb, $3, 'waiting', $4::jsonb, $5, $6, $7, $8,
               $9::jsonb, $10::jsonb, $11::jsonb, $12)
       returning id`,
      [prev.game_id, JSON.stringify(prev.player_ids), userId,
       JSON.stringify(prev.options ?? {}), prev.mode, prev.source_conversation_id,
       prev.rules_version, prev.schema_version,
       prev.ludo_roster ? JSON.stringify(prev.ludo_roster) : null,
       prev.controller_types ? JSON.stringify(prev.controller_types) : null,
       prev.bot_difficulties ? JSON.stringify(prev.bot_difficulties) : null,
       prev.bot_policy_version]
    );

    if (prev.slug === 'ludo') {
      await publisher.publish(GAMES_INPUT_CHANNEL, JSON.stringify({
        type: 'game_join', match_id: insert[0].id, from_user_id: userId,
      }));
    }

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

// ─────────────────────────────────────────────────────────────────────────────────
// THE PARTY LOBBY (database/migrations/052_game_lobbies.sql).
//
// A SECOND, ADDITIVE LOBBY SHAPE — it does not replace the invite-and-wait path above.
// `POST /games/matches` + `/join` + `/decline` is a DIRECT 1:1 (or fixed-seat) invite: seats
// are named at creation, and the match starts when the last named seat accepts. That flow is
// untouched, and it is still what a "play them again" or a chat invite uses.
//
// A PARTY lobby is opened deliberately, by a host, on a match they already created. It adds
// the three things the invite path structurally cannot express:
//   * READY-STATES — an invited player who accepted is seated, but not necessarily looking at
//     the screen. `game_matches.player_ids` cannot tell those apart; a lobby member row can.
//   * A JOIN CODE — the one way in for someone who was never named in `player_ids`. The invite
//     path has no answer for "let my friend's friend in", because it authorizes on membership
//     of a list fixed before that person existed to the match.
//   * LOBBY CHAT — server-readable and ephemeral, see the migration header. Deliberately NOT
//     the E2EE message pipe, because a join-code stranger holds no ratchet session with anyone
//     here and establishing four of them for a chat that dies in four minutes buys nothing.
//
// WHICH SCREEN THE CLIENT SHOWS: party lobby iff a lobby row exists for the match (the host
// opened one). Otherwise the existing 1:1 invite-and-wait view. One fact decides it, so the
// two can never both claim the screen.
//
// AUTHORIZATION IS DONE HERE AND ONLY HERE. Every route below derives the caller from
// `requireAuth` and never reads a user id from the body — the same rule the WS relay states
// for `from_user_id`. A non-member cannot read a lobby's chat; a non-host cannot start it.
// ─────────────────────────────────────────────────────────────────────────────────

/**
 * Join-code alphabet. 0/O and 1/I/L are EXCLUDED — a join code's whole job is to survive being
 * read aloud or retyped from a screenshot, and those are the pairs that do not survive it.
 * 4 characters over this 31-symbol alphabet is ~923k codes, and only codes belonging to an OPEN
 * lobby are live at once (the partial unique index in 052), so the space is nowhere near
 * pressured.
 */
const LOBBY_CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const LOBBY_CODE_LENGTH = 6;

/**
 * A fresh code. Uses `randomInt` rather than `Math.random`: a guessable code is a way into a
 * public lobby, and while that is a small prize it costs nothing to not hand it over. The
 * modulo-free `randomInt(n)` also avoids the bias that `% alphabet.length` would introduce.
 */
function newJoinCode(): string {
  let out = '';
  for (let i = 0; i < LOBBY_CODE_LENGTH; i++) {
    out += LOBBY_CODE_ALPHABET[randomInt(LOBBY_CODE_ALPHABET.length)];
  }
  return out;
}

/** Chat page size. The lobby renders a short tail, not a scrollback — see the migration. */
const LOBBY_MESSAGE_LIMIT = 50;

interface LobbyRow {
  match_id: string;
  host_user_id: string;
  join_code: string | null;
  is_public: boolean;
  format: string | null;
  fill_empty: boolean;
  started_at: Date | null;
  created_at: Date;
}

interface LobbyMemberRow {
  user_id: string;
  state: string;
  mic_on: boolean;
  seat: number | null;
  joined_at: Date;
  seen_at: Date;
  full_name: string | null;
  username: string | null;
}

/**
 * Everyone in the lobby, in arrival order, with the display fields the client needs.
 *
 * JOINS `users` HERE rather than making the client resolve ids. A join-code member is by
 * definition someone the viewer may never have messaged, so the client's own contact directory
 * cannot name them — it would render a party of raw uuids. Only name and username are exposed:
 * enough to identify a person in a list, and nothing more than any other roster in this API
 * already returns.
 */
async function lobbyMembers(matchId: string): Promise<LobbyMemberRow[]> {
  return query<LobbyMemberRow>(
    `select m.user_id, m.state, m.mic_on, m.seat, m.joined_at, m.seen_at,
            u.full_name, u.username
       from game_lobby_members m
       left join users u on u.id = m.user_id
      where m.match_id = $1
      order by m.joined_at`,
    [matchId]
  );
}

/** The wire shape of one member. Built in one place so every route and every WS frame agrees. */
function memberPayload(m: LobbyMemberRow) {
  return {
    user_id: m.user_id,
    // 'waiting' | 'ready'. The client renders the chip from this and nothing else.
    state: m.state,
    // STORED INTENT ONLY — there is no voice transport behind this flag. See the migration:
    // the client must not present it as live audio until one exists.
    mic_on: m.mic_on,
    seat: m.seat,
    name: m.full_name ?? m.username ?? null,
    username: m.username ?? null,
    joined_at: new Date(m.joined_at).getTime(),
  };
}

/** The wire shape of the lobby itself, minus the members. */
function lobbyPayload(lobby: LobbyRow, maxPlayers: number) {
  return {
    match_id: lobby.match_id,
    host_user_id: lobby.host_user_id,
    join_code: lobby.join_code,
    is_public: lobby.is_public,
    format: lobby.format,
    fill_empty: lobby.fill_empty,
    // The seat cap comes from the CATALOG (`games.max_players`), never from the client. It is
    // what makes "full" a fact rather than a client's opinion.
    max_players: maxPlayers,
    started_at: lobby.started_at ? new Date(lobby.started_at).getTime() : null,
    created_at: new Date(lobby.created_at).getTime(),
  };
}

/**
 * Broadcast the whole lobby to every member.
 *
 * SENDS THE FULL ROSTER, not a delta. A lobby is at most four rows, so a delta protocol would
 * save nothing and would introduce the one bug class this screen cannot tolerate: a client
 * whose member list has silently diverged from the server's, showing a ready-state that is not
 * real. Every mutation ends with one of these, so the screen is live without polling.
 *
 * Mirrors publishInviteStatus: same channel, same fire-and-forget posture. A failed publish
 * must never fail the mutation that already committed — the client re-reads on next focus.
 */
async function publishLobbyUpdate(
  lobby: LobbyRow,
  maxPlayers: number,
  members: LobbyMemberRow[],
  reason: 'opened' | 'joined' | 'ready' | 'left' | 'host_changed' | 'started' | 'cancelled',
  recipientIds?: string[]
): Promise<void> {
  const frame = JSON.stringify({
    type: 'game_lobby_update',
    match_id: lobby.match_id,
    // Why the roster changed, so the client can animate a join differently from a ready toggle
    // without diffing to guess.
    reason,
    lobby: lobbyPayload(lobby, maxPlayers),
    members: members.map(memberPayload),
  });
  // Defaults to the current members. A LEAVE passes an explicit list that still includes the
  // person who left, so their own device learns the leave succeeded from the same frame
  // everyone else gets rather than from the HTTP response alone.
  const targets = recipientIds ?? members.map((m) => m.user_id);
  await Promise.all(
    targets.map((id) => publisher.publish(`channel:user:${id}`, frame))
  ).catch(() => { /* a dropped frame is a re-read, never a failed mutation */ });
}

/**
 * Load a lobby, its match and the catalog cap in one round trip. Returns null when there is no
 * lobby — which is the ordinary case for most matches and is never an error by itself.
 */
async function loadLobby(matchId: string): Promise<
  { lobby: LobbyRow; maxPlayers: number; matchStatus: string; playerIds: string[] } | null
> {
  const rows = await query<LobbyRow & { max_players: number; status: string; player_ids: string[] }>(
    `select l.match_id, l.host_user_id, l.join_code, l.is_public, l.format,
            l.fill_empty, l.started_at, l.created_at,
            g.max_players, m.status, m.player_ids
       from game_lobbies l
       join game_matches m on m.id = l.match_id
       join games g on g.id = m.game_id
      where l.match_id = $1`,
    [matchId]
  );
  const row = rows[0];
  if (!row) return null;
  return {
    lobby: row,
    maxPlayers: row.max_players,
    matchStatus: row.status,
    playerIds: row.player_ids,
  };
}

/**
 * POST /games/matches/:id/lobby — open a party lobby on a match the caller created.
 * Body: { is_public?, format?, fill_empty? }
 *
 * CREATOR ONLY, and it reuses `game_matches.created_by` rather than minting a separate notion
 * of ownership: the person who made the match is the person who may open a lobby on it, and
 * two sources of truth for "whose match is this" would eventually disagree.
 *
 * IDEMPOTENT. The client opens the lobby as it pushes the screen, and a double-tap or a retried
 * request must not mint a second join code for a match that already has one — the second code
 * would be live in the index and would resolve to the same lobby, which is a code space leak
 * for no gain. `on conflict do nothing` plus a re-read is the whole mechanism.
 */
router.post(
  '/matches/:id/lobby',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const matchId = req.params.id;
    if (!UUID_RE.test(matchId)) return res.status(400).json({ error: 'bad match id' });

    const matches = await query<{ created_by: string; status: string; max_players: number }>(
      `select m.created_by, m.status, g.max_players
         from game_matches m join games g on g.id = m.game_id
        where m.id = $1`,
      [matchId]
    );
    const match = matches[0];
    if (!match) return res.status(404).json({ error: 'no such match' });
    if (match.created_by !== userId) return res.status(403).json({ error: 'creator only' });
    // A lobby is a thing that happens BEFORE a match. Opening one on a match that already
    // started, finished or was abandoned would render a ready-up screen for a game in progress.
    if (match.status !== 'waiting') {
      return res.status(409).json({ error: 'match is not waiting', status: match.status });
    }

    const isPublic = req.body?.is_public === true;
    // Free text, capped. The migration deliberately does not enum these — they are product
    // vocabulary the client owns — but "the client owns it" is not "the client may send 8KB".
    const format = typeof req.body?.format === 'string' && req.body.format.length <= 32
      ? req.body.format : null;
    const fillEmpty = req.body?.fill_empty === true;

    // The code is generated even for a private lobby. `is_public` is checked FIRST on the join
    // path, so a lobby can be flipped public later without needing a code minted at that moment
    // — and a code that exists but is refused is strictly simpler than a nullable one.
    await query(
      `insert into game_lobbies (match_id, host_user_id, join_code, is_public, format, fill_empty)
       values ($1, $2, $3, $4, $5, $6)
       on conflict (match_id) do nothing`,
      [matchId, userId, newJoinCode(), isPublic, format, fillEmpty]
    );

    // The host is a member of their own lobby. Without this the roster renders without the one
    // person guaranteed to be looking at it, and `everyone ready` would be vacuously true.
    await query(
      `insert into game_lobby_members (match_id, user_id, state)
       values ($1, $2, 'ready')
       on conflict (match_id, user_id) do nothing`,
      [matchId, userId]
    );

    const loaded = await loadLobby(matchId);
    if (!loaded) return res.status(500).json({ error: 'lobby vanished' });
    const members = await lobbyMembers(matchId);
    await publishLobbyUpdate(loaded.lobby, loaded.maxPlayers, members, 'opened');

    res.status(201).json({
      lobby: lobbyPayload(loaded.lobby, loaded.maxPlayers),
      members: members.map(memberPayload),
      messages: [],
    });
  })
);

/**
 * GET /games/matches/:id/lobby — the lobby, its roster and the recent chat.
 *
 * THE READ IS AUTHORIZED, and that is the point of this handler. Chat here is server-readable
 * (see the migration), which makes "who may read it" a decision this route has to make
 * explicitly rather than one the encryption made for free everywhere else in this API.
 *
 * Two ways in, and no third:
 *   * you are a LOBBY MEMBER, or
 *   * you hold the JOIN CODE for a public lobby (`?code=`), which is what lets the join screen
 *     preview a party before committing to it.
 * Being named in `game_matches.player_ids` is deliberately NOT sufficient: seat list and lobby
 * presence are different facts (the migration says so), and an invited player who never opened
 * the lobby has no business reading what was typed in it.
 */
router.get(
  '/matches/:id/lobby',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const matchId = req.params.id;
    if (!UUID_RE.test(matchId)) return res.status(400).json({ error: 'bad match id' });

    const loaded = await loadLobby(matchId);
    // 404, not 200-with-null. "This match has no party lobby" is exactly what the client needs
    // to hear in order to fall back to the 1:1 invite-and-wait view.
    if (!loaded) return res.status(404).json({ error: 'no lobby for this match' });

    const members = await lobbyMembers(matchId);
    const isMember = members.some((m) => m.user_id === userId);

    // Case-insensitive, because a code is typed by a human. Compared against the stored code
    // only when the lobby is public — a private lobby refuses the code outright.
    const supplied = typeof req.query.code === 'string' ? req.query.code.trim().toUpperCase() : null;
    const holdsCode =
      loaded.lobby.is_public &&
      !!loaded.lobby.join_code &&
      supplied === loaded.lobby.join_code;

    if (!isMember && !holdsCode) {
      return res.status(403).json({ error: 'not in this lobby' });
    }

    const messages = await query<{
      id: string; user_id: string | null; body: string; created_at: Date;
      full_name: string | null; username: string | null;
    }>(
      `select m.id, m.user_id, m.body, m.created_at, u.full_name, u.username
         from game_lobby_messages m
         left join users u on u.id = m.user_id
        where m.match_id = $1
        order by m.id desc
        limit $2`,
      [matchId, LOBBY_MESSAGE_LIMIT]
    );

    res.json({
      lobby: lobbyPayload(loaded.lobby, loaded.maxPlayers),
      members: members.map(memberPayload),
      // Re-reversed to oldest-first. The query takes the NEWEST 50 (order by id desc) because
      // the tail is what a lobby shows; the client renders top-down, so the order is flipped
      // back here rather than in three clients.
      messages: messages.reverse().map((m) => ({
        id: String(m.id),
        user_id: m.user_id,
        // Null author means a deleted account (the migration's ON DELETE SET NULL). The client
        // renders it as "Left" — the message is not rewritten or hidden, because other people
        // were part of that conversation.
        name: m.full_name ?? m.username ?? null,
        body: m.body,
        created_at: new Date(m.created_at).getTime(),
      })),
      // Told plainly rather than inferred from `host_user_id === me` in three clients.
      is_host: loaded.lobby.host_user_id === userId,
      is_member: isMember,
    });
  })
);

/**
 * POST /games/lobbies/join — enter a public lobby with its code.
 * Body: { join_code }
 *
 * NOT KEYED ON A MATCH ID, deliberately: the code IS the address. Someone joining this way does
 * not know the match id and must not have to — handing out a uuid alongside the code would make
 * the code pointless.
 *
 * Every rejection below is a real state a code can be in, and each is reported distinctly
 * because the client's message differs: "no such code" is a typo, "already started" is bad luck,
 * "full" is a reason to wait.
 */
router.post(
  '/lobbies/join',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const raw = req.body?.join_code;
    if (typeof raw !== 'string') return res.status(400).json({ error: 'join_code required' });
    const code = raw.trim().toUpperCase();
    // Shape-checked before it reaches the database: the column has a CHECK constraint of the
    // same shape, and a query is not the place to discover the client sent a sentence.
    if (!/^[A-Z0-9]{4,8}$/.test(code)) return res.status(404).json({ error: 'unknown code' });

    const rows = await query<LobbyRow & { max_players: number; status: string }>(
      `select l.match_id, l.host_user_id, l.join_code, l.is_public, l.format,
              l.fill_empty, l.started_at, l.created_at, g.max_players, m.status
         from game_lobbies l
         join game_matches m on m.id = l.match_id
         join games g on g.id = m.game_id
        where l.join_code = $1 and l.started_at is null`,
      [code]
    );
    const row = rows[0];
    // A private lobby answers exactly as an unknown code does, and that is intentional: any
    // other answer turns this endpoint into an oracle for "is this a real code" — the same
    // reasoning the invite path's opaque 403 is built on.
    if (!row || !row.is_public) return res.status(404).json({ error: 'unknown code' });
    if (row.status !== 'waiting') {
      return res.status(409).json({ error: 'match already started', status: row.status });
    }

    const members = await lobbyMembers(row.match_id);
    // Already in? Idempotent success. A retried join must not 409 the person who is already
    // standing in the room.
    if (!members.some((m) => m.user_id === userId)) {
      if (members.length >= row.max_players) {
        return res.status(409).json({ error: 'lobby is full' });
      }
      // The row insert is what actually enforces one membership per person (primary key), and
      // the length check above is a courteous pre-check, not the guarantee. Two people racing
      // for the last seat can both pass the check; both inserts succeed and the lobby is one
      // over. That is tolerated over a lock here because `start` re-checks the cap before it
      // flips the match — the seat count that matters is the one at start, not at join.
      await query(
        `insert into game_lobby_members (match_id, user_id, state)
         values ($1, $2, 'waiting')
         on conflict (match_id, user_id) do nothing`,
        [row.match_id, userId]
      );

      // SEATED IN THE MATCH TOO. A lobby member who is not in `player_ids` would be a person
      // watching a game they cannot play — every downstream check (join, snapshot, forfeit)
      // authorizes on that array. Appended rather than rebuilt so seat order, which the rules
      // modules read as turn order, is preserved.
      await query(
        `update game_matches
            set player_ids = case
                  when player_ids @> $2::jsonb then player_ids
                  else player_ids || $2::jsonb
                end
          where id = $1`,
        [row.match_id, JSON.stringify([userId])]
      );
    }

    const after = await lobbyMembers(row.match_id);
    await publishLobbyUpdate(row, row.max_players, after, 'joined');

    res.json({
      match_id: row.match_id,
      lobby: lobbyPayload(row, row.max_players),
      members: after.map(memberPayload),
    });
  })
);

/**
 * POST /games/matches/:id/lobby/ready — the caller's own ready state.
 * Body: { ready: bool, mic_on?: bool }
 *
 * THE CALLER'S OWN, ALWAYS. There is no user id in the body and there will not be one: a member
 * marking someone ELSE ready is how a host starts a match into a seat whose player is not there.
 */
router.post(
  '/matches/:id/lobby/ready',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const matchId = req.params.id;
    if (!UUID_RE.test(matchId)) return res.status(400).json({ error: 'bad match id' });
    if (typeof req.body?.ready !== 'boolean') {
      return res.status(400).json({ error: 'ready must be a boolean' });
    }

    const loaded = await loadLobby(matchId);
    if (!loaded) return res.status(404).json({ error: 'no lobby for this match' });
    if (loaded.lobby.started_at) return res.status(409).json({ error: 'lobby already started' });

    // `mic_on` rides along because the two toggles live in the same row and a member flipping
    // either wants one round trip. Absent means unchanged, never means false.
    const micOn = typeof req.body?.mic_on === 'boolean' ? req.body.mic_on : null;

    // The update is the membership check: no row, no update, and `returning` tells us which
    // happened without a second query.
    const updated = await query<{ user_id: string }>(
      `update game_lobby_members
          set state = $3,
              mic_on = coalesce($4::boolean, mic_on),
              seen_at = now()
        where match_id = $1 and user_id = $2
        returning user_id`,
      [matchId, userId, req.body.ready ? 'ready' : 'waiting', micOn]
    );
    if (updated.length === 0) return res.status(403).json({ error: 'not in this lobby' });

    const members = await lobbyMembers(matchId);
    await publishLobbyUpdate(loaded.lobby, loaded.maxPlayers, members, 'ready');
    res.json({ ok: true, members: members.map(memberPayload) });
  })
);

/**
 * POST /games/matches/:id/lobby/leave — step out of the party.
 *
 * ── WHEN THE HOST LEAVES, THE LOBBY IS CANCELLED. ───────────────────────────────
 * The alternative — transfer host to the longest-present member — was considered and rejected.
 * The lobby is keyed to a match whose `created_by` is the host, and every creator-only route in
 * this router (`/cancel`, and `/lobby` itself) authorizes against that column. Transferring the
 * lobby host would put the two out of step: the new host could start the match but not cancel
 * it, and `POST /matches/:id/lobby` re-opened by the new host would 403. Making the transfer
 * honest means also rewriting `game_matches.created_by`, i.e. rewriting who created a row —
 * which is a durable historical fact that history and the leaderboard both read.
 *
 * So the host leaving ends the party, the match is marked 'cancelled' exactly as `/cancel` does,
 * and everyone is told why. A party without the person who assembled it is not a party that
 * should silently promote a stranger who joined by code thirty seconds ago into someone who can
 * start a match on other people's behalf.
 *
 * A non-host leaving is just a row delete, and their seat frees up.
 */
router.post(
  '/matches/:id/lobby/leave',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const matchId = req.params.id;
    if (!UUID_RE.test(matchId)) return res.status(400).json({ error: 'bad match id' });

    const loaded = await loadLobby(matchId);
    // Leaving a lobby that is already gone is not an error — the caller's goal is already true.
    // Same posture as `POST /matches/:id/leave` above.
    if (!loaded) return res.json({ ok: true, cancelled: false });

    const before = await lobbyMembers(matchId);
    if (!before.some((m) => m.user_id === userId)) {
      return res.json({ ok: true, cancelled: false });
    }

    if (loaded.lobby.host_user_id === userId) {
      // Everyone who was present is told, INCLUDING the host, so their own screen dismisses off
      // the same frame every other device gets.
      const audience = before.map((m) => m.user_id);
      // The match dies with the lobby. 'cancelled' rather than deleted, matching `/cancel`:
      // the row stays out of the leaderboard (which counts only 'finished') and history can
      // still show that a game was set up and never played.
      await query(
        `update game_matches
            set status = 'cancelled', ended_at = now(), end_reason = 'cancelled'
          where id = $1 and status = 'waiting'`,
        [matchId]
      );
      // Members and messages go with it via ON DELETE CASCADE on game_lobbies(match_id).
      await query(`delete from game_lobbies where match_id = $1`, [matchId]);

      await publishLobbyUpdate(
        { ...loaded.lobby, started_at: null }, loaded.maxPlayers, [], 'cancelled', audience
      );
      // The existing invite-card path is also told, so a chat invite pointing at this match
      // flips to cancelled rather than sitting there offering a dead lobby.
      await publishInviteStatus(matchId, loaded.playerIds, 'cancelled');
      return res.json({ ok: true, cancelled: true });
    }

    await query(
      `delete from game_lobby_members where match_id = $1 and user_id = $2`,
      [matchId, userId]
    );
    // Unseated from the match as well — the mirror of the join path. Leaving the id in
    // `player_ids` would leave a seat allocated to someone who walked out, and the match would
    // wait forever for them.
    await query(
      `update game_matches
          set player_ids = coalesce((
                select jsonb_agg(value)
                  from jsonb_array_elements(player_ids) as value
                 where value #>> '{}' <> $2::text
              ), '[]'::jsonb)
        where id = $1 and status = 'waiting'`,
      [matchId, userId]
    );

    const after = await lobbyMembers(matchId);
    // The leaver is included in the audience so their device sees the same authoritative frame.
    await publishLobbyUpdate(
      loaded.lobby, loaded.maxPlayers, after, 'left',
      [...after.map((m) => m.user_id), userId]
    );
    res.json({ ok: true, cancelled: false });
  })
);

/**
 * POST /games/matches/:id/lobby/messages — say something while you wait.
 * Body: { body }
 *
 * MEMBERS ONLY. Holding the join code is enough to PREVIEW a lobby (see the GET) but not to
 * talk in it — reading a room you are considering entering and putting words in it are
 * different acts.
 *
 * SERVER-READABLE, and this is the one route in the games API that stores user prose in
 * plaintext. The migration header carries the full argument; the short version is that it is
 * ephemeral, dies with the match, and its members may hold no ratchet session with each other.
 * This is NOT a precedent for the message pipe.
 */
router.post(
  '/matches/:id/lobby/messages',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const matchId = req.params.id;
    if (!UUID_RE.test(matchId)) return res.status(400).json({ error: 'bad match id' });

    const raw = req.body?.body;
    if (typeof raw !== 'string') return res.status(400).json({ error: 'body required' });
    const body = raw.trim();
    // Bounds mirror the CHECK constraint in 052 so a too-long message is a 400 with a reason
    // rather than a 500 from a constraint violation.
    if (body.length < 1 || body.length > 500) {
      return res.status(400).json({ error: 'body must be 1-500 characters' });
    }

    const loaded = await loadLobby(matchId);
    if (!loaded) return res.status(404).json({ error: 'no lobby for this match' });

    const members = await lobbyMembers(matchId);
    const me = members.find((m) => m.user_id === userId);
    if (!me) return res.status(403).json({ error: 'not in this lobby' });

    const inserted = await query<{ id: string; created_at: Date }>(
      `insert into game_lobby_messages (match_id, user_id, body)
       values ($1, $2, $3)
       returning id, created_at`,
      [matchId, userId, body]
    );

    const payload = {
      id: String(inserted[0].id),
      user_id: userId,
      name: me.full_name ?? me.username ?? null,
      body,
      created_at: new Date(inserted[0].created_at).getTime(),
    };

    // A message is its OWN event rather than a lobby update carrying the roster: chat is the
    // one thing here that arrives in a stream, and re-sending four member rows per "ok" would
    // make the noisiest event the heaviest one.
    const frame = JSON.stringify({
      type: 'game_lobby_message',
      match_id: matchId,
      message: payload,
    });
    await Promise.all(
      members.map((m) => publisher.publish(`channel:user:${m.user_id}`, frame))
    ).catch(() => { /* the message is committed; a dropped frame is a re-read */ });

    res.status(201).json({ message: payload });
  })
);

/**
 * POST /games/matches/:id/lobby/start — the host begins the match.
 *
 * HOST ONLY, and everyone must be ready. `fill_empty` relaxes the SEAT count (empty seats are
 * accepted rather than blocking), but it deliberately does NOT relax the READY check: a seat
 * nobody claimed is a seat the host chose to leave empty, while a member sitting at 'waiting'
 * is a person who has not said they are there. Starting into the first is a decision; starting
 * into the second is stranding someone.
 *
 * WHAT THIS DOES NOT DO: build the board. That is `game_join` on the games service, exactly as
 * `POST /matches/:id/join` does it — the rules live in one place and this route does not learn
 * them. It flips the durable status and hands off.
 */
router.post(
  '/matches/:id/lobby/start',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth as { user_id: string };
    const matchId = req.params.id;
    if (!UUID_RE.test(matchId)) return res.status(400).json({ error: 'bad match id' });

    const loaded = await loadLobby(matchId);
    if (!loaded) return res.status(404).json({ error: 'no lobby for this match' });
    if (loaded.lobby.host_user_id !== userId) return res.status(403).json({ error: 'host only' });
    if (loaded.lobby.started_at) return res.status(409).json({ error: 'already started' });
    if (loaded.matchStatus !== 'waiting') {
      return res.status(409).json({ error: 'match is not waiting', status: loaded.matchStatus });
    }

    const members = await lobbyMembers(matchId);
    // Re-checked HERE and not only at join: joins race, and the seat count that matters is the
    // one at the moment the match becomes real.
    if (members.length > loaded.maxPlayers) {
      return res.status(409).json({ error: 'lobby is full' });
    }
    if (!loaded.lobby.fill_empty) {
      // Without fill-empty the party must actually fill the game. The catalog's min_players is
      // the floor, and it is the same floor `POST /games/matches` enforces.
      const minimum = await query<{ min_players: number }>(
        `select g.min_players from game_matches m join games g on g.id = m.game_id where m.id = $1`,
        [matchId]
      );
      const min = minimum[0]?.min_players ?? 2;
      if (members.length < min) {
        return res.status(409).json({ error: 'not enough players', needed: min });
      }
    }
    const notReady = members.filter((m) => m.state !== 'ready');
    if (notReady.length > 0) {
      // Counted, not named. The client already has the roster and renders which chips are grey;
      // repeating the ids here would be a second source for a fact it can already see.
      return res.status(409).json({ error: 'not everyone is ready', waiting: notReady.length });
    }

    const started = await query<{ started_at: Date }>(
      // Guarded on `started_at is null` so two taps in flight cannot both start the match — the
      // loser updates zero rows and is told the truth below.
      `update game_lobbies set started_at = now()
        where match_id = $1 and started_at is null
        returning started_at`,
      [matchId]
    );
    if (started.length === 0) return res.status(409).json({ error: 'already started' });

    await query(
      `update game_matches set status = 'active', started_at = now()
        where id = $1 and status = 'waiting'`,
      [matchId]
    );

    const startedLobby: LobbyRow = { ...loaded.lobby, started_at: started[0].started_at };
    await publishLobbyUpdate(startedLobby, loaded.maxPlayers, members, 'started');
    // The invite-card path is told too, so any chat invite pointing at this match stops
    // offering a lobby that is now a game in progress.
    await publishInviteStatus(matchId, loaded.playerIds, 'active', members.length);

    // Hand the match to the games service, which owns what a fresh board looks like. Same
    // publish `POST /matches/:id/join` makes, for the same reason.
    await publisher.publish(
      GAMES_INPUT_CHANNEL,
      JSON.stringify({ type: 'game_join', match_id: matchId, from_user_id: userId })
    );

    res.json({ ok: true, match_id: matchId, started_at: new Date(started[0].started_at).getTime() });
  })
);

export default router;
