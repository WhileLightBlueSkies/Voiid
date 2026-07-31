// VOIID games service — the referee (docs/GAMES.md §5).
//
// WHY THIS IS ITS OWN PROCESS. backend/websocket is deliberately a dumb pipe: it has no
// database and no notion of what any payload means. Game rules need to validate moves
// against real state, which is business logic. Putting that in the relay would break the
// one architectural rule that service follows — and worse, a crash in a new, fast-moving
// game surface would take messaging down with it. Messaging is the product; games are not
// allowed to be able to break it. Separate pm2 process, same box, restartable alone.
//
// THE SHAPE:
//   relay --(channel:games:input)--> THIS --(channel:user:<id>)--> relay --> players
//
// Input arrives already authenticated: the relay stamps `from_user_id` from the socket's
// JWT and the client cannot forge it, exactly as it does for loc_update. This service
// therefore trusts WHO sent a frame, and trusts nothing else about it.
import { sub, pub, GAMES_INPUT_CHANNEL } from './redis';
import { factoryFor } from './engine/registry';
import { loadMatch, saveMatch, finishMatch, markStarted, type LiveMatch } from './matches';
import { query } from './db';
import type { GameEngine, GameOutcome } from './engine/GameEngine';
import http from 'http';

// --- Per-match input rate limiting --------------------------------------------------
// Same posture as the relay's loc_update bucket: silent drop, in-memory, no error frame
// back. A client flooding moves is a bug or an attack, and answering it with traffic is
// how you turn one bad client into a fan-out amplifier. Turn-based games need only a
// handful of moves a minute; 60 is generous headroom that still bounds the damage.
const INPUT_MAX_PER_WINDOW = Number(process.env.VOIID_GAME_INPUT_RATE) || 60;
const INPUT_WINDOW_MS = 60_000;
const inputRate = new Map<string, { count: number; windowStart: number }>();

function rateLimited(matchId: string, userId: string): boolean {
  const key = `${matchId}:${userId}`;
  const now = Date.now();
  const bucket = inputRate.get(key);
  if (!bucket || now - bucket.windowStart >= INPUT_WINDOW_MS) {
    inputRate.set(key, { count: 1, windowStart: now });
    return false;
  }
  if (bucket.count >= INPUT_MAX_PER_WINDOW) return true;
  bucket.count += 1;
  return false;
}

/**
 * Push state to every player in the match. One publish per recipient on the SAME
 * `channel:user:<id>` the API and relay already use — which is why the clients need no
 * new connection, no new reconnect logic, and no second socket: a game frame arrives on
 * the pipe they already hold open for chat.
 */
async function broadcast(m: LiveMatch): Promise<void> {
  const frame = JSON.stringify({
    type: 'game_state',
    match_id: m.matchId,
    game: m.slug,
    seq: m.seq,
    payload: m.state,
  });
  for (const uid of m.players) {
    await pub.publish(`channel:user:${uid}`, frame);
  }
}

async function endMatch(m: LiveMatch, engine: GameEngine, outcome: GameOutcome) {
  m.state = engine.serialize();
  m.seq += 1;
  m.secret = engine.serializeSecret?.();
  // Broadcast the terminal state BEFORE clearing Redis: the players must see the winning
  // board, and finishMatch drops the key.
  await broadcast(m);
  for (const uid of m.players) inputRate.delete(`${m.matchId}:${uid}`);
  await finishMatch(m.matchId, m.players, outcome);
}

/**
 * A `game_input` frame forwarded by the relay:
 *   { type:'game_input', match_id, from_user_id, payload }
 * `from_user_id` is authoritative. `payload` is untrusted and interpreted only by the
 * rules module.
 */
