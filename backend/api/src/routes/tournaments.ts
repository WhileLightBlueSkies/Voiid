// Community tournaments — an ORGANISING LAYER over the existing games stack, not a second one.
//
// ── WHAT THIS ROUTER IS ALLOWED TO CREATE ────────────────────────────────────────
//
// `game_matches` rows, with four extra columns filled in. That is the whole feature. A
// tournament match is the same object as a friendly match: same catalog row, same referee
// process (backend/games), same rules module, same Redis live state, same finish path, same
// result rows, same `POST /games/matches/:id/join`. 031_tournaments.sql refuses a parallel
// `tournament_matches` table for the reason that matters — two of everything is two of
// everything drifting — and this file is the half of that promise that lives in code.
//
// SO: there is deliberately no join route, no move route, no state route and no abandon route
// here. Those already exist in routes/games.ts and they work unchanged on a bracket fixture.
//
// ── HOW A PLAYER FINDS OUT THEY HAVE A MATCH ─────────────────────────────────────
//
// BY PULLING `GET /tournaments/:id/matches`, not by receiving an invite.
//
// docs/research/04_communities_plan.md says bracket invites "flow client-side over E2EE as
// they already do". They cannot, and 031's header records why: the ordinary invite is an E2EE
// message, and two strangers drawn against each other in round 2 have no Double Ratchet
// session and — under 020_reachability.sql — no right to open one. A BRACKET PAIRING IS NOT A
// MESSAGING RIGHT. The match row is the entire handshake.
//
// ── THE E2EE POSTURE, UNCHANGED ──────────────────────────────────────────────────
//
// Game state is server-readable because the server referees; that exception was made and
// scoped in 024_games.sql and this file adds nothing to it. Standings are arithmetic over
// match results the server already wrote. No message, call, location or moment becomes
// readable, and nothing here is a precedent for making one.
//
// A community-scoped leaderboard is defensible where the global one is not, and the
// difference is consent: everyone on a tournament table joined the same community on purpose.
// `GET /games/leaderboard` stays opponent-scoped for exactly the reason it says it does.
//
// ── MOUNTING ────────────────────────────────────────────────────────────────────
//
// Paths are declared in full and the router is mounted at the API root, matching
// routes/communityHostThreads.ts. A general communities router's one-segment `/:handle` route
// can never match a two-segment `/:id/tournaments` path, so mount order does not matter.
import { Router } from 'express';
import { pool, query } from '../db';
import { publisher } from '../redis';
import { requireAuth } from '../auth';
import { rateLimit } from '../security';
import { asyncHandler } from '../util';
import { communityAccess } from '../communityRoles';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// The same channel routes/games.ts publishes `game_join` on. Re-declared rather than imported
// so this file takes no dependency on that router's internals.
const GAMES_INPUT_CHANNEL = 'channel:games:input';

const FORMATS = new Set(['single_elim', 'round_robin']);

// Mirrors the ceilings in 031_tournaments.sql. The DATABASE is the authority — the check
// constraint there is what an admin UPDATE cannot get past — but rejecting here turns a
// constraint violation (a 500 from the global handler) into a 400 that says what is wrong.
const FORMAT_MAX_PLAYERS: Record<string, number> = { single_elim: 64, round_robin: 16 };

// Authorisation is `communityAccess` (../communityRoles) for every endpoint here. Roles are
// read from `community_members`, never from anything on the tournament: 030 makes the roster
// the single authority on who runs a community, and 031 deliberately gives this feature no role
// column of its own so there is nothing here to disagree with it.

interface TournamentRow {
  id: string;
  community_id: string;
  game_id: string;
  name: string;
  format: string;
  status: string;
  created_by: string;
  max_players: number;
  starts_at: Date | null;
  started_at: Date | null;
  finished_at: Date | null;
  winner_user_id: string | null;
  created_at: Date;
  slug: string;
  game_name: string;
  icon_key: string | null;
}

async function loadTournament(id: string): Promise<TournamentRow | undefined> {
  return (
    await query<TournamentRow>(
      `select t.*, g.slug, g.name as game_name, g.icon_key
         from tournaments t join games g on g.id = t.game_id
        where t.id = $1`,
      [id]
    )
  )[0];
}

