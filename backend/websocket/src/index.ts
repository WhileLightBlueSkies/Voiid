import { redeemWebTicket } from './webTicket';
import { callKeyCopies, callKeyDeliveryFrames, CALL_DEVICE_CLAIM_SCRIPT } from './callSignaling';
import { randomUUID } from 'node:crypto';
import { boundedSend, PRESENCE_SCRIPT, FRAME_BUDGET_SCRIPT } from './transport';
import { callGrantAllows } from '@voiid/common-utils';
// VOIID WebSocket relay (Phase 0 realtime flow, Section 10).
// Connect with JWT -> SUBSCRIBE channel:user:{id} -> in-memory socket_map.
// On Redis message for a user, push the wake/ciphertext-ref down their live socket.
// Unauthenticated sockets are rejected (Section 4.6).
import { WebSocketServer, WebSocket } from 'ws';
import Redis from 'ioredis';
import { authorizeConnection, useSessionCache, WS_CLOSE_REVOKED } from './session';
import { conversationRecipients, narrow, shareRecipients, useRecipientCache } from './recipients';
import { BoundedRateMap, SocketBudget } from './budget';

const port = Number(process.env.WS_PORT) || 4001;

// ── FAIL-CLOSED BOOT GUARD ────────────────────────────────────────────────────
// Mirrors the guard in backend/api/src/index.ts: a forged JWT accepted HERE is
// as good as one accepted by the API — this service trusts tokens, stamps sender
// identities from them and relays envelopes on their say-so. Production must not
// come up with the dev fallback secret or the auth bypass enabled.
(function assertProductionSafety() {
  if (process.env.NODE_ENV !== 'production') return;
  const fatal: string[] = [];
  if (!process.env.JWT_SECRET || process.env.JWT_SECRET === 'dev-only-change-me') {
    fatal.push('JWT_SECRET is missing or set to the known dev default — anyone can connect as any user');
  }
  if (process.env.AUTH_DEV_BYPASS === '1') {
    fatal.push('AUTH_DEV_BYPASS=1 is an API-side switch but must never be set in a production env');
  }
  // New in S03: device-session revocation is authoritative in Postgres, not in Redis. Without
  // this the relay would answer every connect with 4503 and carry no traffic at all — better
  // to say why at boot than to look like a total outage with a healthy-looking process.
  if (!process.env.DATABASE_URL) {
    fatal.push('DATABASE_URL is missing — the relay verifies device sessions against it on connect');
  }
  if (fatal.length) {
    console.error('[voiid:ws] REFUSING TO START in production:\n - ' + fatal.join('\n - '));
    process.exit(1);
  }
})();

// socket_map: user_id -> set of live sockets on THIS instance.
const socketMap = new Map<string, Set<WebSocket>>();

// Which device each socket belongs to, so a sign-out can name ONE of a user's devices.
// A WeakMap because the entry must die with the socket: keeping a device id alive in a
// Map keyed by socket would retain every connection this process ever accepted.
// Undefined for a legacy unbound credential, which no device-targeted frame can single out.
const socketDevice = new WeakMap<WebSocket, string | undefined>();

// Subscriber connection: one shared sub, pattern-subscribe to user channels routed here.
const sub = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379');
const presence = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379');
// Publisher for typing/presence fan-out originating from WS frames.
const pub = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379');

// --- Pending call-offer buffer ------------------------------------------------------
// Redis pub/sub is fire-and-forget: an offer published while the callee holds no live
// socket is gone for good. Since ringing happens out-of-band (VoIP/FCM push), the callee
// routinely wakes AFTER the offer was published and would otherwise sit on "Connecting"
// forever. We park the offer in a short-lived per-user hash (call_id -> frame) and flush
// it the moment that user's socket attaches.
//
// TTL is deliberately tight: an offer older than this is a call nobody is still waiting
// on, and SDP (which carries host IPs) should not linger.
const OFFER_BUFFER_TTL = Number(process.env.VOIID_CALL_OFFER_TTL_SECONDS) || 60;
const offersKey = (userId: string) => `call:offers:${userId}`;

// Trickle ICE needs the same buffer, and losing it fails WORSE than losing the offer.
// Because the offer is trickle it carries no candidates of its own, so a push-woken callee
// that receives the buffered offer but none of the caller's candidates is left relying on
// peer-reflexive discovery — which stalls or fails outright behind symmetric NAT and on
// TURN-only networks. That is the "rings, accepts, never connects" shape on Android when
// the process was killed.
//
// A LIST per (recipient, call) rather than a JSON array inside the per-user offers hash:
// candidates arrive as a burst of independent frames, and read-modify-write on a single
// hash field silently loses one whenever two of them interleave. RPUSH is atomic, so it
// cannot. Same TTL and same resolution-time cleanup as the offer it belongs to.
const iceKey = (userId: string, callId: string) => `call:ice:${userId}:${callId}`;
// Bounded so the relay can never be parked full of arbitrary data. A real session trickles
// well under this; the trim drops the OLDEST because host candidates gather first and
// relay/srflx ones — the candidates that actually work behind symmetric NAT — arrive last.
const ICE_BUFFER_MAX = 64;

// ─────────────────────────────────────────────────────────────────────────────────
// CALL SIGNALING AUTHORIZATION
//
// This relay authenticates the SENDER (the JWT proves who they are) but until now checked
// nothing about the RECIPIENT: a `call_offer` naming any `to_user_id` was forwarded, so an
// authenticated user could ring anyone whose user_id they knew — bypassing the reachability
// gate 020 built for messages. The comment on `loc_update` ("the receiving client must
// discard unauthorized frames — that check is the real authorization") does NOT hold here,
// because the call clients ring for any offer rather than rejecting unknown callers.
//
// This service holds NO database connection on purpose — it is stateless fan-out over Redis.
// So the authorization decision is made in the API (POST /calls/ring, which has the database
// and runs the conversation-membership query) and deposited in Redis as a short-lived grant
// naming the two permitted parties. Here we only VERIFY it.
//
// Fail-closed: no grant means no relay. The cost of a false negative is one dropped call
// frame on an expired grant; the cost of a false positive is the hole this closes.
// ─────────────────────────────────────────────────────────────────────────────────
const ringGrantKey = (callId: string) => `callgrant:${callId}`;

