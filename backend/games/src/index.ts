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
//
// PER-MATCH SERIALIZATION (LUDO_GAME_SPEC.md §7.3): every input for one match now flows
// through ONE async queue entry — compare expectedSeq, restore, validate, apply, increment,
// persist, broadcast happen atomically with respect to every other frame for the same
// match. Node's event loop alone never guaranteed that: two awaits inside one handler let
// a second input interleave between the first's load and save. For multi-process deploys
// the Postgres seq compare-and-swap in matches.ts remains the outer guard; this queue makes
// the single-process case correct rather than merely usual.
import { sub, pub, state as redisState, GAMES_INPUT_CHANNEL } from './redis';
import { randomUUID } from 'node:crypto';
import { factoryFor } from './engine/registry';
import {
    loadMatch,
    saveMatch,
    finishMatch,
    markStarted,
    setDeadline,
    popDueDeadlines,
    type LiveMatch,
} from './matches';
import {
    projectionFor,
    namesForViewer,
    invalidateProjection,
} from './projection';
import { advanceTournament, forfeitFixtures } from './tournaments';
import { enqueue } from './queue';
import { query } from './db';
import type { GameEngine, GameOutcome, GameStatePayload } from './engine/GameEngine';
import http from 'http';

// --- Per-match input rate limiting --------------------------------------------------
// Same posture as the relay's loc_update bucket: silent drop, in-memory, no error frame
// back. A client flooding moves is a bug or an attack, and answering it with traffic is
// how you turn one bad client into a fan-out amplifier. Turn-based games need only a
// handful of moves a minute; 60 is generous headroom that still bounds the damage.
//
// EXCEPTION (§16): a VALID-looking Ludo command dropped silently would look like a lost tap,
// so the first drop per window answers with exactly one `RATE_LIMITED` rejection, throttled
// to once per 10 seconds so the answer cannot become the amplifier.
const INPUT_MAX_PER_WINDOW = Number(process.env.VOIID_GAME_INPUT_RATE) || 60;
const INPUT_WINDOW_MS = 60_000;
const RATE_LIMIT_NOTICE_MS = 10_000;

const CONTINUOUS_HEADROOM = 2;
const inputRate = new Map<string, { count: number; windowStart: number }>();
const lastRateNotice = new Map<string, number>();

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

// --- Per-match async queues (§7.3): see queue.ts -------------------------------------

// --- Presence (§7.1, §16) ------------------------------------------------------------

/** Socket absence for five seconds marks a seat disconnected; it never pauses a clock. */
const PRESENCE_TIMEOUT_MS = 5_000;
/** userId -> 'connected'|'disconnected', as LAST PUBLISHED, per match. */
const publishedConnections = new Map<string, Record<string, 'connected' | 'disconnected'>>();

function connectionsOf(m: LiveMatch): Record<string, 'connected' | 'disconnected'> {
    const now = Date.now();
    const out: Record<string, 'connected' | 'disconnected'> = {};
    for (const uid of m.players) {
        const seen = m.presence?.[uid];
        out[uid] = seen !== undefined && now - seen <= PRESENCE_TIMEOUT_MS ? 'connected' : 'disconnected';
    }
    return out;
}

async function sweepPresence(): Promise<void> {
    for (const [matchId, m] of liveMatches) {
        if (m.slug !== 'ludo' || !m.presence) continue;
        const before = publishedConnections.get(matchId) ?? {};
        const after = connectionsOf(m);
        for (const uid of m.players) {
            if (before[uid] && before[uid] === after[uid]) continue;
            const seat = m.players.indexOf(uid);
            const frame = JSON.stringify({
                type: 'game_presence',
                match_id: matchId,
                seat,
                connection: after[uid],
            });
            for (const peer of m.players) {
                await pub.publish(`channel:user:${peer}`, frame);
            }
        }
        publishedConnections.set(matchId, after);
    }
}