/** The card shape every endpoint here returns, so three clients do not each invent one. */
function card(t: TournamentRow, playerCount?: number) {
  return {
    id: t.id,
    community_id: t.community_id,
    name: t.name,
    format: t.format,
    status: t.status,
    game_slug: t.slug,
    game_name: t.game_name,
    icon_key: t.icon_key,
    created_by: t.created_by,
    max_players: t.max_players,
    player_count: playerCount ?? null,
    starts_at: t.starts_at,
    started_at: t.started_at,
    finished_at: t.finished_at,
    winner_user_id: t.winner_user_id,
    created_at: t.created_at,
  };
}

// ─────────────────────────────────────────────────────────────────────────────────
// BRACKET SEEDING — the ONE piece of bracket knowledge that lives in the API.
//
// It lives here, and not with the advance routine in backend/games, because seeding must
// commit in the same transaction that flips the tournament to 'active' (031's own note: a
// crash between the two leaves a tournament that is live with no fixtures and no way to
// produce them). That transaction belongs to the request that started it.
//
// The two halves cannot drift into each other: this maps SEED -> SLOT once, advancement maps
// SLOT -> PARENT SLOT forever. Neither function can express the other's question.
// ─────────────────────────────────────────────────────────────────────────────────

/**
 * Standard knockout seeding order for a bracket of `size` (a power of two).
 *
 * Built by repeated reflection: [1,2] -> [1,4,2,3] -> [1,8,4,5,2,7,3,6]. The property that
 * matters is that the top two seeds can only meet in the final, the top four only in the
 * semis, and so on — which is what makes a seeded bracket worth seeding. Entry 2i plays entry
 * 2i+1 in slot i.
 */
function seedOrder(size: number): number[] {
  let arr = [1, 2];
  while (arr.length < size) {
    const n = arr.length * 2;
    const next: number[] = [];
    for (const s of arr) {
      next.push(s);
      next.push(n + 1 - s);
    }
    arr = next;
  }
  return arr;
}

interface Fixture {
  players: string[];
  round: number;
  slot: number;
  bye: boolean;
}

/**
 * Round 1 of a knockout bracket for `players` in seed order (index 0 = seed 1).
 *
 * A field that is not a power of two gets BYES: the bracket is rounded up and the slots whose
 * second entrant does not exist become one-player matches, stored finished with that player as
 * winner. 031's header explains why a bye is a match row rather than a special case — the
 * advance routine, the bracket screen and the "is this round complete" check then all treat it
 * identically to a played match, and none of them needs to know byes exist.
 *
 * Byes land on the TOP seeds, because seedOrder pairs seed 1 with the highest seed number and
 * the highest seed numbers are the ones that do not exist.
 */
function seedSingleElim(players: string[]): Fixture[] {
  let size = 2;
  while (size < players.length) size *= 2;
  const order = seedOrder(size);

  const fixtures: Fixture[] = [];
  for (let slot = 0; slot * 2 + 1 < order.length; slot++) {
    const a = players[order[slot * 2] - 1];
    const b = players[order[slot * 2 + 1] - 1];
    const present = [a, b].filter((p): p is string => Boolean(p));
    // Both seeds absent is impossible for a field of 2 or more: seedOrder pairs a low seed
    // with a high one, and the low seed of every slot in a minimal bracket exists.
    if (present.length === 0) continue;
    fixtures.push({ players: present, round: 1, slot, bye: present.length === 1 });
  }
  return fixtures;
}

/**
 * The full round-robin fixture list, by the circle method: one player is fixed and the rest
 * rotate, which produces every pairing exactly once across `M-1` rounds.
 *
 * An odd field gets a phantom entry whose opponent simply has no fixture that round. That
 * "bye" writes NO match row at all — unlike a knockout bye, nothing downstream is waiting on a
 * winner from it, so a one-player finished row would be noise in the fixture list.
 *
 * The cost is why 031 caps this format at 16 while knockout goes to 64: N players is
 * N*(N-1)/2 matches here against N-1 there. At 64 that would be 2,016 fixtures.
 */