/** True when `from`/`to` are exactly the pair the API authorized for this call. */
async function callPairAuthorized(callId: string, from: string, to: string): Promise<boolean> {
  try { return callGrantAllows(await pub.get(ringGrantKey(callId)), from, to); }
  catch { return false; }
}
// Per-user buffer of "this call was taken on another of your devices" verdicts. Same
// lifetime as the offer buffer, and cleared the same two ways (the offer's resolution
// hdel, or TTL). Exists because the verdict must reach a sibling device that was woken
// by a VoIP push but has not yet attached its socket — over plain pub/sub it would be
// lost, and that sibling would post a FALSE missed-call notification for a call the
// account actually answered.
const takenKey = (userId: string) => `call:taken:${userId}`;

// --- Live location relay ------------------------------------------------------------
// Position fixes are ENCRYPTED ON THE SENDER'S DEVICE under a share key this process has
// never seen (it is distributed to the audience inside an E2EE control message on the
// message path) and arrive here as an opaque base64 blob. This relay copies that blob
// and stamps the authenticated sender — it never parses it, never stores it in Postgres,
// and, exactly like SDP/ICE above, MUST NOT be logged.
//
// WHY THE RELAY AND NOT THE MESSAGE PATH: a fix every 10s for 5 recipients x 2 devices is
// 3,600 wake pushes/hour to the RECIPIENTS' phones plus 1,800 permanent DB rows an hour,
// for data that is worthless the moment it is stale. So fixes ride the ephemeral relay
// and nothing else; only the durable start/stop control messages take the message path.
//
// SAME BUFFER PROBLEM AS CALL OFFERS, DIFFERENT ANSWER: Redis pub/sub has no persistence,
// so a fix published while the recipient's socket is down evaporates. We park the LATEST
// frame per share in a per-user hash. Two deliberate differences from the offer buffer:
//   * it holds the latest fix only, never a queue — replaying a trail of stale positions
//     is worse than showing nothing;
//   * the flush does NOT delete, because a user's SECOND device connecting needs it too
//     and re-delivering one idempotent latest fix is harmless. The TTL reaps it, and a
//     `loc_stop` hdels it so a stopped share can never be resurrected from the buffer.
const LOC_BUFFER_TTL = Number(process.env.VOIID_LOC_BUFFER_TTL_SECONDS) || 300;
const lastFixKey = (userId: string) => `loc:last:${userId}`;

// Per-socket, per-share token bucket for loc_update. The product cadence is one fix every
// 10-15s (~4-6/min); 12/min is generous headroom. Excess frames are DROPPED SILENTLY —
// a flooding stream is a bug or an attack, and dropping an ephemeral fix costs nothing
// (the next one supersedes it anyway). Without this the relay is an unmetered fan-out
// amplifier: one frame in, N publishes out.
const LOC_MAX_FRAMES_PER_WINDOW = 12;
const LOC_RATE_WINDOW_MS = 60_000;
// A fix is ~100-160 bytes of plaintext, so a few hundred bytes of base64. The cap keeps
// the relay from being repurposed as a bulk side-channel for arbitrary data.
const LOC_MAX_CIPHERTEXT_CHARS = 4096;
// STRUCTURAL opacity check: the payload must be base64 and nothing else. A JSON object
// with a plaintext `lat` in it cannot match this alphabet (no `{`, `"`, `:`, `.`, space),
// so a client that "helpfully" sends raw coordinates is rejected at the door rather than
// relayed. Cheap, and it means this process can never carry a readable position.
const LOC_B64_RE = /^[A-Za-z0-9+/=_-]+$/;
// A conversation share fans out to one conversation; the cap only bounds how much work a
// single frame can ask this process to do.
const LOC_MAX_RECIPIENTS = 512;

// --- Games relay --------------------------------------------------------------------
// Game input is FORWARDED, not fanned out: one publish to the games service, which owns
// the rules and answers on the players' own channels. See the handler for why this
// process stays ignorant of game rules.
const GAMES_INPUT_CHANNEL = 'channel:games:input';
// A COARSE FLOOD GUARD, NOT A PER-GAME LIMIT — and the difference is what broke Snake.
//
// This process cannot know which game a match is (no database, by design), so it cannot
// compute a per-game rate. backend/games can and does: see limitFor() there, which derives
// the real limit from the game's own tickHz. This number therefore only has to clear the
// FASTEST credible client with headroom, or it silently throttles a game it knows nothing
// about — which is exactly what it did.
//
// It was 120/min = 2/s, set when every game was turn-based and a handful of moves a minute
// was the whole story. Snake steers at 10-15/s. The budget was exhausted 8-12 seconds into
// every match, and because the window is fixed rather than sliding, the player then had
// ~50 seconds with NO steering and no respawn (that frame is a game_input too). The clients
// were tuned against the games service's 20/s limit and never saw this one in front of it.
//
// 1800/min = 30/s clears Snake with 2x headroom and leaves room for the 20-30 Hz games in
// GAMES.md §4 (Air Hockey, Ping Pong, Pool). See docs/GAMES_SNAKE_BUGS.md Part A.
const GAME_MAX_FRAMES_PER_WINDOW = Number(process.env.VOIID_GAME_WS_RATE) || 1800;

// --- Call signalling flood guard ------------------------------------------------------
// Location frames get 12/min and game frames 1800/min; call frames had NO limit at all,
// and each one costs several Redis operations plus a fan-out to every recipient device.
//
// Sized off what a real call actually sends. The expensive burst is ICE: trickle
// candidates arrive in a clump at setup and again on every ICE restart — a few dozen per
// negotiation, times up to 3 restarts, plus offer/answer and the hold/ringing/hangup
// frames. 600/min is roughly ten times that, so it cannot throttle a legitimate call even
// on a network that is renegotiating constantly, while still bounding a client that has
// come loose.
//
// Keyed per USER rather than per call: a client flooding across many call ids is the case
// a per-call bucket would miss entirely.
const CALL_MAX_FRAMES_PER_WINDOW = Number(process.env.VOIID_CALL_WS_RATE) || 600;
const CALL_RATE_WINDOW_MS = 60_000;
const GAME_RATE_WINDOW_MS = 60_000;
// A move is tiny (a cell index, an angle/power pair). Generous, but bounded.
const GAME_MAX_PAYLOAD_CHARS = 2048;

// --- The socket-wide budget (R02) -----------------------------------------------------
//
// Every limiter above is per-TYPE or per-KEY, and nothing counted the socket as a whole.
// `typing`, `session_reset`, `loc_stop` and `heartbeat` had no limit at all, so a client
// could spend indefinitely across them while staying under every ceiling that existed.
//
// Sized to clear the sum of the legitimate maxima with headroom: games alone are allowed
// 1800/min, calls 600/min, plus location and typing. 3000 frames/min cannot throttle an
// honest client doing all of those at once. The byte ceiling is the one that matters against
// a client that has come loose: `ws` accepts frames up to WS_MAX_PAYLOAD (256 KB), so without
// it a socket could push ~150 MB/min through this process at the frame limit.
const SOCKET_MAX_FRAMES_PER_WINDOW = Number(process.env.VOIID_WS_MAX_FRAMES_PER_MIN) || 3000;
const SOCKET_MAX_BYTES_PER_WINDOW = Number(process.env.VOIID_WS_MAX_BYTES_PER_MIN) || 16 * 1024 * 1024;
const SOCKET_RATE_WINDOW_MS = 60_000;