/** Server-owned ten-minute invite expiry; runs even when no client has the lobby open. */
async function sweepExpiredLudoInvites(): Promise<void> {
    const rows = await query<{ id: string; player_ids: string[]; created_at: Date }>(
        `with due as (
           select m.id from game_matches m join games g on g.id = m.game_id
            where g.slug = 'ludo' and m.status = 'waiting'
              and m.created_at <= now() - interval '10 minutes'
            order by m.created_at limit 100 for update of m skip locked
         )
         update game_matches m set status = 'expired', ended_at = now(), end_reason = 'expired'
          from due where m.id = due.id returning m.id, m.player_ids, m.created_at`,
    );
    for (const row of rows) {
        const frame = JSON.stringify({
            type: 'game_invite_status', match_id: row.id, status: 'expired',
            accepted_seats: 0, total_seats: row.player_ids.length,
            expires_at: new Date(row.created_at).getTime() + 10 * 60_000,
        });
        await Promise.all(row.player_ids.map((uid) => pub.publish(`channel:user:${uid}`, frame)));
    }
}

/**
 * Push state to every player in the match. One publish per recipient on the SAME
 * `channel:user:<id>` the API and relay already use — which is why the clients need no
 * new connection, no new reconnect logic, and no second socket: a game frame arrives on
 * the pipe they already hold open for chat.
 *
 * PER-RECIPIENT FRAMES come from either an information projection (Sea Battle's fleet) or,
 * for Ludo, the identity projection plus connection bits resolved per viewer (§6).
 */
async function broadcast(
    m: LiveMatch,
    wire?: GameStatePayload,
    engine?: GameEngine,
): Promise<void> {
    if (m.slug === 'ludo' && engine) {
        await broadcastLudo(m, engine);
        return;
    }

    const envelope = (payload: GameStatePayload) =>
        JSON.stringify({
            type: 'game_state',
            match_id: m.matchId,
            game: m.slug,
            seq: m.seq,
            payload,
        });

    if (engine?.serializeForPlayer) {
        for (const uid of m.players) {
            await pub.publish(`channel:user:${uid}`, envelope(engine.serializeForPlayer(uid)!));
        }
        return;
    }

    const frame = envelope(wire ?? m.state);
    for (const uid of m.players) {
        await pub.publish(`channel:user:${uid}`, frame);
    }
}

interface LudoEngineHooks {
    setFrameContext?: (ctx: unknown) => void;
}

/** The schema-v3 envelope (§7.2): recipient-projected, seq-stamped, server_now stamped. */
async function broadcastLudo(m: LiveMatch, engine: GameEngine): Promise<void> {
    const players = ludoSeatPlayers(engine, m);
    const base = await projectionFor(m.matchId, players, m.sourceConversationId ?? null);
    const serverNow = Date.now();
    const connections = connectionsOf(m);

    for (const uid of m.players) {
        (engine as unknown as LudoEngineHooks).setFrameContext?.({
            serverNow,
            seq: m.seq,
            connections,
            names: namesForViewer(base, uid),
        });
        const payload = engine.serializeForPlayer!(uid);
        await pub.publish(
            `channel:user:${uid}`,
            JSON.stringify({
                type: 'game_state',
                match_id: m.matchId,
                game: m.slug,
                schema_version: 3,
                seq: m.seq,
                server_now: serverNow,
                payload,
            }),
        );
    }
}

function ludoSeatPlayers(engine: GameEngine, m: LiveMatch): (string | null)[] {
    try {
        const state = engine.serialize() as { ludo?: { humanUserIds?: (string | null)[] } };
        if (state?.ludo?.humanUserIds && Array.isArray(state.ludo.humanUserIds)) return state.ludo.humanUserIds;
    } catch {
        // fall through to the flat roster
    }
    return m.players;
}