function seedRoundRobin(players: string[]): Fixture[] {
  const field: (string | null)[] = [...players];
  if (field.length % 2 === 1) field.push(null);
  const m = field.length;

  const fixed = field[0];
  let rotating = field.slice(1);

  const fixtures: Fixture[] = [];
  for (let r = 0; r < m - 1; r++) {
    const list = [fixed, ...rotating];
    for (let i = 0; i < m / 2; i++) {
      const a = list[i];
      const b = list[m - 1 - i];
      if (!a || !b) continue;
      fixtures.push({ players: [a, b], round: r + 1, slot: i, bye: false });
    }
    // Rotate everything except the fixed entry one place. This is what makes each round a
    // different set of pairings and every pairing happen exactly once.
    rotating = [rotating[rotating.length - 1], ...rotating.slice(0, -1)];
  }
  return fixtures;
}

// ─────────────────────────────────────────────────────────────────────────────────
// POST /communities/:id/tournaments — create.
//
// Body: { id?, game_slug, name, format?, max_players?, starts_at? }
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/communities/:id/tournaments',
  requireAuth,
  rateLimit({ max: 20, windowSeconds: 3600, bucket: 'tournament-create' }),
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const communityId = String(req.params.id ?? '');
    if (!UUID_RE.test(communityId)) return res.status(400).json({ error: 'community id must be a uuid' });

    const guard = await communityAccess(communityId, userId, true);
    if (!guard.ok) return res.status(guard.status).json({ error: guard.error });

    const { id, game_slug, name, format, max_players, starts_at } = req.body ?? {};

    // CLIENT-SUPPLIED ID IS THE RETRY KEY, the same role communities.id plays in 030. Creating
    // a tournament and seeding it are separate calls, so a client whose POST timed out must be
    // able to land on the same row instead of leaving a second, empty tournament on the
    // community's list. Optional: a client that does not care gets a server-generated uuid.
    const tournamentId = typeof id === 'string' ? id : null;
    if (tournamentId !== null && !UUID_RE.test(tournamentId)) {
      return res.status(400).json({ error: 'id must be a uuid' });
    }

    if (typeof game_slug !== 'string' || typeof name !== 'string') {
      return res.status(400).json({ error: 'game_slug and name are required' });
    }
    const trimmed = name.trim();
    if (trimmed.length < 1 || trimmed.length > 60) {
      return res.status(400).json({ error: 'name must be 1-60 characters' });
    }

    const fmt = typeof format === 'string' ? format : 'single_elim';
    if (!FORMATS.has(fmt)) return res.status(400).json({ error: 'unknown format' });

    // THE DEFAULT IS FORMAT-AWARE, and it has to be. 031 defaults the column to 32 and caps
    // round_robin at 16 — so a client that creates a round robin without naming a size would be
    // handed the column default and rejected by the ceiling, for a field it never asked about.
    const cap = Number.isInteger(max_players)
      ? Number(max_players)
      : Math.min(32, FORMAT_MAX_PLAYERS[fmt]);
    if (cap < 2 || cap > FORMAT_MAX_PLAYERS[fmt]) {
      return res
        .status(400)
        .json({ error: `max_players must be 2-${FORMAT_MAX_PLAYERS[fmt]} for ${fmt}` });
    }

    // starts_at is ADVISORY — 031 says so and means it. Nothing starts a tournament but an
    // organiser pressing start, because "seed automatically at 19:00" needs a scheduler this
    // codebase does not have, and a bracket that quietly seeded itself with three of the
    // twenty expected registrants would be worse than one that waited.
    let startsAt: Date | null = null;
    if (starts_at != null) {
      const d = new Date(starts_at);
      if (Number.isNaN(d.getTime())) return res.status(400).json({ error: 'starts_at is not a date' });
      startsAt = d;
    }

    // TWO SEATS EXACTLY. Pairing is 1v1 all the way down the bracket, so a game whose catalog
    // row cannot seat two people has no tournament to run. Checked here rather than in a
    // constraint because it is a join against `games`, which a CHECK cannot do.
    const game = (
      await query<{ id: string; min_players: number; max_players: number }>(
        `select id, min_players, max_players from games where slug = $1 and enabled = true`,
        [game_slug]
      )
    )[0];
    if (!game) return res.status(404).json({ error: 'unknown game' });
    if (game.min_players > 2 || game.max_players < 2) {
      return res.status(400).json({ error: 'this game cannot be played one-against-one' });
    }

    const inserted = (
      await query<{ id: string }>(
        `insert into tournaments
           (id, community_id, game_id, name, format, max_players, starts_at, created_by)
         values (coalesce($1::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8)
         on conflict (id) do nothing
         returning id`,
        [tournamentId, communityId, game.id, trimmed, fmt, cap, startsAt, userId]
      )
    )[0];

    if (!inserted) {
      // The id already existed. That is the retry landing on its own row — but only if it IS
      // its own row. A client that guessed or replayed somebody else's uuid gets a 409 rather
      // than a view of a tournament it did not create.
      const existing = await loadTournament(tournamentId!);
      if (!existing || existing.created_by !== userId || existing.community_id !== communityId) {
        return res.status(409).json({ error: 'tournament id already in use' });
      }
      return res.status(200).json({ tournament: card(existing, 0) });
    }

    const created = await loadTournament(inserted.id);
    return res.status(201).json({ tournament: card(created!, 0) });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// GET /communities/:id/tournaments — the community's tournament tab.
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/communities/:id/tournaments',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const communityId = String(req.params.id ?? '');
    if (!UUID_RE.test(communityId)) return res.status(400).json({ error: 'community id must be a uuid' });

    // Reading the list requires membership, not adminship: a tournament roster is the
    // community roster filtered, and 030 already says a roster is visible to the space it
    // belongs to. It is NOT public — a non-member gets the same 403 as a pending applicant.
    const guard = await communityAccess(communityId, userId, false);
    if (!guard.ok) return res.status(guard.status).json({ error: guard.error });

    const rows = await query<TournamentRow & { player_count: string; registered: boolean }>(
      `select t.*, g.slug, g.name as game_name, g.icon_key,
              (select count(*) from tournament_players p
                where p.tournament_id = t.id and p.state = 'registered')::text as player_count,
              exists (select 1 from tournament_players p
                       where p.tournament_id = t.id and p.user_id = $2
                         and p.state = 'registered') as registered
         from tournaments t join games g on g.id = t.game_id
        where t.community_id = $1
        order by t.created_at desc
        limit 100`,
      [communityId, userId]
    );

    res.json({
      tournaments: rows.map((r) => ({ ...card(r, Number(r.player_count)), registered: r.registered })),
    });
  })
);