// Ceilings on the per-key limiter maps. Both were plain Maps keyed by a CLIENT-SUPPLIED id
// (share, match) and neither was capped or pruned, so a client could grow them for the life
// of the socket one invented id at a time. Sized well above any honest simultaneous count.
const LOC_RATE_MAX_KEYS = Number(process.env.VOIID_WS_MAX_SHARE_KEYS) || 64;
const GAME_RATE_MAX_KEYS = Number(process.env.VOIID_WS_MAX_MATCH_KEYS) || 64;

// Sockets one account may hold on THIS instance. A phone, a tablet, a web companion and
// some reconnect churn is a handful; hundreds is a client in a loop or someone using a
// stolen token to pin resources. The OLDEST is closed rather than the newest refused, so a
// reconnecting client always wins and a stale socket is what gets cleaned up.
const MAX_SOCKETS_PER_USER = Number(process.env.VOIID_WS_MAX_SOCKETS_PER_USER) || 8;

/**
 * Deliver any buffered latest-fix frames to a user whose socket just attached.
 *
 * Unlike flushPendingOffers this does NOT clear the buffer — see the note above. Frames
 * are opaque ciphertext; a share the recipient no longer knows about is dropped by the
 * client, which is where location relay authorization actually lives (this process has
 * no database and cannot check that a recipient is an authorized target).
 */
async function flushPendingLocation(userId: string, ws: WebSocket): Promise<void> {
  try {
    const buffered = await pub.hgetall(lastFixKey(userId));
    for (const frame of Object.values(buffered ?? {})) {
      const parsed = JSON.parse(frame);
      if (!(await shareRecipients(parsed.from_user_id, parsed.share_id)).includes(userId)) continue;
      if (ws.readyState === WebSocket.OPEN) boundedSend(ws, frame);
    }
  } catch {
    // A missed flush degrades to "the marker updates on the next fix", not a dropped socket.
  }
}

/**
 * Deliver (and clear) any offers parked for a user that just connected.
 *
 * Safe to replay: clients ignore a duplicate offer for a call they've already attached,
 * and an offer whose call has since been answered/hung up was deleted at that moment.
 */
async function flushPendingOffers(userId: string, ws: WebSocket): Promise<void> {
  try {
    const key = offersKey(userId);
    const pending = await pub.hgetall(key);
    const frames = Object.values(pending ?? {});
    if (!frames.length) return;
    // Deliberately do NOT delete the key here. An account can have several devices, and
    // EACH must ring — but a device is woken by its own VoIP push and attaches its socket
    // independently, so they connect at different moments. Draining the buffer on the
    // first connect (as this used to) left every other device silent. Instead we leave
    // the offer in place and let it be cleared by the call's resolution (the hdel on
    // answer/hangup/decline/busy) or by TTL. Re-delivery is safe: clients ignore a
    // duplicate offer for a call they have already attached (iOS: handleIncomingOffer).
    for (const frame of frames) {
      const parsed = JSON.parse(frame);
      if (parsed.type !== 'call_taken' && !(await callPairAuthorized(parsed.call_id, parsed.from_user_id, userId))) continue;
      if (ws.readyState === WebSocket.OPEN) boundedSend(ws, frame);
    }
    // The offer alone is not enough to connect — it is trickle, so it names no candidates.
    // The hash FIELDS are the call ids, which is exactly the set of calls this device can
    // still be ringing for, so they double as the lookup for the parked candidates.
    await flushPendingIce(userId, Object.keys(pending), ws);
  } catch {
    // Never let a Redis hiccup take down the connection — a missed flush degrades to
    // the pre-existing behaviour (caller times out), not a dropped socket.
  }
}

/**
 * Deliver the trickle-ICE candidates parked for calls whose offers were just flushed.
 *
 * Called from flushPendingOffers rather than from the connection handler so it is strictly
 * ordered AFTER the offer: both clients queue candidates that arrive before the remote
 * description (iOS/Android `pendingRemoteCandidates`), so leading with the offer is not
 * required for correctness, but it avoids making every push-woken call depend on that path.
 *
 * Non-draining for the same reason as the offer buffer: a second device on the account
 * attaches later and needs the same candidates. Re-delivery is safe — a duplicate
 * candidate is a no-op for the peer connection.
 */
async function flushPendingIce(userId: string, callIds: string[], ws: WebSocket): Promise<void> {
  for (const callId of callIds) {
    try {
      const frames = await pub.lrange(iceKey(userId, callId), 0, -1);
      for (const frame of frames) {
        const parsed = JSON.parse(frame);
        if (!(await callPairAuthorized(callId, parsed.from_user_id, userId))) continue;
        if (ws.readyState === WebSocket.OPEN) boundedSend(ws, frame);
      }
    } catch {
      // Degrades to peer-reflexive discovery — where this call was before the buffer
      // existed — rather than to a dropped socket. Keep going for the other calls.
    }
  }
}

/**
 * Deliver any "call taken on another device" verdicts parked for a user that just
 * connected. Same non-draining, replay-safe discipline as flushPendingOffers: several
 * siblings may each need the verdict, and a client that receives a call_taken for a call
 * it never knew about simply ignores it.
 */
async function flushPendingTaken(userId: string, ws: WebSocket): Promise<void> {
  try {
    const pending = await pub.hgetall(takenKey(userId));
    const frames = Object.values(pending ?? {});
    for (const frame of frames) {
      const parsed = JSON.parse(frame);
      if (parsed.type !== 'call_taken' && !(await callPairAuthorized(parsed.call_id, parsed.from_user_id, userId))) continue;
      if (ws.readyState === WebSocket.OPEN) boundedSend(ws, frame);
    }
  } catch {
    // A missed flush degrades to the pre-existing behaviour (a possible spurious
    // missed-call banner), never a dropped socket.
  }
}

