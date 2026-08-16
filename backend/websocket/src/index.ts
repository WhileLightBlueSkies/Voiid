// VOIID WebSocket relay (Phase 0 realtime flow, Section 10).
// Connect with JWT -> SUBSCRIBE channel:user:{id} -> in-memory socket_map.
// On Redis message for a user, push the wake/ciphertext-ref down their live socket.
// Unauthenticated sockets are rejected (Section 4.6).
import { WebSocketServer, WebSocket } from 'ws';
import jwt from 'jsonwebtoken';
import Redis from 'ioredis';

const JWT_SECRET = process.env.JWT_SECRET ?? 'dev-only-change-me';
const port = Number(process.env.WS_PORT) || 4001;

// socket_map: user_id -> set of live sockets on THIS instance.
const socketMap = new Map<string, Set<WebSocket>>();

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
  const raw = await pub.get(ringGrantKey(callId));
  if (!raw) return false;
  try {
    const { a, b } = JSON.parse(raw) as { a: string; b: string };
    // Direction-agnostic: the grant is written by the caller's ring, but the callee's answer,
    // ICE and hangup travel the other way over the same authorized pair.
    return (a === from && b === to) || (a === to && b === from);
  } catch {
    return false;
  }
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
const GAME_RATE_WINDOW_MS = 60_000;
// A move is tiny (a cell index, an angle/power pair). Generous, but bounded.
const GAME_MAX_PAYLOAD_CHARS = 2048;

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
      if (ws.readyState === WebSocket.OPEN) ws.send(frame);
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
      if (ws.readyState === WebSocket.OPEN) ws.send(frame);
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
        if (ws.readyState === WebSocket.OPEN) ws.send(frame);
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
      if (ws.readyState === WebSocket.OPEN) ws.send(frame);
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
  let isSignout = false;
  try { isSignout = JSON.parse(payload)?.type === 'force_signout'; } catch { /* not JSON: relay it */ }

  for (const ws of sockets) {
    if (ws.readyState === WebSocket.OPEN) ws.send(payload);
  }
  if (isSignout) {
    for (const ws of sockets) {
      if (ws.readyState === WebSocket.OPEN) ws.close(4403, 'account deleted');
    }
    socketMap.delete(userId);
  }
});

const wss = new WebSocketServer({ port });