/**
 * Resolve a tournament and prove the caller may see it, in one place.
 *
 * Every /tournaments/:id endpoint below starts here, so there is exactly one definition of
 * "may this person look at this bracket" and no endpoint can quietly acquire a laxer one.
 */
async function openTournament(
  id: unknown,
  userId: string,
  needsAdmin: boolean
): Promise<{ ok: true; t: TournamentRow } | { ok: false; status: number; error: string }> {
  if (typeof id !== 'string' || !UUID_RE.test(id)) {
    return { ok: false, status: 400, error: 'tournament id must be a uuid' };
  }
  const t = await loadTournament(id);
  if (!t) return { ok: false, status: 404, error: 'no such tournament' };
  const guard = await communityAccess(t.community_id, userId, needsAdmin);
  if (!guard.ok) return { ok: false, status: guard.status, error: guard.error };
  return { ok: true, t };
}

// ─────────────────────────────────────────────────────────────────────────────────
// GET /tournaments/:id — card plus the field.
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/tournaments/:id',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openTournament(req.params.id, userId, false);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    const players = await query(
      `select p.user_id, p.seed, p.state, p.eliminated_in_round, p.registered_at,
              u.full_name, u.username
         from tournament_players p
         left join users u on u.id = p.user_id
        where p.tournament_id = $1
        order by p.seed nulls last, p.registered_at`,
      [opened.t.id]
    );

    const registered = players.filter((p: any) => p.state === 'registered').length;
    res.json({
      tournament: card(opened.t, registered),
      players,
      you_registered: players.some((p: any) => p.user_id === userId && p.state === 'registered'),
    });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /tournaments/:id/register
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/tournaments/:id/register',
  requireAuth,
  rateLimit({ max: 60, windowSeconds: 3600, bucket: 'tournament-register' }),
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openTournament(req.params.id, userId, false);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });
    if (opened.t.status !== 'open') {
      return res.status(409).json({ error: 'registration is closed' });
    }

    const client = await pool.connect();
    try {
      await client.query('begin');

      // LOCK THE CONTAINER, then count. Two players registering for the last place at the same
      // instant both read "31 of 32" if the count is taken without a lock, and both insert —
      // a check constraint cannot express "how many rows point at this parent", so the
      // serialisation has to be explicit. Locking the tournament row rather than the player
      // rows is what makes it work: the row being contended for does not exist yet.
      const locked = (
        await client.query<{ status: string; max_players: number }>(
          `select status, max_players from tournaments where id = $1 for update`,
          [opened.t.id]
        )
      ).rows[0];
      if (!locked || locked.status !== 'open') {
        await client.query('rollback');
        return res.status(409).json({ error: 'registration is closed' });
      }

      const already = (
        await client.query<{ state: string }>(
          `select state from tournament_players where tournament_id = $1 and user_id = $2`,
          [opened.t.id, userId]
        )
      ).rows[0];

      if (already?.state !== 'registered') {
        const count = Number(
          (
            await client.query<{ n: string }>(
              `select count(*)::text as n from tournament_players
                where tournament_id = $1 and state = 'registered'`,
              [opened.t.id]
            )
          ).rows[0].n
        );
        if (count >= locked.max_players) {
          await client.query('rollback');
          return res.status(409).json({ error: 'this tournament is full' });
        }
      }

      // UPSERT on a NULL-FREE primary key. (tournament_id, user_id) has no nullable column in
      // it, which is what makes ON CONFLICT actually match — a NULL in a unique key makes the
      // conflict target never fire and turns an upsert into a silent second insert, the bug
      // 027_receipt_null_device.sql exists to undo. Re-registering after a withdrawal is the
      // normal path, not an edge case.
      await client.query(
        `insert into tournament_players (tournament_id, user_id, state)
         values ($1, $2, 'registered')
         on conflict (tournament_id, user_id)
           do update set state = 'registered', registered_at = now()`,
        [opened.t.id, userId]
      );

      await client.query('commit');
      return res.json({ ok: true, registered: true });
    } catch (e) {
      await client.query('rollback');
      throw e;
    } finally {
      client.release();
    }
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /tournaments/:id/withdraw
//
// Before the bracket is seeded this is a plain state change. AFTER it is seeded it is a
// FORFEIT: the bracket is not reshaped, because re-seeding a live bracket would invalidate
// matches that have already been played. 031's header sets this rule; this is it in code.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/tournaments/:id/withdraw',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openTournament(req.params.id, userId, false);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    const t = opened.t;
    if (t.status === 'finished' || t.status === 'cancelled') {
      return res.status(409).json({ error: 'this tournament is over' });
    }

    const updated = await query<{ user_id: string }>(
      `update tournament_players set state = 'withdrawn'
        where tournament_id = $1 and user_id = $2 and state = 'registered'
        returning user_id`,
      [t.id, userId]
    );
    // Already withdrawn, or never registered. Idempotent rather than 404: a second tap must
    // not be an error, and "you were not in this" is not information worth a distinct status.
    if (updated.length === 0) return res.json({ ok: true, forfeited: false });

    if (t.status === 'active') {
      // The walkover rows are written by the referee, not here. "A walkover awards the slot but
      // scores nothing" is a rule about how a match ends, and every other such rule lives in
      // backend/games — see the handler there. Authorisation has already happened above; the
      // frame carries no authority of its own.
      await publisher.publish(
        GAMES_INPUT_CHANNEL,
        JSON.stringify({ type: 'tournament_forfeit', tournament_id: t.id, user_id: userId })
      );
      return res.json({ ok: true, forfeited: true });
    }

    res.json({ ok: true, forfeited: false });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /tournaments/:id/start — seed the bracket.