sub.psubscribe('channel:user:*');
sub.on('pmessage', (_pattern, channel, payload) => {
  const userId = channel.replace('channel:user:', '');
  const sockets = socketMap.get(userId);
  if (!sockets) return; // socket lives on another instance; that instance delivers it

  // `force_signout` is a CONTROL frame, not something to relay: the API publishes it when an
  // account is deleted. The connect-time revocation check only guards NEW sockets, so without
  // this a user who is already connected keeps their live session — on the service carrying
  // the traffic — until they happen to reconnect. Deliver it (so the client can clear local
  // state and show why) and then close.
  let signout: { device_id?: string; reason?: string } | null = null;
  try {
    const frame = JSON.parse(payload);
    if (frame?.type === 'force_signout') signout = frame;
  } catch { /* not JSON: relay it */ }

  // A device-scoped sign-out (logout, revoke, superseded) names its device and must reach
  // ONLY that device's sockets. Account deletion names none and still closes everything.
  // Getting this wrong in the permissive direction would sign a user out of their other
  // phone every time they logged out of one — so an unidentified socket is never closed by
  // a targeted frame, and never shown one either.
  const targeted = signout?.device_id;
  const affected = targeted
    ? [...sockets].filter((ws) => socketDevice.get(ws) === targeted)
    : [...sockets];

  for (const ws of affected) {
    if (ws.readyState === WebSocket.OPEN) boundedSend(ws, payload);
  }
  if (signout) {
    for (const ws of affected) {
      if (ws.readyState === WebSocket.OPEN) ws.close(WS_CLOSE_REVOKED, signout.reason ?? 'account deleted');
    }
    for (const ws of affected) sockets.delete(ws);
    if (!sockets.size) socketMap.delete(userId);
  }
});

// A HARD CEILING ON ANY SINGLE FRAME.
//
// There was none, so `ws` accepted a frame of any size. SDP and ICE candidates relay
// VERBATIM — the relay deliberately does not parse them — so a client could hand this
// process an arbitrarily large string and have it buffered, published to Redis and fanned
// out to every recipient device.
//
// 256 KB is far above any real signalling frame (a large SDP with many codecs and
// candidates runs a few tens of KB) and far below anything that threatens the process.
// `ws` closes the connection itself when a frame exceeds this, which is the right outcome:
// nothing legitimate produces one.
const WS_MAX_PAYLOAD_BYTES = Number(process.env.VOIID_WS_MAX_PAYLOAD) || 256 * 1024;

const wss = new WebSocketServer({ port, maxPayload: WS_MAX_PAYLOAD_BYTES });

// The relay shares its existing Redis connection with the session and recipient lookups
// rather than opening more; Postgres is consulted only on a cache miss.
useSessionCache(presence);
useRecipientCache(presence);