wss.on('connection', (ws, req) => {
  // JWT via ?token= or Sec-WebSocket-Protocol; reject if absent/invalid.
  const url = new URL(req.url ?? '', 'http://localhost');
  const token = url.searchParams.get('token');
  let userId: string;
  try {
    userId = (jwt.verify(token ?? '', JWT_SECRET) as { user_id: string }).user_id;
  } catch {
    ws.close(4401, 'unauthorized');
    return;
  }

  // A VALID SIGNATURE IS NOT A LIVE ACCOUNT. Tokens run to 30 days with no server-side
  // session, so a deleted user kept opening sockets here — on the service that carries the
  // messages, calls and locations — long after every API read path had stopped returning
  // their row. This process holds no database connection by design, so the API writes a
  // revocation tombstone into the Redis both share and this reads it.
  //
  // Deliberately keyed on `auth:revoked:` rather than the API's `auth:active:` cache: that
  // one has a 10-second TTL, so absence is its normal state and denying on absence would
  // disconnect every user within ten seconds. Presence of THIS key is written only by
  // account deletion, so it is safe to fail closed on and open on everything else.
  presence.get(`auth:revoked:${userId}`).then((revoked) => {
    if (revoked) ws.close(4403, 'account deleted');
  }).catch(() => { /* Redis down: the API remains the authority and still fails closed there */ });

  if (!socketMap.has(userId)) socketMap.set(userId, new Set());
  socketMap.get(userId)!.add(ws);

  // presence: user online with heartbeat TTL. Also stamp last_seen now, and on
  // every heartbeat, so "last seen" stays fresh even on an UNCLEAN disconnect
  // (app killed / network drop) — the close handler can't be relied on for that.
  presence.set(`user:${userId}:online`, '1', 'EX', 60);
  presence.set(`user:${userId}:last_seen`, Date.now().toString());

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
  const locRate = new Map<string, { count: number; windowStart: number }>();

  // game_input rate state for THIS socket, keyed by match_id. Socket-local for the same
  // reason as locRate — it dies with the connection, so there is no cross-socket map to
  // leak or to clean up.
  const gameRate = new Map<
    string,
    { count: number; windowStart: number; warned: boolean }
  >();

  ws.on('message', (raw) => {
    // Realtime control frames: heartbeat (presence) and typing (Section 10 Redis keys).
    try {
      const msg = JSON.parse(raw.toString());

      if (msg.type === 'heartbeat') {
        presence.set(`user:${userId}:online`, '1', 'EX', 60);
        presence.set(`user:${userId}:last_seen`, Date.now().toString());
        return;
      }

      // typing: { type:'typing', conversation_id, recipient_ids:[...], state:'start'|'stop' }
      // Client supplies recipient_ids (it knows members from its local DB); WS has no DB.
      if (msg.type === 'typing' && msg.conversation_id && Array.isArray(msg.recipient_ids)) {
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
        // Blocking (039). This process holds no database connection by design, so the API
        // mirrors each block pair into the Redis both share (`block:a:b`, written in both
        // directions) exactly as account deletion does with `auth:revoked:` above.
        //
        // Fail OPEN on a Redis error, unlike the revocation check. The harm of a leaked
        // typing indicator is small and bounded; the harm of silently dropping every
        // typing frame during a Redis blip is a feature that looks broken for everyone.
        // Postgres remains the authority for every path that actually carries content.
        for (const rid of msg.recipient_ids) {
          if (rid === userId) continue;
          presence.get(`block:${userId}:${rid}`).then((blocked) => {
            if (!blocked) pub.publish(`channel:user:${rid}`, out);
          }).catch(() => { pub.publish(`channel:user:${rid}`, out); });
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
        typeof msg.share_id === 'string' &&
        Array.isArray(msg.recipient_ids)
      ) {
        const recipients = msg.recipient_ids.slice(0, LOC_MAX_RECIPIENTS);

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
          // Token bucket per share, per socket. Silent drop by design.
          const now = Date.now();
          const bucket = locRate.get(msg.share_id);
          if (!bucket || now - bucket.windowStart >= LOC_RATE_WINDOW_MS) {
            locRate.set(msg.share_id, { count: 1, windowStart: now });
          } else if (bucket.count >= LOC_MAX_FRAMES_PER_WINDOW) {
            return;
          } else {
            bucket.count += 1;
          }
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
        const now = Date.now();
        const bucket = gameRate.get(msg.match_id);
        if (!bucket || now - bucket.windowStart >= GAME_RATE_WINDOW_MS) {
          gameRate.set(msg.match_id, { count: 1, windowStart: now, warned: false });
        } else if (bucket.count >= GAME_MAX_FRAMES_PER_WINDOW) {
          if (!bucket.warned) {
            bucket.warned = true;
            console.warn(
              `[ws] game_input rate limit hit: match=${msg.match_id} user=${userId} ` +
                `limit=${GAME_MAX_FRAMES_PER_WINDOW}/${GAME_RATE_WINDOW_MS}ms — ` +
                `dropping until the window rolls`
            );
          }
          return;
        } else {
          bucket.count += 1;
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
          msg.type === 'call_migrate') &&
        typeof msg.to_user_id === 'string' &&
        typeof msg.call_id === 'string'
      ) {
        // Rebuild the outbound frame from KNOWN fields only (never echo client
        // extras) and stamp the authenticated sender. Undefined fields are dropped
        // by JSON.stringify, so e.g. a hangup without `reason` simply omits it.
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
        });
        // Deliver to the callee's devices (never echo back to the sender).
        if (msg.to_user_id !== userId) {
          // AUTHORIZATION GATE — see callPairAuthorized() above. Async, so this whole
          // delivery is deferred into a promise chain rather than making the outer message
          // handler async (which would change frame ordering for every other message type).
          // Frames for one call still land in order because they await the same key.
          const toUserId = msg.to_user_id as string;
          void callPairAuthorized(msg.call_id as string, userId, toUserId).then((allowed) => {
            if (!allowed) {
              // Fail closed and say nothing useful back: a caller probing which user_ids are
              // reachable must not learn the difference between "not authorized" and
              // "authorized but offline".
              return;
            }
            pub.publish(`channel:user:${toUserId}`, out);

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
      if (msg.type === 'session_reset' && msg.conversation_id && Array.isArray(msg.recipient_ids)) {
        const out = JSON.stringify({
          type: 'session_reset', conversation_id: msg.conversation_id, from_user: userId,
        });
        for (const rid of msg.recipient_ids) {
          if (rid !== userId) pub.publish(`channel:user:${rid}`, out);
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
      presence.set(`user:${userId}:last_seen`, Date.now().toString());
      presence.del(`user:${userId}:online`);
    }
  });

  ws.send(JSON.stringify({ type: 'connected', user_id: userId }));
});

console.log(`[voiid:ws] listening on :${port}`);