function ludoPublic(engine: GameEngine, viewerId: string): Record<string, unknown> | null {
    try {
        const p = engine.serializeForPlayer!(viewerId) as { ludoV3?: Record<string, unknown> };
        return p.ludoV3 ?? null;
    } catch {
        return null;
    }
}

function rejectTo(userId: string, body: Record<string, unknown>): Promise<void> {
    return pub
        .publish(`channel:user:${userId}`, JSON.stringify(body))
        .then(() => undefined);
}

/**
 * Keep the sorted-set deadline in step with whatever the engine now says.
 */
async function syncDeadline(m: LiveMatch, engine: GameEngine): Promise<void> {
    if (!engine.deadlineAt) return;
    await setDeadline(m.matchId, engine.isFinished() ? null : engine.deadlineAt());
}

async function endMatch(m: LiveMatch, engine: GameEngine, outcome: GameOutcome) {
    stopLoop(m.matchId);
    m.state = engine.serialize();
    const wire = engine.serializeForWire?.();
    m.seq += 1;
    m.secret = engine.serializeSecret?.();

    // Terminal audit (§5.4): reveal the RNG seed only NOW, alongside the result row.
    let audit: Record<string, unknown> | undefined;
    if (m.slug === 'ludo') {
        const secretInner = (m.secret as { ludo?: Record<string, unknown> } | undefined)?.ludo;
        const publicState = ludoPublic(engine, '');
        audit = {
            rng: secretInner?.rng,
            winnerSeat: publicState?.winnerSeat ?? null,
            endReason: publicState?.endReason ?? null,
        };
    }

    await broadcast(m, wire, engine);
    for (const uid of m.players) {
        inputRate.delete(`${m.matchId}:${uid}`);
        lastRateNotice.delete(`${m.matchId}:${uid}`);
    }

    await finishMatch(m.matchId, m.players, outcome, audit);

    if (m.slug === 'ludo') {
        const publicState = ludoPublic(engine, m.players[0] ?? '');
        const frame = JSON.stringify({
            type: 'game_ended',
            match_id: m.matchId,
            winner_seat: publicState?.winnerSeat ?? null,
            end_reason: publicState?.endReason ?? null,
            ended_at: Date.now(),
        });
        for (const uid of m.players) {
            await pub.publish(`channel:user:${uid}`, frame);
        }
        invalidateProjection(m.matchId);
    }
}

// --- Tick loops for continuous games -------------------------------------------------

const loops = new Map<string, NodeJS.Timeout>();

function stopLoop(matchId: string): void {
    const t = loops.get(matchId);
    if (t) {
        clearInterval(t);
        loops.delete(matchId);
    }
    liveEngines.delete(matchId);
    liveMatches.delete(matchId);
    tickCounts.delete(matchId);
    publishedConnections.delete(matchId);
}

const liveEngines = new Map<string, GameEngine>();
const liveMatches = new Map<string, LiveMatch>();

/** Persist every Nth tick. A crash loses at most this many ticks of an arcade match. */
const PERSIST_EVERY = 5;
const tickCounts = new Map<string, number>();

async function runTick(matchId: string): Promise<void> {
    let m = liveMatches.get(matchId);
    if (!m) {
        const loaded = await loadMatch(matchId);
        if (!loaded) {
            stopLoop(matchId);
            return;
        }
        m = loaded;
        liveMatches.set(matchId, m);
    }

    const factory = factoryFor(m.slug);
    if (!factory) {
        stopLoop(matchId);
        return;
    }

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

    const full = engine.serialize();
    const wire = engine.serializeForWire?.();
    m.state = full;
    m.secret = engine.serializeSecret?.();
    m.seq += 1;

    await broadcast(m, wire, engine);

    const n = (tickCounts.get(matchId) ?? 0) + 1;
    tickCounts.set(matchId, n);
    if (n % PERSIST_EVERY === 0) await saveMatch(m);
}