//
// ONE TRANSACTION, non-negotiable (031): assigning seeds, flipping status to 'active' and
// inserting the fixtures must commit together. A crash between them leaves a tournament that
// says it is live, has no fixtures, and has no route that would ever produce them — start is
// the only thing that seeds, and start refuses a tournament that is already 'active'.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/tournaments/:id/start',
  requireAuth,
  rateLimit({ max: 30, windowSeconds: 3600, bucket: 'tournament-start' }),
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openTournament(req.params.id, userId, true);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    const client = await pool.connect();
    try {
      await client.query('begin');

      // Lock and re-read inside the transaction: the status check above was made outside it,
      // and two organisers pressing start together must not both seed. The `status = 'open'`
      // predicate on this SELECT is what makes the second one lose.
      const t = (
        await client.query<{ id: string; game_id: string; format: string; status: string }>(
          `select id, game_id, format, status from tournaments where id = $1 for update`,
          [opened.t.id]
        )
      ).rows[0];
      if (!t || t.status !== 'open') {
        await client.query('rollback');
        return res.status(409).json({ error: 'this tournament has already started' });
      }

      // Seeding order is REGISTRATION ORDER, and it is written down rather than randomised.
      // A field that can be explained ("you registered fourth, you are seed 4") is one an
      // organiser can defend; a shuffle would be unreproducible, which matters the first time
      // somebody asks why they drew the favourite.
      const field = (
        await client.query<{ user_id: string }>(
          `select user_id from tournament_players
            where tournament_id = $1 and state = 'registered'
            order by registered_at, user_id`,
          [t.id]
        )
      ).rows.map((r) => r.user_id);

      if (field.length < 2) {
        await client.query('rollback');
        return res.status(409).json({ error: 'a tournament needs at least two players' });
      }

      // Seeds are assigned at START, not at registration: seeding is a decision about the whole
      // field and cannot be made while the field is still changing.
      for (let i = 0; i < field.length; i++) {
        await client.query(
          `update tournament_players set seed = $3
            where tournament_id = $1 and user_id = $2`,
          [t.id, field[i], i + 1]
        );
      }

      const fixtures =
        t.format === 'round_robin' ? seedRoundRobin(field) : seedSingleElim(field);

      // One multi-row INSERT. A loop would let a mid-flight failure leave half a round, and
      // nothing re-runs seeding — the transaction would roll back, but only if the failure is
      // an exception rather than a lost connection between statements.
      const values: string[] = [];
      const params: unknown[] = [t.game_id, userId, t.id];
      for (const f of fixtures) {
        const p = params.length;
        values.push(
          `($1, $${p + 1}::jsonb, $2, $${p + 2}, $${p + 3}, $3, $${p + 4}, $${p + 5}, 1, $${p + 6})`
        );
        params.push(
          JSON.stringify(f.players),
          f.bye ? 'finished' : 'waiting',
          // A bye is a one-player row that is already won. It writes NO game_match_results, and
          // that is what keeps it out of every score: standings and the global leaderboard both
          // read results, never winner_id alone. A bye must never look like a win someone earned.
          f.bye ? f.players[0] : null,
          f.round,
          f.slot,
          f.bye ? new Date() : null
        );
      }

      await client.query(
        `insert into game_matches
           (game_id, player_ids, created_by, status, winner_id,
            tournament_id, tournament_round, tournament_slot, tournament_attempt, ended_at)
         values ${values.join(', ')}
         on conflict (tournament_id, tournament_round, tournament_slot, tournament_attempt)
           where tournament_id is not null
           do nothing`,
        params
      );

      await client.query(
        `update tournaments set status = 'active', started_at = now() where id = $1`,
        [t.id]
      );

      await client.query('commit');

      // NO ADVANCE IS FIRED HERE, and that is a claim worth stating rather than leaving to be
      // rediscovered. A freshly seeded round can never already be complete: seedOrder pairs a
      // low seed against a high one, so the lowest-numbered slot of any field of two or more
      // always holds two real players and therefore a 'waiting' match. Round robin is the same
      // — every fixture it creates has two players. Advancement is driven by matches ending,
      // and at this instant none has.
      const fresh = await loadTournament(t.id);
      return res.json({ tournament: card(fresh!, field.length), fixtures: fixtures.length });
    } catch (e) {
      await client.query('rollback');
      throw e;
    } finally {
      client.release();
    }
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /tournaments/:id/cancel
//
// Matches are LEFT ALONE. They are history: people played them, they belong on the players'
// records, and deleting them to tidy up a container would erase results that were real.
// `finished_at` stays null — 031 constrains status='finished' and finished_at to agree, and a
// cancelled tournament did not finish.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/tournaments/:id/cancel',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openTournament(req.params.id, userId, true);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    const rows = await query<{ id: string }>(
      `update tournaments set status = 'cancelled'
        where id = $1 and status in ('open', 'active')
        returning id`,
      [opened.t.id]
    );
    if (rows.length === 0) return res.status(409).json({ error: 'this tournament is already over' });
    res.json({ ok: true });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// GET /tournaments/:id/matches — THE FIXTURE LIST.
