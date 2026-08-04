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
import type { GameEngine, GameOutcome, GameStatePayload } from './engine/GameEngine';
import http from 'http';

// --- Per-match input rate limiting --------------------------------------------------
// Same posture as the relay's loc_update bucket: silent drop, in-memory, no error frame
// back. A client flooding moves is a bug or an attack, and answering it with traffic is
// how you turn one bad client into a fan-out amplifier. Turn-based games need only a
// handful of moves a minute; 60 is generous headroom that still bounds the damage.
const INPUT_MAX_PER_WINDOW = Number(process.env.VOIID_GAME_INPUT_RATE) || 60;
const INPUT_WINDOW_MS = 60_000;

/**
 * Continuous games need a far higher ceiling, per game type (GAMES.md §115: "12-30/60s
 * depending on game, configurable per game type").
 *
 * 60/minute is generous for chess and lethal for a joystick: a player steering a snake
 * legitimately sends several frames a second, so the turn-based limit would silently freeze
 * their controls a second into every match. The limit is therefore derived from the game's
 * own tick rate — a client has no reason to send input faster than the server can act on it,
 * with 2x headroom for jitter and burst.
 */
const CONTINUOUS_HEADROOM = 2;
const inputRate = new Map<string, { count: number; windowStart: number }>();

function limitFor(slug: string): number {
  const hz = factoryFor(slug)?.tickHz;
  return hz ? Math.ceil(hz * 60 * CONTINUOUS_HEADROOM) : INPUT_MAX_PER_WINDOW;
}

function rateLimited(matchId: string, userId: string, slug: string): boolean {
  const key = `${matchId}:${userId}`;
  const now = Date.now();
  const bucket = inputRate.get(key);
  if (!bucket || now - bucket.windowStart >= INPUT_WINDOW_MS) {
    inputRate.set(key, { count: 1, windowStart: now });
    return false;
  }
  if (bucket.count >= limitFor(slug)) return true;
  bucket.count += 1;
  return false;
}

/**
 * Push state to every player in the match. One publish per recipient on the SAME
 * `channel:user:<id>` the API and relay already use — which is why the clients need no
 * new connection, no new reconnect logic, and no second socket: a game frame arrives on
 * the pipe they already hold open for chat.
 */
async function broadcast(m: LiveMatch, wire?: GameStatePayload): Promise<void> {
  const frame = JSON.stringify({
    type: 'game_state',
    match_id: m.matchId,
    game: m.slug,
    seq: m.seq,
    // `wire` is the engine's client-facing projection when it has one (continuous games send
    // food as a delta). Falling back to m.state keeps every turn-based game unchanged.
    payload: wire ?? m.state,
  });
  for (const uid of m.players) {
    await pub.publish(`channel:user:${uid}`, frame);
  }
}

async function endMatch(m: LiveMatch, engine: GameEngine, outcome: GameOutcome) {
  // Stop the clock before anything else. A tick firing between the terminal broadcast and
  // finishMatch() would resurrect the Redis key that finishMatch is about to delete, leaving
  // an orphaned match ticking forever with no players.
  stopLoop(m.matchId);
  m.state = engine.serialize();
  const wire = engine.serializeForWire?.();
  m.seq += 1;
  m.secret = engine.serializeSecret?.();
  // Broadcast the terminal state BEFORE clearing Redis: the players must see the winning
  // board, and finishMatch drops the key.
  await broadcast(m, wire);
  for (const uid of m.players) inputRate.delete(`${m.matchId}:${uid}`);
  await finishMatch(m.matchId, m.players, outcome);
}

// --- Tick loops for continuous games (docs/GAMES.md §105) ---------------------------
//
// Every game before Snake was turn-based, so this service had no clock at all: state changed
// only in response to an input frame. Continuous games must move on their own, which means a
// per-match interval that calls engine.tick() and broadcasts the result.
//
// THE LOOP IS KEYED ON tickHz BEING PRESENT, not on a list of slugs. A turn-based factory
// omits tickHz and therefore never gets a loop — so CPU cost scales with live ARCADE
// matches, not with matches in total, exactly as GameEngine.ts promises.
//
// The loop lives in this process's memory, not in Redis. That is a deliberate tradeoff: if
// the service restarts, in-flight arcade matches stop ticking and expire via the state TTL.
// GAMES.md §107 accepts exactly this ("if the games process restarts, in-progress arcade
// matches are lost"), and the alternative — a durable scheduler — is a great deal of
// machinery for a 3-minute match.
const loops = new Map<string, NodeJS.Timeout>();