function startLoop(matchId: string, hz: number): void {
    if (loops.has(matchId)) return;

    let running = false;
    const timer = setInterval(() => {
        if (running) return;
        running = true;
        runTick(matchId)
            .catch((e) => console.error('[games] tick error', matchId, e))
            .finally(() => {
                running = false;
            });
    }, Math.round(1000 / hz));

    loops.set(matchId, timer);
    console.log(`[games] tick loop started for ${matchId} @ ${hz}Hz`);
}

// --- Ludo lifecycle helpers -----------------------------------------------------------

/** Restore-or-reuse the live engine for a match, cached beside the record. */
function engineFor(m: LiveMatch): GameEngine | null {
    const factory = factoryFor(m.slug);
    if (!factory) return null;
    const live = liveEngines.get(m.matchId);
    if (live) return live;
    const engine = factory.restore(m.state, m.secret);
    liveEngines.set(m.matchId, engine);
    return engine;
}

function rememberCommand(m: LiveMatch, commandId: string, seq: number): void {
    if (!commandId) return;
    m.processedCommands = m.processedCommands ?? {};
    m.processedCommands[commandId] = seq;
    const ids = Object.keys(m.processedCommands);
    if (ids.length > 64) {
        for (const stale of ids.slice(0, ids.length - 64)) delete m.processedCommands[stale];
    }
}

/**
 * Commit one accepted Ludo transition: bump seq exactly once, persist, broadcast the
 * recipient-projected frames. Runs INSIDE the match queue.
 */
async function commitLudoTransition(m: LiveMatch, engine: GameEngine): Promise<void> {
    m.state = engine.serialize();
    m.secret = engine.serializeSecret?.();
    m.seq += 1;
    await syncDeadline(m, engine);
    await saveMatch(m);
    await broadcastLudo(m, engine);
}

// --- Input ---------------------------------------------------------------------------

/**
 * A `game_input` frame forwarded by the relay:
 *   { type:'game_input', match_id, from_user_id, payload }
 * `from_user_id` is authoritative. `payload` is untrusted and interpreted only by the rules
 * module.
 */
async function handleInput(msg: Record<string, any>): Promise<void> {
    const matchId = msg.match_id;
    const userId = msg.from_user_id;
    if (typeof matchId !== 'string' || typeof userId !== 'string') return;
    await enqueue(matchId, () => processInput(matchId, userId, msg.payload ?? {}));
}

async function withMatchLease(matchId: string, job: () => Promise<void>): Promise<void> {
    const key = `games:lease:${matchId}`, token = randomUUID();
    for (let attempt = 0; attempt < 25; attempt++) {
        if (await redisState.set(key, token, 'PX', 10_000, 'NX')) {
            try { await job(); }
            finally {
                await redisState.eval(
                    `if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end`,
                    1, key, token,
                );
            }
            return;
        }
        await new Promise((done) => setTimeout(done, 20));
    }
}

async function processInput(
    matchId: string,
    userId: string,
    payload: Record<string, unknown>,
): Promise<void> {
    const m = liveMatches.get(matchId) ?? (await loadMatch(matchId));
    if (!m) return;

    // Membership is enforced HERE, unlike the relay's location path which cannot check it.
    if (!m.players.includes(userId)) return;
    if (rateLimited(matchId, userId, m.slug)) {
        await maybeRateLimitNotice(m, userId);
        return;
    }

    // PRESENCE: any authenticated input refreshes last-seen. Never pauses a clock and never
    // reaches a frame beyond the derived connected/disconnected bit.
    m.presence = m.presence ?? {};
    m.presence[userId] = Date.now();

    const factory = factoryFor(m.slug);
    if (!factory) return;

    if (m.slug === 'ludo') {
        await withMatchLease(matchId, async () => {
            // Refresh after acquiring the cross-process lease; another worker may have
            // committed while this command waited.
            const current = (await loadMatch(matchId)) ?? m;
            await processLudoInput(current, userId, payload);
        });
        return;
    }

    // ---- Legacy shared-frame path, unchanged for every other game --------------------
    const live = liveEngines.get(matchId);
    const engine = live ?? factory.restore(m.state, m.secret);
    const result = engine.applyInput(userId, payload);
    if (!result.accepted) return;

    if (result.outcome) {
        await endMatch(m, engine, result.outcome);
        return;
    }

    const mustBroadcast = !result.silent;
    if (!live || mustBroadcast) {
        m.state = engine.serialize();
        m.secret = engine.serializeSecret?.();
    }
    if (!live) {
        m.seq += 1;
        await syncDeadline(m, engine);
        await saveMatch(m);
    }
    if (mustBroadcast) await broadcast(m, undefined, engine);
}