wss.on('connection', async (ws, req) => {
  // PAUSED FOR THE DURATION OF THE AUTH ROUND-TRIP.
  //
  // The session check below is awaited, so this handler yields to the event loop before the
  // 'message' listener is attached. A client that sends immediately on open — a heartbeat, a
  // game input, a call frame — would have that frame parsed and emitted to nobody, and
  // silently dropped. `pause()` holds the bytes in the socket's own buffer until `resume()`
  // at the end of this handler, by which time every listener is registered. The previous
  // code needed none of this because it attached listeners in the same tick.
  ws.pause();
  ws.on('error', () => ws.terminate());
  const authDeadline = setTimeout(() => ws.terminate(), 10_000);
  ws.once('close', () => clearTimeout(authDeadline));

  // JWT via ?token=; reject if absent, unverifiable, or naming a revoked session.
  const url = new URL(req.url ?? '', 'http://localhost');
  let token = req.headers.authorization?.replace(/^Bearer /i, '') ?? url.searchParams.get('token');
  const ticket = url.searchParams.get('ticket');
  const webOrigin = process.env.VOIID_WEB_ORIGIN;
  if (ticket) {
    try { token = await redeemWebTicket(ticket, req.headers.origin, webOrigin, pub); }
    catch { ws.close(4503, 'service unavailable'); ws.resume(); return; }
  }
  req.url = url.pathname; // Do not retain URL credentials for service access logging.

  // AWAITED BEFORE THE SOCKET IS REGISTERED. The previous check was a floating promise: the
  // socket joined socketMap and began receiving traffic immediately, and the close (if any)
  // landed a round-trip later. A revoked client got a window of live relay access on every
  // connect, which is exactly the access this is meant to deny.
  const auth = await authorizeConnection(token);
  clearTimeout(authDeadline);
  if (!auth.ok) {
    ws.close(auth.code, auth.reason);
    ws.resume();
    return;
  }
  if (auth.client === 'web' && (!ticket || req.headers.origin !== webOrigin)) { ws.close(4401, 'unauthorized'); ws.resume(); return; }
  const userId = auth.userId;

  // The client may have closed or the server shut down during the round-trip above.
  if (ws.readyState !== WebSocket.OPEN) return;

  const leaseId = randomUUID();
  const lease = (action: string) => presence.eval(PRESENCE_SCRIPT, 3,
    `user:${userId}:leases`, `user:${userId}:online`, `user:${userId}:last_seen`,
    leaseId, action, 60_000, MAX_SOCKETS_PER_USER);
  try {
    if (await lease('add') !== 1) { ws.close(4429, 'too many connections'); ws.resume(); return; }
  } catch { ws.close(4503, 'service unavailable'); ws.resume(); return; }
  if (ws.readyState !== WebSocket.OPEN) { await lease('remove').catch(() => {}); return; }
  let alive = true;
  let checking = false;
  ws.on('pong', () => { alive = true; });
  const heartbeat = setInterval(async () => {
    if (checking) return;
    if (!alive || Date.now() >= auth.expiresAt) { ws.terminate(); return; }
    alive = false;
    ws.ping();
    checking = true;
    try {
      const current = await authorizeConnection(token);
      if (!current.ok || ws.readyState !== WebSocket.OPEN) { ws.terminate(); return; }
      if (await lease('renew') !== 1) ws.terminate();
    } catch { ws.terminate(); }
    finally { checking = false; }
  }, 20_000);
  const expire = setTimeout(() => ws.terminate(), Math.min(2_147_483_647, Math.max(1, auth.expiresAt - Date.now())));
  ws.once('close', () => {
    clearInterval(heartbeat);
    clearTimeout(expire);
    void lease('remove').catch(() => {});
  });
  socketDevice.set(ws, auth.deviceId);
  if (!socketMap.has(userId)) socketMap.set(userId, new Set());
  const userSockets = socketMap.get(userId)!;

  // Close the oldest rather than refuse the newest: a client reconnecting after a network
  // change must always get in, and the socket most likely to be dead is the one that has
  // been open longest. Set iteration is insertion order, so the first entry is the oldest.
  while (userSockets.size >= MAX_SOCKETS_PER_USER) {
    const oldest = userSockets.values().next().value as WebSocket | undefined;
    if (!oldest) break;
    userSockets.delete(oldest);
    if (oldest.readyState === WebSocket.OPEN) oldest.close(4429, 'too many connections');
  }
  userSockets.add(ws);

  // presence: user online with heartbeat TTL. Also stamp last_seen now, and on
  // every heartbeat, so "last seen" stays fresh even on an UNCLEAN disconnect
  // (app killed / network drop) — the close handler can't be relied on for that.


  // A socket attaching is the ONLY moment a push-woken callee can receive the offer it
  // slept through. Do it before anything else so the answer path isn't left waiting.
  void flushPendingOffers(userId, ws);
  // And any "already taken on your other device" verdict, so a push-woken sibling cancels
  // its ring / missed-call banner instead of firing a false notification.
  void flushPendingTaken(userId, ws);
  // Same reasoning for live location: a recipient woken by a message push attaches after
  // the fix was published, and would otherwise show nothing until the sender's next one.
  void flushPendingLocation(userId, ws);

  // loc_update rate state for THIS socket, keyed by share_id. Socket-local so it dies
  // with the connection — no cross-socket map to leak.
  const locRate = new BoundedRateMap({
    max: LOC_RATE_MAX_KEYS, limit: LOC_MAX_FRAMES_PER_WINDOW, windowMs: LOC_RATE_WINDOW_MS,
  });

  // game_input rate state for THIS socket, keyed by match_id. Socket-local for the same
  // reason as locRate — it dies with the connection, so there is no cross-socket map to
  // leak or to clean up.
  // Per CONNECTION, not module-level: a map keyed by user id at module scope would retain
  // an entry for every user who ever connected, for the life of the process. Scoped here it
  // dies with the socket, and a client reconnecting to dodge the limit has to pay a new TLS
  // handshake and auth for each attempt — which is its own throttle.
  const callRate = new Map<string, { count: number; windowStart: number; warned: boolean }>();

  const gameRate = new BoundedRateMap({
    max: GAME_RATE_MAX_KEYS, limit: GAME_MAX_FRAMES_PER_WINDOW, windowMs: GAME_RATE_WINDOW_MS,
  });

  // ONE BUDGET FOR THE WHOLE SOCKET, checked before parsing or any Redis call. See the
  // constants for why the per-type limits above were not enough on their own.
  const socketBudget = new SocketBudget({
    frames: SOCKET_MAX_FRAMES_PER_WINDOW,
    bytes: SOCKET_MAX_BYTES_PER_WINDOW,
    windowMs: SOCKET_RATE_WINDOW_MS,
  });

  ws.on('message', async (raw) => {
    // BEFORE ANYTHING ELSE, including the JSON parse: a frame that is over budget must not
    // cost this process a parse, a database lookup or a Redis round-trip. Silent drop, for
    // the same reason the location limiter drops silently — a client flooding is a bug or an
    // attack, and answering it is just more work.
    const size = Buffer.isBuffer(raw) ? raw.length
      : Array.isArray(raw) ? raw.reduce((n, part) => n + part.length, 0)
      : Buffer.byteLength(String(raw));
    if (!socketBudget.admit(size) || ws.readyState !== WebSocket.OPEN || Date.now() >= auth.expiresAt) return;
    try {
      if (await presence.eval(FRAME_BUDGET_SCRIPT, 1, `relay:budget:${userId}`, size,
          SOCKET_MAX_FRAMES_PER_WINDOW, SOCKET_MAX_BYTES_PER_WINDOW, SOCKET_RATE_WINDOW_MS) !== 1) return;
    } catch { ws.terminate(); return; }

    // Realtime control frames: heartbeat (presence) and typing (Section 10 Redis keys).
    try {
      const msg = JSON.parse(raw.toString());

      if (auth.client === 'web' && !['heartbeat', 'typing'].includes(msg.type)) return;
      if (msg.type === 'heartbeat') {
        // Server ping/pong owns the lease; client heartbeats cannot keep a stale session alive.
        return;
      }

      // typing: { type:'typing', conversation_id, state:'start'|'stop' }
      //
      // THE RECIPIENTS ARE DERIVED, NOT SUPPLIED. This used to take `recipient_ids` from the
      // frame and publish to whatever it named, because the relay had no database — so any
      // authenticated client could push a typing indicator at any user, in any conversation
      // id it cared to guess. S03 gave this process a database; recipients.ts uses it.
      //
      // A `recipient_ids` array is still honoured if present, but only to NARROW the derived
      // audience — a client may address fewer people than it is entitled to, never more.
      // Blocking is applied inside the same query rather than through the `block:a:b` mirror,
      // so it is answered by the same authority that answers membership.
      if (msg.type === 'typing' && msg.conversation_id) {
        const audience = await conversationRecipients(userId, msg.conversation_id);
        if (!audience.length) return;

        const typingKey = `conversation:${msg.conversation_id}:typing:${userId}`;
        if (msg.state === 'stop') {
          presence.del(typingKey);
        } else {
          presence.set(typingKey, '1', 'EX', 5); // TTL 5s per Section 10
        }
        const out = JSON.stringify({
          type: 'typing',
          conversation_id: msg.conversation_id,
          user_id: userId,
          state: msg.state === 'stop' ? 'stop' : 'start',
        });
        for (const rid of narrow(audience, msg.recipient_ids)) {
          pub.publish(`channel:user:${rid}`, out);
        }
        return;
      }

      // --- Live location relay ----------------------------------------------------
      // loc_update: { type:'loc_update', share_id, recipient_ids:[...], ciphertext(b64) }
      // loc_stop:   { type:'loc_stop',   share_id, recipient_ids:[...] }
      //
      // `ciphertext` is opaque: encrypted on-device under a share key that never reaches
      // any server, copied verbatim, never parsed, never logged. The client supplies
      // recipient_ids because this process has no database — identical to `typing`.
      //
      // SECURITY, STATED PLAINLY: sender identity is authoritative (stamped from the JWT,
      // never echoed from the frame), but this process CANNOT verify that a recipient is
      // an authorized target of that share — it has no DB. Membership is enforced once,
      // at POST /location/shares. A malicious client can therefore relay loc_update frames
      // at arbitrary users and gains nothing: the payload is encrypted under a key those
      // users do not hold. THE RECEIVING CLIENT MUST DISCARD ANY loc_update WHOSE share_id
      // IS NOT IN ITS LOCAL INBOUND-SHARE TABLE. That check is the real authorization.
      if (
        (msg.type === 'loc_update' || msg.type === 'loc_stop') &&
        typeof msg.share_id === 'string'
      ) {
        // DERIVED FROM THE SHARE, not from the frame. A share id is not a capability: this
        // resolves only for the share's OWNER, and only to targets that are still live —
        // not revoked, not expired, not ended, not blocked.
        //
        // That is what makes an invented share id inert rather than merely rate-limited. The
        // old code relayed to whatever `recipient_ids` named and then wrote the frame into
        // each recipient's buffer with `hset`, so a stranger could put entries into another
        // user's location buffer and remove them again with `loc_stop`. Both now resolve to
        // an empty audience and do nothing at all.
        const audience = await shareRecipients(userId, msg.share_id);
        if (!audience.length) {
          // Nothing to do, and nothing to say: a client that has just had a share revoked
          // looks exactly like one probing for share ids.
          if (msg.type === 'loc_stop') locRate.delete(msg.share_id);
          return;
        }
        const recipients = narrow(audience, msg.recipient_ids).slice(0, LOC_MAX_RECIPIENTS);

        if (msg.type === 'loc_update') {
          // Opaque-payload gate: base64 only, bounded length. A raw-coordinate JSON body
          // fails the alphabet test and is dropped instead of relayed.
          if (
            typeof msg.ciphertext !== 'string' ||
            msg.ciphertext.length === 0 ||
            msg.ciphertext.length > LOC_MAX_CIPHERTEXT_CHARS ||
            !LOC_B64_RE.test(msg.ciphertext)
          ) {
            return;
          }
          // Token bucket per share, per socket. Silent drop by design. Bounded now (see
          // budget.ts): the key is client-supplied, so the map it lives in must have a ceiling.
          if (!locRate.admit(msg.share_id)) return;
        }

        // Rebuild from a fixed field list — client extras are never echoed.
        const out = JSON.stringify(
          msg.type === 'loc_update'
            ? {
                type: 'loc_update',
                share_id: msg.share_id,
                from_user_id: userId, // authoritative sender (never client-supplied)
                ciphertext: msg.ciphertext, // opaque; never parsed, never logged
                ts: Date.now(),
              }
            : {
                type: 'loc_stop',
                share_id: msg.share_id,
                from_user_id: userId,
                ts: Date.now(),
              }
        );

        for (const rid of recipients) {
          // The derived audience already excludes the sender and anything non-string; kept
          // as a cheap assertion rather than a load-bearing filter.
          if (typeof rid !== 'string' || rid === userId) continue;
          pub.publish(`channel:user:${rid}`, out);
          const key = lastFixKey(rid);
          if (msg.type === 'loc_update') {
            // Latest-only: hset overwrites the previous fix for this share rather than
            // appending, so the buffer can never become a position history.
            pub.hset(key, msg.share_id, out);
            pub.expire(key, LOC_BUFFER_TTL);
          } else {
            // A stopped share must not be resurrectable from the buffer on reconnect.
            pub.hdel(key, msg.share_id);
          }
        }
        if (msg.type === 'loc_stop') locRate.delete(msg.share_id);
        return;
      }

      // --- Games input relay ------------------------------------------------------
      // game_input: { type:'game_input', match_id, payload }
      //
      // WHY THIS FORWARDS INSTEAD OF ANSWERING: this process stays a dumb pipe. It does
      // not know the rules of any game, does not hold match state, and has no database —
      // the same constraints that make it forward location and SDP untouched. It hands
      // the frame to backend/games on a single Redis channel and that service, which owns
      // the rules, publishes the resulting `game_state` back to each player on their
      // ordinary `channel:user:<id>`. So game state reaches clients through the exact
      // path a chat message does, and needs no new client connection.
      //
      // SECURITY, SAME RULE AS EVERYWHERE ELSE HERE: `from_user_id` is stamped from THIS
      // socket's JWT and any client-supplied value is discarded, so a player cannot
      // submit a move as somebody else. Whether that user is actually in the match, and
      // whether the move is legal, are decided by backend/games — which unlike this
      // process has the state to answer both.
      //
      // NOT ENCRYPTED, DELIBERATELY: `payload` is readable game state, because the server
      // is the referee and must read moves to validate them. That is a documented
      // exception scoped to games (docs/GAMES.md §2) — it is NOT a precedent for the
      // message path, whose payloads remain opaque to this relay.
      if (msg.type === 'game_input' && typeof msg.match_id === 'string') {
        // Bounded work per frame: a move is a few dozen bytes. The cap stops the games
        // channel being repurposed as a bulk side-channel.
        const encoded = JSON.stringify(msg.payload ?? {});
        if (encoded.length > GAME_MAX_PAYLOAD_CHARS) return;

        // Token bucket per match per socket — identical posture to loc_update above:
        // silent drop, no error frame, because answering a flood with traffic is how one
        // bad client becomes an amplifier.
        //
        // Silent to the CLIENT, but no longer silent to us. When this limit throttled Snake
        // it was invisible from both ends: the phone saw its frames vanish and the games
        // service simply never heard from the player. One line per match on the first drop
        // is what turns that into a nameable failure, and it cannot become a log flood
        // because it fires once per bucket.
        if (!gameRate.admit(msg.match_id)) {
          if (gameRate.warnOnce(msg.match_id)) {
            console.warn(
              `[ws] game_input rate limit hit: match=${msg.match_id} user=${userId} ` +
                `limit=${GAME_MAX_FRAMES_PER_WINDOW}/${GAME_RATE_WINDOW_MS}ms — ` +
                `dropping until the window rolls`
            );
          }
          return;
        }

        // Rebuilt from a fixed field list — client extras are never forwarded.
        pub.publish(
          GAMES_INPUT_CHANNEL,
          JSON.stringify({
            type: 'game_input',
            match_id: msg.match_id,
            from_user_id: userId, // authoritative sender (never client-supplied)
            payload: msg.payload ?? {},
          })
        );
        return;
      }

      // --- Call signaling relay (voice/video) ------------------------------------
      // WebRTC signaling is a thin, ephemeral relay: the server forwards opaque SDP
      // and ICE candidates between the two peers and never inspects, stores, or logs
      // them. Call MEDIA and SRTP keys are E2E on the devices (derived in e2e-core);
      // the server sees signaling only. Every frame targets a single `to_user_id`
      // whose devices we reach via their Redis channel — identical fan-out to typing.
      //
      // SECURITY: the sender identity is ALWAYS the JWT-authenticated `userId` of
      // THIS socket, stamped server-side as `from_user_id`. Any client-supplied
      // `from`/`from_user_id` is ignored — a caller cannot spoof another user.
      //
      // NOTE: sdp/candidate can carry host IPs; they are relayed verbatim but MUST
      // NOT be logged (no info-level logging of these frames anywhere here).
      //
      // ONE EXCEPTION to "never stored": `call_offer`, and the `call_ice` candidates
      // that belong to it, are buffered in Redis for OFFER_BUFFER_TTL seconds (see
      // below). Redis pub/sub has no persistence, so a frame published while the callee
      // has no live socket is dropped forever — the callee then wakes from a VoIP push,
      // answers, and waits for an offer that no longer exists (stuck on "Connecting"),
      // or gets the offer but none of the candidates and never completes ICE. The
      // buffer is deleted the moment the call resolves, and never holds SRTP keys or any
      // message content.
      // `call_ringing` is what lets the CALLER hear a ringback tone. The tone itself
      // is played locally on the caller's device (server-generated ringback would mean
      // streaming audio, which is wrong for a P2P/E2EE app) — this frame only tells the
      // caller "their device is actually alerting now", so ringback starts at the
      // truthful moment rather than the instant we sent the offer.
      //
      // `call_hold`/`call_unhold` carry call-waiting state so the peer can show
      // "on hold" and stop sending media while held.
      if (
        (msg.type === 'call_offer' ||
          msg.type === 'call_answer' ||
          msg.type === 'call_ice' ||
          msg.type === 'call_hangup' ||
          msg.type === 'call_busy' ||
          msg.type === 'call_decline' ||
          msg.type === 'call_ringing' ||
          msg.type === 'call_hold' ||
          msg.type === 'call_unhold' ||
          // ── THE CONFERENCE FOUR ──────────────────────────────────────────────
          // Both clients send these and both LISTEN for them (iOS
          // WebSocketClient.swift:461-476, Android WebSocketClient.kt:350-353), and
          // none of them was on this list — so every one was dropped in silence,
          // because the relay forwards only types it recognises and ignores the rest.
          //
          // That single omission is why conference calling did not work:
          //   * ACCEPT never reached the inviter, so their roster never updated;
          //   * DECLINE never reached them either, so a refused invite looked exactly
          //     like one still ringing, forever;
          //   * MIGRATE never arrived, so the original peer never moved to the SFU and
          //     the engine timed out and abandoned the upgrade;
          //   * INVITE only worked when it happened to arrive over the push path,
          //     which is why this appeared to work with the app backgrounded and not
          //     in the foreground.
          msg.type === 'call_invite' ||
          msg.type === 'call_invite_accept' ||
          msg.type === 'call_invite_decline' ||
          msg.type === 'call_migrate' ||
          msg.type === 'call_key') &&
        typeof msg.to_user_id === 'string' &&
        typeof msg.call_id === 'string'
      ) {
        // FLOOD GUARD. Every frame below costs several Redis operations plus a fan-out
        // to each of the recipient's devices, and this branch had no limit of any kind
        // while location and game frames both did. Keyed per user, so a client spraying
        // across many call ids is caught too. See CALL_MAX_FRAMES_PER_WINDOW for sizing.
        //
        // Silent to the client — a rate-limit reply would tell a prober something — but
        // logged once per window so a real throttle is nameable rather than invisible.
        {
          const now = Date.now();
          const bucket = callRate.get(userId);
          if (!bucket || now - bucket.windowStart >= CALL_RATE_WINDOW_MS) {
            callRate.set(userId, { count: 1, windowStart: now, warned: false });
          } else if (bucket.count >= CALL_MAX_FRAMES_PER_WINDOW) {
            if (!bucket.warned) {
              bucket.warned = true;
              console.warn(
                `[ws] call frame rate limit hit: user=${userId} ` +
                  `limit=${CALL_MAX_FRAMES_PER_WINDOW}/${CALL_RATE_WINDOW_MS}ms — ` +
                  `dropping until the window rolls`
              );
            }
            return;
          } else {
            bucket.count += 1;
          }
        }

        // Rebuild the outbound frame from KNOWN fields only (never echo client
        // extras) and stamp the authenticated sender. Undefined fields are dropped
        // by JSON.stringify, so e.g. a hangup without `reason` simply omits it.
        const keyCopies = msg.type === 'call_key' ? callKeyCopies(msg) : undefined;
        if (msg.type === 'call_key' && (!keyCopies || !auth.deviceId)) return;
        const out = JSON.stringify({
          type: msg.type,
          call_id: msg.call_id,
          from_user_id: userId, // authoritative sender (never client-supplied)
          conversation_id: msg.conversation_id,
          call_kind: msg.call_kind, // 'voice' | 'video' (call_offer)
          sdp: msg.sdp, // opaque; call_offer / call_answer
          candidate: msg.candidate, // opaque; call_ice (trickle)
          reason: msg.reason, // optional; call_hangup
          // The SFU room for call_invite / call_migrate. Rebuilding the frame from a
          // fixed field list is deliberate (never echo client extras) — but `room` was
          // missing from that list, so even once the types above are allowed the
          // invitee would be told a conference exists and given no way to enter it.
          room: msg.room,
          other_user_id: msg.other_user_id,
          ciphertexts: keyCopies,
          sender_device_id: msg.type === 'call_key' ? auth.deviceId : undefined,
        });
        // Deliver to the callee's devices (never echo back to the sender).
        if (msg.to_user_id !== userId) {
          // AUTHORIZATION GATE — see callPairAuthorized() above. Async, so this whole
          // delivery is deferred into a promise chain rather than making the outer message
          // handler async (which would change frame ordering for every other message type).
          // Frames for one call still land in order because they await the same key.
          const toUserId = msg.to_user_id as string;
          await callPairAuthorized(msg.call_id as string, userId, toUserId).then(async (allowed) => {
            if (!allowed || ws.readyState !== WebSocket.OPEN || Date.now() >= auth.expiresAt) {
              // Fail closed and say nothing useful back: a caller probing which user_ids are
              // reachable must not learn the difference between "not authorized" and
              // "authorized but offline".
              return;
            }
            // Device arbitration applies only to a 1:1 grant, never to conference participants.
            const grant = JSON.parse((await pub.get(ringGrantKey(msg.call_id))) ?? 'null');
            if (!grant || !callGrantAllows(JSON.stringify(grant), userId, toUserId)) return;
            if (grant.v !== 2 && ['call_offer', 'call_answer', 'call_ice', 'call_decline', 'call_hangup', 'call_busy'].includes(msg.type)) {
              const claim = await pub.eval(CALL_DEVICE_CLAIM_SCRIPT, 2,
                `call:device:${msg.call_id}:${userId}`, `call:device:${msg.call_id}:${toUserId}`, auth.deviceId ?? 'legacy', msg.type,
                7200, msg.reason ?? '') as [number, string, string];
              if (Number(claim[0]) !== 1) {
                if (claim[2] === 'answer' || claim[2] === 'decline') boundedSend(ws, JSON.stringify({
                  type: 'call_taken', call_id: msg.call_id, from_user_id: userId,
                  reason: claim[2], winner_device_id: claim[1],
                }));
                return;
              }
            }
            if (keyCopies && auth.deviceId) {
              for (const frame of callKeyDeliveryFrames(msg.call_id, userId, auth.deviceId, keyCopies)) {
                pub.publish(`channel:user:${toUserId}`, frame);
              }
            } else {
              pub.publish(`channel:user:${toUserId}`, out);
            }

          // Buffer the offer so a callee whose socket is down (backgrounded/killed,
          // about to be woken by the VoIP push) can still get it. We CANNOT decide
          // "is the callee live?" from publish()'s return value: every WS instance
          // psubscribes to `channel:user:*`, so that count is the number of INSTANCES,
          // not of that user's sockets. So buffer unconditionally and let the flush
          // on connect be idempotent — the clients already ignore a duplicate offer
          // for a call they've attached (iOS: handleIncomingOffer).
          if (msg.type === 'call_offer') {
            const key = offersKey(msg.to_user_id);
            pub.hset(key, msg.call_id, out);
            pub.expire(key, OFFER_BUFFER_TTL);
          }
          // Park the caller's candidates alongside that offer, for exactly as long as the
          // offer is parked. The `hexists` gate is what keeps this purposeful: candidates
          // are only worth holding for a call whose offer is still waiting to be collected
          // (a callee mid-wake), and once the call resolves the offer is hdel'd — so this
          // stops buffering at the same instant rather than holding candidates for a call
          // that is already up or already dead.
          if (msg.type === 'call_ice') {
            const callId = msg.call_id as string;
            void pub
              .hexists(offersKey(toUserId), callId)
              .then((parked) => {
                if (!parked) return;
                const key = iceKey(toUserId, callId);
                pub.rpush(key, out);
                pub.ltrim(key, -ICE_BUFFER_MAX, -1);
                pub.expire(key, OFFER_BUFFER_TTL);
              })
              .catch(() => {
                // Unbuffered is the pre-existing behaviour; never surface as a rejection.
              });
          }
          // The call resolved (or died) — drop any buffered offer immediately rather
          // than letting it sit out its TTL and re-ring a settled call on reconnect.
          if (
            msg.type === 'call_answer' ||
            msg.type === 'call_hangup' ||
            msg.type === 'call_decline' ||
            msg.type === 'call_busy'
          ) {
            // Clear BOTH directions. An answer/decline/busy comes from the callee, so
            // the buffered offer sits under the sender's key — but a hangup can come
            // from EITHER side, and a caller who cancels before the callee wakes must
            // not leave a live offer in the buffer. If it survived, the callee would
            // connect within the TTL and get a phantom ring for a call that was already
            // cancelled. Only one of these keys can hold this call_id, so deleting both
            // is free.
            pub.hdel(offersKey(userId), msg.call_id);
            pub.hdel(offersKey(msg.to_user_id), msg.call_id);
            // Candidates carry host IPs just like the SDP does, so they die with the offer
            // and in both directions for the same reason.
            pub.del(iceKey(userId, msg.call_id), iceKey(msg.to_user_id, msg.call_id));

            // …and tell the sender's OWN other devices that this call is settled.
            //
            // Call frames are relayed only to the far side, so a user with two
            // devices had no way to learn that the call they are both ringing for
            // was taken on the other one: the sibling kept ringing until the CALLER
            // eventually hung up, and (with client-side missed-call notifications)
            // then claimed the user had missed a call they actually answered. The
            // sender's own socket also receives this; clients ignore it for the call
            // they themselves resolved.
            //
            // Only for the CALLEE's verdict (answer/decline/busy). A `call_hangup` can
            // come from either side and never means "a sibling took the ringing call".
            if (msg.type !== 'call_hangup') {
              // Preserve the real cause. `busy` is NOT `decline`: it means one of the
              // user's devices was already on a call, not that they refused this one —
              // and the sibling's missed-call logic may treat those differently.
              const reason =
                msg.type === 'call_answer' ? 'answer'
                : msg.type === 'call_busy' ? 'busy'
                : 'decline';
              const takenFrame = JSON.stringify({
                type: 'call_taken',
                call_id: msg.call_id,
                from_user_id: userId,
                reason,
                winner_device_id: auth.deviceId,
              });
              // Live siblings hear it immediately…
              pub.publish(`channel:user:${userId}`, takenFrame);
              // …and one still asleep (VoIP-pushed, not yet connected) gets it on attach,
              // so it cancels its ring/banner instead of reporting a false missed call.
              // Keyed by call_id so a later resolution of the SAME call overwrites rather
              // than duplicates; cleared by TTL.
              pub.hset(takenKey(userId), msg.call_id, takenFrame);
              pub.expire(takenKey(userId), OFFER_BUFFER_TTL);
            }
          }
          });
        }
        return;
      }

      // session_reset: a recipient couldn't decrypt our message (stale/mismatched
      // E2E session, e.g. after a reinstall). Relay to the original sender so they
      // drop the stale session and re-establish a fresh one on the next message.
      // { type:'session_reset', conversation_id, recipient_ids:[senderUserId] }
      if (msg.type === 'session_reset' && msg.conversation_id) {
        // Same rule as typing: derived audience, and the client's list may only narrow it.
        // Narrowing matters more here than it does for typing — the frame is meant for ONE
        // person, the original sender, and telling a whole group to tear down their sessions
        // would cause a burst of unnecessary re-establishment. Unauthorised ids simply fall
        // out of the intersection.
        const audience = await conversationRecipients(userId, msg.conversation_id);
        if (!audience.length) return;
        const out = JSON.stringify({
          type: 'session_reset', conversation_id: msg.conversation_id, from_user: userId,
        });
        for (const rid of narrow(audience, msg.recipient_ids)) {
          pub.publish(`channel:user:${rid}`, out);
        }
        return;
      }
    } catch { /* ignore malformed frames */ }
  });

  ws.on('close', () => {
    const set = socketMap.get(userId);
    set?.delete(ws);
    if (set && set.size === 0) {
      socketMap.delete(userId);

    }
  });

  boundedSend(ws, JSON.stringify({ type: 'connected', user_id: userId }));

  // Every listener is attached; release anything the client sent while we were checking.
  ws.resume();
});

console.log(`[voiid:ws] listening on :${port}`);