//
// This is how a player learns they have a match, and it is the reason there is no invite push:
// see the header. `mine` marks the caller's own fixtures so a client can render "your next
// match" without filtering a whole bracket client-side.
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/tournaments/:id/matches',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openTournament(req.params.id, userId, false);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    const rows = await query<{
      id: string;
      tournament_round: number;
      tournament_slot: number;
      tournament_attempt: number;
      status: string;
      winner_id: string | null;
      player_ids: string[];
      created_at: Date;
      ended_at: Date | null;
    }>(
      `select id, tournament_round, tournament_slot, tournament_attempt,
              status, winner_id, player_ids, created_at, ended_at
         from game_matches
        where tournament_id = $1
        order by tournament_round, tournament_slot, tournament_attempt`,
      [opened.t.id]
    );

    res.json({
      matches: rows.map((r) => ({
        match_id: r.id,
        round: r.tournament_round,
        slot: r.tournament_slot,
        attempt: r.tournament_attempt,
        status: r.status,
        winner_id: r.winner_id,
        player_ids: r.player_ids,
        // A one-player row is a bye or the remains of a walkover — the client renders it as a
        // free pass rather than as a game, and must not offer a Join button for it.
        bye: r.player_ids.length < 2,
        mine: r.player_ids.includes(userId),
        created_at: r.created_at,
        ended_at: r.ended_at,
      })),
    });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// GET /tournaments/:id/standings