async function maybeRateLimitNotice(m: LiveMatch, userId: string): Promise<void> {
    if (m.slug !== 'ludo') return;
    const key = `${m.matchId}:${userId}`;
    const now = Date.now();
    const last = lastRateNotice.get(key) ?? 0;
    if (now - last < RATE_LIMIT_NOTICE_MS) return;
    lastRateNotice.set(key, now);
    await rejectTo(userId, {
        type: 'game_command_rejected',
        match_id: m.matchId,
        commandId: null,
        code: 'RATE_LIMITED',
        current_seq: m.seq,
    });
}

async function processLudoInput(
    m: LiveMatch,
    userId: string,
    payload: Record<string, unknown>,
): Promise<void> {
    // IDEMPOTENCY (§7.1): a retried command id replays NO second action; the current state
    // is re-sent to THAT user only so their UI can converge.
    const commandId = typeof payload.commandId === 'string' ? payload.commandId : '';
    if (commandId && m.processedCommands?.[commandId] !== undefined) {
        const engine = engineFor(m)!;
        await broadcastLudoTo(m, engine, userId);
        return;
    }

    // STALE_SEQ (§7.3): compare BEFORE applying. Two devices submitting simultaneously
    // produce one accepted transition and one STALE_SEQ; the stale client fetches the
    // winner's state and never predicts a move.
    const expectedSeq = payload.expectedSeq;
    if (typeof expectedSeq === 'number' && expectedSeq !== m.seq) {
        await rejectTo(userId, {
            type: 'game_command_rejected',
            match_id: m.matchId,
            commandId,
            code: 'STALE_SEQ',
            current_seq: m.seq,
        });
        return;
    }

    const engine = engineFor(m)!;
    const result = engine.applyInput(userId, payload);

    if (!result.accepted) {
        if (result.rejection) {
            await rejectTo(userId, {
                type: 'game_command_rejected',
                match_id: m.matchId,
                commandId,
                code: result.rejection,
                current_seq: m.seq,
            });
        }
        return;
    }

    if (result.outcome) {
        if (commandId) rememberCommand(m, commandId, m.seq + 1);
        await endMatch(m, engine, result.outcome);
        return;
    }

    if (commandId) rememberCommand(m, commandId, m.seq + 1);
    await commitLudoTransition(m, engine);
}

/** Send ONLY one user the projected current state (idempotent replay path). */
async function broadcastLudoTo(m: LiveMatch, engine: GameEngine, userId: string): Promise<void> {
    const players = ludoSeatPlayers(engine, m);
    const base = await projectionFor(m.matchId, players, m.sourceConversationId ?? null);
    const serverNow = Date.now();
        (engine as unknown as LudoEngineHooks).setFrameContext?.({
            serverNow,
            seq: m.seq,
        connections: connectionsOf(m),
        names: namesForViewer(base, userId),
    });
    const payload = engine.serializeForPlayer!(userId);
    await pub.publish(
        `channel:user:${userId}`,
        JSON.stringify({
            type: 'game_state',
            match_id: m.matchId,
            game: m.slug,
            schema_version: 3,
            seq: m.seq,
            server_now: serverNow,
            payload,
        }),
    );
}