async function handleInput(msg: Record<string, any>): Promise<void> {
  const matchId = msg.match_id;
  const userId = msg.from_user_id;
  if (typeof matchId !== 'string' || typeof userId !== 'string') return;

  const m = await loadMatch(matchId);
  if (!m) return; // unknown/expired match — silent, same as the relay's posture

  // Membership is enforced HERE, unlike the relay's location path which cannot check it
  // (no DB). This service holds the player list in the live record, so an outsider firing
  // inputs at someone else's match is rejected outright rather than merely being useless.
  if (!m.players.includes(userId)) return;
  if (rateLimited(matchId, userId)) return;

  const factory = factoryFor(m.slug);
  if (!factory) return;

  const engine = factory.restore(m.state, m.secret);
  const result = engine.applyInput(userId, msg.payload ?? {});

  // Rejected input produces NO broadcast. An illegal move costs the server one Redis read
  // and nothing else.
  if (!result.accepted) return;

  if (result.outcome) {
    await endMatch(m, engine, result.outcome);
    return;
  }

  m.state = engine.serialize();
  // Keep the hidden picks alive across the next restore. Not part of `state`, so broadcast() can
  // never leak them — which is the whole point of the separate channel.
  m.secret = engine.serializeSecret?.();
  m.seq += 1;
  await saveMatch(m);
  await broadcast(m);
}

/**
 * `game_join` — published by the API when a player accepts an invite. Creates the live
 * record on first join and starts the match once every seat is filled.
 *
 * The live record is created here rather than in the API because this service owns rules:
 * only the factory knows what a fresh board looks like.
 */
async function handleJoin(msg: Record<string, any>): Promise<void> {
  const matchId = msg.match_id;
  if (typeof matchId !== 'string') return;

  const joiner = typeof msg.from_user_id === 'string' ? msg.from_user_id : null;

  const existing = await loadMatch(matchId);
  if (existing) {
    // Record this join, then decide whether the match is playable yet.
    const joined = new Set(existing.joined ?? []);
    if (joiner) joined.add(joiner);
    existing.joined = [...joined];
    await saveMatch(existing);

    // A state frame means "the game is on". Sending one before every seat is filled is what made
    // matches start early: the creator joins at creation, so a broadcast on their own join handed
    // their lobby a board while the opponent had not accepted anything. Broadcast only once
    // everyone is here — a rejoin after that is a genuine resync and still gets a frame.
    if (existing.joined.length >= existing.players.length) {
      await markStarted(matchId);
      await broadcast(existing);
    }
    return;
  }

  const rows = await query<{
    slug: string;
    player_ids: string[];
    status: string;
    options: Record<string, unknown> | null;
  }>(
    `select g.slug, m.player_ids, m.status, m.options
       from game_matches m join games g on g.id = m.game_id
      where m.id = $1`,
    [matchId]
  );
  const row = rows[0];
  if (!row || row.status === 'finished' || row.status === 'abandoned') return;

  const factory = factoryFor(row.slug);
  if (!factory) return;

  const players = row.player_ids;
  // Per-match settings (hand cricket's over count). Chosen at creation, so they must come
  // from the row — the match is built lazily here, long after the creator's tap.
  const engine = factory.create(players, row.options ?? {});
  const m: LiveMatch = {
    matchId,
    slug: row.slug,
    players,
    seq: 0,
    state: engine.serialize(),
    secret: engine.serializeSecret?.(),
    joined: joiner ? [joiner] : [],
  };
  await saveMatch(m);

  // FIRST join only starts the match in a single-player game. For everyone else the board is built
  // and held until the remaining seats join — see the resync branch above for why.
  if (m.joined!.length >= players.length) {
    await markStarted(matchId);
    await broadcast(m);
  }
}

sub.subscribe(GAMES_INPUT_CHANNEL, (err) => {
  if (err) {
    console.error('[games] failed to subscribe', err);
    process.exit(1);
  }
  console.log(`[games] subscribed to ${GAMES_INPUT_CHANNEL}`);
});

sub.on('message', (_channel, raw) => {
  let msg: Record<string, any>;
  try {
    msg = JSON.parse(raw);
  } catch {
    return;
  }
  // One malformed frame must never kill the process — every handler is fire-and-forget
  // with its own catch, so a bug in one match cannot stop the others.
  const run =
    msg.type === 'game_input'
      ? handleInput(msg)
      : msg.type === 'game_join'
        ? handleJoin(msg)
        : null;
  if (run) run.catch((e) => console.error('[games] handler error', e));
});

// Health check, matching the other services' deploy expectations.
const port = Number(process.env.GAMES_PORT) || 4002;
http
  .createServer((req, res) => {
    if (req.url === '/health') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, service: 'games' }));
      return;
    }
    res.writeHead(404);
    res.end();
  })
  .listen(port, () => console.log(`[games] health on :${port}`));