//
// Straight off the `tournament_standings` VIEW in 031 — there is no state here that the match
// rows do not already imply, and materialising it would create a second source of truth that a
// missed UPDATE silently corrupts.
//
// LEFT JOINED FROM THE FIELD, not from the view: a registrant who has not played yet belongs
// on the table on zero points. Reading only the view would make people vanish from the
// standings of a tournament they are in until their first result lands.
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/tournaments/:id/standings',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openTournament(req.params.id, userId, false);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    const rows = await query(
      `select p.user_id,
              u.full_name,
              u.username,
              p.seed,
              p.state,
              p.eliminated_in_round,
              coalesce(s.played, 0)  as played,
              coalesce(s.wins, 0)    as wins,
              coalesce(s.draws, 0)   as draws,
              coalesce(s.losses, 0)  as losses,
              coalesce(s.score, 0)   as score,
              coalesce(s.points, 0)  as points
         from tournament_players p
         left join users u on u.id = p.user_id
         left join tournament_standings s
                on s.tournament_id = p.tournament_id and s.user_id = p.user_id
        where p.tournament_id = $1
        order by coalesce(s.points, 0) desc,
                 coalesce(s.score, 0) desc,
                 coalesce(s.wins, 0) desc,
                 p.seed nulls last`,
      [opened.t.id]
    );

    res.json({ standings: rows, winner_user_id: opened.t.winner_user_id });
  })
);

export default router;