// --- Join -----------------------------------------------------------------------------

/**
 * `game_join` — published by the API when a player accepts an invite. Creates the live
 * record on first join and starts the match once every seat is filled.
 */
async function handleJoin(msg: Record<string, any>): Promise<void> {
    const matchId = msg.match_id;
    if (typeof matchId !== 'string') return;
    const joiner = typeof msg.from_user_id === 'string' ? msg.from_user_id : null;
    await enqueue(matchId, () => processJoin(matchId, joiner));
}

async function processJoin(matchId: string, joiner: string | null): Promise<void> {
    const existing = liveMatches.get(matchId) ?? (await loadMatch(matchId));
    if (existing) {
        const joined = new Set(existing.joined ?? []);
        if (joiner) joined.add(joiner);
        existing.joined = [...joined];
        existing.presence = existing.presence ?? {};
        if (joiner) existing.presence[joiner] = Date.now();
        if (liveMatches.has(matchId)) liveMatches.set(matchId, existing);

        if (existing.slug === 'ludo') {
            invalidateProjection(matchId);
            const hooks = engineFor(existing) as unknown as LudoLifecycle & GameEngine;
            const engine = hooks;

            if (!ludoStarted(existing)) {
                // ACCEPTANCE + START (§8.1, §5.4): a match begins only when every selected
                // seat has accepted; the starting seat is chosen here, after the final
                // acceptance. Idempotent — a rejoin racing the start cannot start it twice.
                if (joiner) hooks.accept?.(joiner);
                if (hooks.allAccepted?.() === true) {
                    hooks.startAll?.(Date.now());
                    await markStarted(matchId);
                    await commitLudoTransition(existing, engine);
                } else if (joiner) {
                    existing.state = engine.serialize();
                    existing.secret = engine.serializeSecret?.();
                    existing.seq += 1;
                    await saveMatch(existing);
                    await broadcastLudoTo(existing, engine, joiner);
                }
            } else {
                // REJOIN / RESYNC (§9): register presence and return current status.
                existing.seq += 1;
                await saveMatch(existing);
                await broadcastLudo(existing, engine);
            }
            await publishInviteStatus(existing);
            return;
        }

        await saveMatch(existing);
        if (existing.joined.length >= existing.players.length) {
            await markStarted(matchId);
            const f = factoryFor(existing.slug);
            const engine = liveEngines.get(matchId) ?? f?.restore(existing.state, existing.secret);
            await broadcast(existing, undefined, engine);
            if (engine) await syncDeadline(existing, engine);
            if (f?.tickHz) startLoop(matchId, f.tickHz);
        }
        return;
    }

    const rows = await query<{
        slug: string;
        player_ids: string[];
        status: string;
        options: Record<string, unknown> | null;
        source_conversation_id: string | null;
    }>(
        `select g.slug, m.player_ids, m.status, m.options, m.source_conversation_id
           from game_matches m join games g on g.id = m.game_id
          where m.id = $1`,
        [matchId]
    );
    const row = rows[0];
    if (!row || row.status === 'finished' || row.status === 'abandoned') return;

    const factory = factoryFor(row.slug);
    if (!factory) return;

    const players = row.player_ids;
    const engine = factory.create(players, row.options ?? {});
    const m: LiveMatch = {
        matchId,
        slug: row.slug,
        players,
        seq: 0,
        state: engine.serialize(),
        secret: engine.serializeSecret?.(),
        joined: joiner ? [joiner] : [],
        processedCommands: {},
        presence: {},
        sourceConversationId: row.source_conversation_id,
    };

    if (row.slug === 'ludo') {
        // The creator was accepted at creation; joining marks further seats. The board is
        // built and held until every seat accepts — a waiting lobby never shows a game.
        const lifecycle = engine as unknown as LudoLifecycle;
        if (joiner) lifecycle.accept?.(joiner);
        liveMatches.set(matchId, m);
        liveEngines.set(matchId, engine);
        if (lifecycle.allAccepted?.() === true) {
            lifecycle.startAll?.(Date.now());
            await markStarted(matchId);
            await commitLudoTransition(m, engine);
        } else {
            await saveMatch(m);
            if (joiner) await broadcastLudoTo(m, engine, joiner);
        }
        await publishInviteStatus(m);
        return;
    }

    await saveMatch(m);
    if (m.joined!.length >= players.length) {
        await markStarted(matchId);
        await broadcast(m, undefined, engine);
        await syncDeadline(m, engine);
        if (factory.tickHz) startLoop(matchId, factory.tickHz);
    } else {
        await syncDeadline(m, engine);
    }
}