function stopLoop(matchId: string): void {
  const t = loops.get(matchId);
  if (t) {
    clearInterval(t);
    loops.delete(matchId);
  }
  // Drop the live engine with the loop. Leaving it would leak a whole world per finished
  // match, and a rejoin must rebuild from Redis rather than resume a stale in-memory copy.
  liveEngines.delete(matchId);
  tickCounts.delete(matchId);
}

/**
 * The LIVE engine for each ticking match, held in this process's memory.
 *
 * Continuous games used to be rebuilt from Redis on every single tick — load, JSON.parse,
 * restore, tick, serialize, save — which put two network round-trips and a full
 * parse/stringify of the whole world inside a 100 ms budget. When one tick overran, the
 * `running` guard below dropped the NEXT tick entirely, so the game visibly hitched on a
 * regular cadence. Holding the engine here removes that work from the hot path; Redis
 * becomes a crash-recovery snapshot written every few ticks rather than the tick's own
 * storage.
 *
 * Turn-based games are untouched by this: they have no loop and still round-trip per input,
 * which is correct for them — a move every few seconds is nowhere near a budget.
 */
const liveEngines = new Map<string, GameEngine>();

/** Persist every Nth tick. A crash loses at most this many ticks of an arcade match. */
const PERSIST_EVERY = 5;
const tickCounts = new Map<string, number>();

async function runTick(matchId: string): Promise<void> {
  const m = await loadMatch(matchId);
  if (!m) {
    // Match expired or was finished by another path. Nothing left to drive.
    stopLoop(matchId);
    return;
  }

  const factory = factoryFor(m.slug);
  if (!factory) {
    stopLoop(matchId);
    return;
  }

  // Reuse the live engine; fall back to rebuilding from Redis after a restart, or the very
  // first tick of a match.
  let engine = liveEngines.get(matchId);
  if (!engine) {
    engine = factory.restore(m.state, m.secret);
    liveEngines.set(matchId, engine);
  }

  if (!engine.tick) {
    stopLoop(matchId);
    return;
  }

  const result = engine.tick();

  if (result.outcome) {
    stopLoop(matchId);
    await endMatch(m, engine, result.outcome);
    return;
  }

  if (!result.changed) return;

  // Order matters: serialize() captures the complete state, and serializeForWire() then
  // consumes the per-frame deltas. Reversing these would drain the delta buffers before they
  // were captured and the next frame would under-report its changes.
  const full = engine.serialize();
  const wire = engine.serializeForWire?.();
  m.state = full;
  m.secret = engine.serializeSecret?.();
  m.seq += 1;

  // Broadcast FIRST, persist on a slower cadence. The players are what the tick is for; the
  // Redis write is only so a process restart does not lose the match outright.
  await broadcast(m, wire);

  const n = (tickCounts.get(matchId) ?? 0) + 1;
  tickCounts.set(matchId, n);
  if (n % PERSIST_EVERY === 0) await saveMatch(m);
}

function startLoop(matchId: string, hz: number): void {
  if (loops.has(matchId)) return;

  // `running` guards against overlap: a tick that takes longer than the interval (a slow
  // Redis round-trip) must not have the next one start on top of it, or the two would race
  // on the same state and one's writes would be silently lost.
  let running = false;
  const timer = setInterval(() => {
    if (running) return;
    running = true;
    runTick(matchId)
      .catch((e) => console.error('[games] tick error', matchId, e))
      .finally(() => { running = false; });
  }, Math.round(1000 / hz));

  loops.set(matchId, timer);
  console.log(`[games] tick loop started for ${matchId} @ ${hz}Hz`);
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
  if (rateLimited(matchId, userId, m.slug)) return;

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

  // A continuous game's input only records intent; the next tick is what makes it visible.
  // Broadcasting here as well would double the fan-out for a player holding a joystick.
  if (!result.silent) await broadcast(m);
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
      // Idempotent: a rejoin/resync after the match is already running must not start a
      // second loop, which startLoop guards against.
      const f = factoryFor(existing.slug);
      if (f?.tickHz) startLoop(matchId, f.tickHz);
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
    if (factory.tickHz) startLoop(matchId, factory.tickHz);
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