interface LudoLifecycle {
    accept?: (userId: string) => boolean;
    allAccepted?: () => boolean;
    startAll?: (now: number) => void;
    setFrameContext?: (ctx: unknown) => void;
}

function ludoStarted(m: LiveMatch): boolean {
    return (m.state as { ludo?: { started?: boolean } }).ludo?.started === true;
}

function acceptedCount(m: LiveMatch, engine: GameEngine): number {
    try {
        const state = engine.serialize() as { ludo?: { accepted?: boolean[]; assigned?: boolean[] } };
        return (state?.ludo?.accepted ?? []).filter((accepted, seat) =>
            accepted && (state.ludo?.assigned?.[seat] ?? true)).length;
    } catch {
        return m.joined?.length ?? 0;
    }
}

/** `game_invite_status` keeps every copy of the chat invite card authoritative (§7.2). */
async function publishInviteStatus(m: LiveMatch): Promise<void> {
    if (m.slug !== 'ludo') return;
    const engine = liveEngines.get(m.matchId);
    const frame = JSON.stringify({
        type: 'game_invite_status',
        match_id: m.matchId,
        status: ludoStarted(m) ? 'active' : 'waiting',
        accepted_seats: Math.max(acceptedCount(m, engine!), m.joined?.length ?? 0),
        total_seats: ((engine?.serialize() as { ludo?: { assigned?: boolean[] } } | undefined)
            ?.ludo?.assigned ?? []).filter(Boolean).length || m.players.length,
        expires_at: (m.inviteCreatedAtMs ?? Date.now()) + 10 * 60 * 1000,
    });
    for (const uid of m.players) {
        await pub.publish(`channel:user:${uid}`, frame);
    }
}

// --- Leave / forfeit -------------------------------------------------------------------

async function handleLeave(msg: Record<string, any>): Promise<void> {
    const matchId = msg.match_id;
    if (typeof matchId !== 'string') return;
    await enqueue(matchId, () => processLeave(matchId));
}

async function processLeave(matchId: string): Promise<void> {
    const m = await loadMatch(matchId);
    if (!m) return;
    if (m.players.length > 1) return;

    const engine = liveEngines.get(matchId) ?? factoryFor(m.slug)?.restore(m.state, m.secret);
    if (!engine || !engine.tick) return;

    const outcome: GameOutcome = { winnerId: null, scores: {} };
    await endMatch(m, engine, outcome);
    console.log(`[games] ${matchId} ended early: solo player left`);
}

/**
 * `game_forfeit` — published by POST /games/matches/:id/forfeit (§7.1). Drops the caller;
 * ends a duel or continues a four-player match.
 */
async function handleForfeit(msg: Record<string, any>): Promise<void> {
    const matchId = msg.match_id;
    const userId = msg.from_user_id;
    if (typeof matchId !== 'string' || typeof userId !== 'string') return;
    await enqueue(matchId, () => processForfeit(matchId, userId));
}

async function processForfeit(matchId: string, userId: string): Promise<void> {
    const m = liveMatches.get(matchId) ?? (await loadMatch(matchId));
    if (!m) return;
    if (m.slug !== 'ludo') return;
    if (!m.players.includes(userId)) return;

    const engine = engineFor(m)!;
    const result = (engine as unknown as {
        forfeit?: (u: string, n: number) => { accepted: boolean; outcome?: GameOutcome };
    }).forfeit?.(userId, Date.now());
    if (!result?.accepted) return;

    if (result.outcome) {
        await endMatch(m, engine, result.outcome);
        return;
    }
    await commitLudoTransition(m, engine);
}

// --- Tournament forfeit ---------------------------------------------------------------

async function handleTournamentForfeit(msg: Record<string, any>): Promise<void> {
    const tournamentId = msg.tournament_id;
    const userId = msg.user_id;
    if (typeof tournamentId !== 'string' || typeof userId !== 'string') return;

    const forfeited = await forfeitFixtures(tournamentId, userId);
    await advanceTournament(tournamentId);
    if (forfeited > 0) console.log(`[games] forfeited ${forfeited} fixture(s) in ${tournamentId}`);
}

// --- The deadline sweeper -------------------------------------------------------------

const SWEEP_INTERVAL_MS = 1000;

async function sweepOne(matchId: string): Promise<void> {
    await enqueue(matchId, async () => {
        const m = liveMatches.get(matchId) ?? (await loadMatch(matchId));
        if (!m) return;

        const factory = factoryFor(m.slug);
        if (!factory) return;

        const engine = liveEngines.get(matchId) ?? factory.restore(m.state, m.secret);
        if (!engine.onTimeout || engine.isFinished()) {
            if (engine.isFinished() && m.slug === 'ludo') {
                // A tombstone restored mid-input-window: retire the match with a clear reason
                // instead of letting it linger until the TTL.
                const inner = (m.state as { legacyAbandoned?: string }).legacyAbandoned;
                if (inner) {
                    await endMatch(m, engine, { winnerId: null, scores: {} });
                    console.log(`[games] ${matchId} abandoned: ${inner}`);
                }
            }
            return;
        }

        const result = engine.onTimeout();
        if (!result.accepted) {
            await syncDeadline(m, engine);
            return;
        }

        if (result.outcome) {
            await endMatch(m, engine, result.outcome);
            console.log(`[games] ${matchId} ended on deadline`);
            return;
        }

        if (m.slug === 'ludo') {
            await commitLudoTransition(m, engine);
        } else {
            m.state = engine.serialize();
            m.secret = engine.serializeSecret?.();
            m.seq += 1;
            await syncDeadline(m, engine);
            await saveMatch(m);
            await broadcast(m, undefined, engine);
        }
    });
}

let sweeping = false;
let lastInviteSweepAt = 0;
setInterval(() => {
    if (sweeping) return;
    sweeping = true;
    popDueDeadlines(Date.now())
        .then(async (due) => {
            for (const id of due) {
                await sweepOne(id).catch((e) => console.error('[games] sweep error', id, e));
            }
        })
        .catch((e) => console.error('[games] sweep error', e))
        .finally(() => {
            sweeping = false;
        });
    // Presence flips piggyback on the same cadence; they never pause a clock.
    sweepPresence().catch((e) => console.error('[games] presence sweep error', e));
    if (Date.now() - lastInviteSweepAt >= 5_000) {
        lastInviteSweepAt = Date.now();
        sweepExpiredLudoInvites().catch((e) => console.error('[games] invite sweep error', e));
    }
}, SWEEP_INTERVAL_MS);

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
    const run =
        msg.type === 'game_input'
            ? handleInput(msg)
            : msg.type === 'game_join'
                ? handleJoin(msg)
                : msg.type === 'game_leave'
                    ? handleLeave(msg)
                    : msg.type === 'game_forfeit'
                        ? handleForfeit(msg)
                        : msg.type === 'tournament_forfeit'
                            ? handleTournamentForfeit(msg)
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
