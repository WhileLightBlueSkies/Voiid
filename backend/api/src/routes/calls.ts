// Calls backend (voice/video) — WebRTC bootstrap surface (Phase: calls).
//
// SCOPE: this route only issues time-limited ICE/TURN credentials, rings an
// offline callee with a content-free push, and keeps a lean call-history record.
// The actual signaling (SDP/ICE) rides the WebSocket relay (backend/websocket)
// over Redis; call MEDIA and SRTP keys are derived E2E on the devices (e2e-core).
// The server NEVER sees media, keys, SDP, or candidates here (Section 4.14).
import { Router } from 'express';
import { query } from '../db';
import { resolveIceServers } from '../turn';
import {
  normalizeCallMetrics,
  dedupeHash,
  clampWindowHours,
  END_REASONS,
  DROP_REASONS,
} from '../callMetrics';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';
import jwt from 'jsonwebtoken';
import { sendWakePush, sendVoipPush, voipConfigured } from '../push';
import { redis } from '../redis';
import {
  adhocRoomName,
  buildLiveKitCallGrant,
  callIdentity,
  encodeCallGrant,
  CONFERENCE_GRANT_TTL_SECONDS,
  MAX_CALL_PARTICIPANTS,
  type CallParticipantState,
  type CallRosterEntry,
} from '../callConference';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ─────────────────────────────────────────────────────────────────────────────────
// CALL AUTHORIZATION
//
// Ringing someone is a REACHABILITY decision, not just an authentication one. 020
// established three ways to reach a person (mutual contact / one-way contact as a request /
// @username + the 6-digit PIN), and every one of them resolves to the same artifact: a
// conversation both parties belong to. So "may A ring B" reduces to "do A and B share an
// active conversation" — no separate policy to keep in sync with 020, and the PIN gate is
// inherited rather than reimplemented.
//
// This check was MISSING on the 1:1 path: /ring validated only field shapes, so anyone who
// learned your user_id (a group roster exposes them) could make every device you own ring,
// VoIP push included, with no PIN, no request and no contact. The group endpoints
// (/group/token, /group/ring) always verified membership; the 1:1 path never did.
//
// BOTH sides are checked, not just the caller. Verifying only the caller would let a member
// of a large group name that conversation_id and ring a stranger who is also in it.
// ─────────────────────────────────────────────────────────────────────────────────
async function sharesConversation(a: string, b: string, conversationId: string): Promise<boolean> {
  const rows = await query<{ n: string }>(
    `select count(distinct user_id)::text as n
       from conversation_members
      where conversation_id = $1 and left_at is null and user_id in ($2, $3)`,
    [conversationId, a, b]
  );
  return rows[0]?.n === '2';
}

/**
 * How long a ring grant stays valid in Redis.
 *
 * THIS IS A CALL-LIFETIME BUDGET, NOT A RING TIMEOUT. It was originally 120s, sized to
 * outlive the ~45s ring — but the relay verifies EVERY call frame against this grant, not
 * just the offer. So on a 1:1 call lasting longer than two minutes the grant expired
 * mid-conversation and the hangup, ICE restarts and hold/unhold frames were all silently
 * dropped: the call could not be ended cleanly and could not recover from a network change.
 * Conference grants never had this problem because escalate/join/leave rewrite the key.
 *
 * Now matched to the conference budget. A stale permit is far less costly than it looks: it
 * authorises signalling between two people who were authorised to call each other when it was
 * written, and re-ringing still goes through POST /ring, which re-checks membership from the
 * database every time.
 */
const RING_GRANT_TTL_SECONDS = CONFERENCE_GRANT_TTL_SECONDS;

/** Redis key naming the ONE pair this call is permitted to signal between. */
export function ringGrantKey(callId: string): string {
  return `callgrant:${callId}`;
}

// GET /calls/turn — time-limited ICE servers for the client's RTCPeerConnection.
// Precedence: Cloudflare (if configured) -> coturn HMAC (if secret set) -> STUN-only.
// Never 500s just because TURN is unconfigured in dev: falls back to STUN with a
// clear `turn_configured: false` flag so the client can still attempt (P2P-only) calls.
router.get('/turn', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  return res.json(await resolveIceServers(user_id));
}));

// POST /calls/ring — persist a ringing call record and wake the callee's offline/
// backgrounded devices with a CONTENT-FREE push (only routing ids + call_id, never
// media/keys). The WS relay reaches devices holding a live socket; this reaches the
// rest so an incoming call actually rings.
router.post('/ring', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { to_user_id, call_id, call_kind, conversation_id } = req.body ?? {};

  if (typeof to_user_id !== 'string' || typeof conversation_id !== 'string') {
    return res.status(400).json({ error: 'to_user_id and conversation_id required' });
  }
  if (call_kind !== 'voice' && call_kind !== 'video') {
    return res.status(400).json({ error: "call_kind must be 'voice' or 'video'" });
  }
  if (typeof call_id !== 'string' || !UUID_RE.test(call_id)) {
    return res.status(400).json({ error: 'call_id must be a uuid (client-generated)' });
  }

  // AUTHORIZATION — see sharesConversation() above. Runs BEFORE the calls row is inserted
  // and before any push is sent, so an unauthorized ring leaves no history record and never
  // reaches the callee's device.
  if (to_user_id === user_id) {
    return res.status(400).json({ error: 'cannot call yourself' });
  }
  if (!(await sharesConversation(user_id, to_user_id, conversation_id))) {
    // 403 rather than 404: the caller supplied a real conversation id, they are simply not
    // permitted to ring through it. Deliberately does not distinguish "you are not a member"
    // from "they are not a member" — that difference would let a caller probe who belongs to
    // a conversation they can see the id of.
    return res.status(403).json({ error: 'not permitted to call this user' });
  }

  // Record the authorized pair for the WebSocket relay. The relay (backend/websocket) holds
  // no database connection by design — it is a stateless fan-out over Redis — so it cannot
  // run the membership query itself. This grant is the authorization decision, made here
  // where the database is, and handed to the relay through the Redis both services share.
  //
  // Keyed by call_id and naming BOTH parties, so the relay can verify each signaling frame
  // belongs to a call that was actually authorized and travels between the two people it was
  // authorized for — a stolen call_id cannot be pointed at a third party.
  //
  // The value carries BOTH shapes: the original `{a, b}` pair the relay reads today, and
  // the `p: [...]` participant list a conference needs (see encodeCallGrant). A 1:1 ring
  // is simply the two-participant case — writing `p` here too means the relay has exactly
  // one grant format to understand, and an escalation later only has to REWRITE this key
  // with a longer `p`, never change its schema mid-call.
  await redis.set(
    ringGrantKey(call_id),
    encodeCallGrant([user_id, to_user_id], [user_id, to_user_id]),
    'EX',
    RING_GRANT_TTL_SECONDS
  );

  // Lean history record. Use the client-supplied call_id as the row id so the
  // signaling id and the history row correlate; ignore a duplicate (retry) ring.
  await query(
    `insert into calls (id, conversation_id, caller_user_id, call_kind, status)
       values ($1, $2, $3, $4, 'ringing')
       on conflict (id) do nothing`,
    [call_id, conversation_id, user_id, call_kind]
  );

  // Wake the callee's active devices (fire-and-forget; must not block the response).
  //
  // Two delivery paths, because "ring a call" is a harder problem than "wake for a
  // message" on iOS. An iOS device with a PushKit token gets a VoIP push: it's the
  // only push that resumes a KILLED app fast enough to report the call to CallKit.
  // Everything else (Android/FCM, iOS without a PushKit token, or a deployment with
  // no VoIP APNs key configured) falls back to the existing alert/data wake push.
  const devices = await query<{
    platform: string;
    push_token: string | null;
    push_provider: string | null;
    voip_token: string | null;
  }>(
    `select platform, push_token, push_provider, voip_token from devices
       where user_id = $1 and revoked_at is null
         and (voip_token is not null
              or (push_token is not null and push_provider is not null))`,
    [to_user_id]
  );

  const meta = {
    type: 'call',
    call_id,
    call_kind,
    conversation_id,
    caller_id: user_id,
  } as const;

  const voipTokens: string[] = [];
  const wakeTargets: { push_token: string; push_provider: string }[] = [];
  // Only route to VoIP when the server can actually SEND one — otherwise an iOS
  // device would be silently skipped instead of falling back to its alert push.
  const useVoip = voipConfigured();
  for (const d of devices) {
    if (useVoip && d.platform === 'ios' && d.voip_token) {
      voipTokens.push(d.voip_token);
    } else if (d.push_token && d.push_provider) {
      wakeTargets.push({ push_token: d.push_token, push_provider: d.push_provider });
    }
  }

  if (voipTokens.length) void sendVoipPush(voipTokens, meta);
  if (wakeTargets.length) void sendWakePush(wakeTargets, meta);

  return res.json({
    call_id,
    ringing_devices: voipTokens.length + wakeTargets.length,
    voip_devices: voipTokens.length,
  });
}));

// --- Group calls: LiveKit SFU token issuance ---------------------------------------
//
// WHY an SFU: mesh WebRTC (every participant sending to every other) collapses past
// ~4 people — n-1 encodes and n-1 uploads per device. LiveKit is an SFU: each client
// uploads ONCE and the server forwards streams.
//
// WHY THIS IS STILL E2E: LiveKit runs with frame-level E2EE. Clients derive a shared
// key from `GroupSession.callKeys(member)` in e2e-core and encrypt media frames BEFORE
// they reach the SFU. The SFU forwards opaque frames — it can route but NOT decrypt.
// The key is never sent here; this endpoint only mints a ROUTING token (who may join
// which room). No key material, no media, no SDP passes through the API.
//
// The token is a standard JWT (HS256 over LIVEKIT_API_SECRET, `iss` = LIVEKIT_API_KEY)
// with LiveKit's documented `video` grant claim — no server SDK dependency needed.
const LIVEKIT_TOKEN_TTL_SECONDS = Number(process.env.LIVEKIT_TOKEN_TTL_SECONDS) || 6 * 3600;

interface LiveKitGrant {
  exp: number;
  iss: string;
  sub: string;
  nbf: number;
  video: {
    room: string;
    roomJoin: boolean;
    canPublish: boolean;
    canSubscribe: boolean;
    canPublishData: boolean;
  };
}

// POST /calls/group/token  { conversation_id } -> { url, token, room }
router.post('/group/token', requireAuth, asyncHandler(async (req, res) => {
  const { user_id, device_id } = (req as any).auth;
  const { conversation_id } = req.body ?? {};

  if (typeof conversation_id !== 'string' || !UUID_RE.test(conversation_id)) {
    return res.status(400).json({ error: 'conversation_id must be a uuid' });
  }

  const url = process.env.LIVEKIT_URL;
  const apiKey = process.env.LIVEKIT_API_KEY;
  const apiSecret = process.env.LIVEKIT_API_SECRET;
  // 503, not 500: "group calling isn't provisioned on this deployment" is a
  // configuration state the client should degrade gracefully around (hide the
  // group-call button), not a server fault it should retry.
  if (!url || !apiKey || !apiSecret) {
    return res.status(503).json({
      error: 'group calling is not configured on this server',
      livekit_configured: false,
    });
  }

  // Authorization: only an ACTIVE member of the conversation may join its room.
  // Without this, any authenticated user could mint a token for any room id and
  // sit in a call they were never part of.
  const member = await query<{ one: number }>(
    `select 1 as one from conversation_members
       where conversation_id = $1 and user_id = $2 and left_at is null`,
    [conversation_id, user_id]
  );
  if (!member[0]) return res.status(403).json({ error: 'not a member of this conversation' });

  // Room name is derived, not stored: the conversation IS the room, so any member
  // resolves the same room with no extra state to keep in sync.
  const room = `voiid-${conversation_id}`;
  // Identity must be unique PER DEVICE — LiveKit evicts an existing participant when
  // a second one joins with the same identity, which would kick a user's other device.
  const identity = device_id ? `${user_id}:${device_id}` : user_id;
  const now = Math.floor(Date.now() / 1000);

  const grant: LiveKitGrant = {
    iss: apiKey,
    sub: identity,
    nbf: now,
    exp: now + LIVEKIT_TOKEN_TTL_SECONDS,
    video: {
      room,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true, // in-call datachannel signaling (mute state, E2EE key rotation)
    },
  };

  // Sign the claims verbatim (no `expiresIn` option) — `exp`/`nbf` are already set,
  // and jsonwebtoken rejects combining them with the equivalent options.
  const token = jwt.sign(grant, apiSecret, { algorithm: 'HS256' });

  // Mark the call LIVE so members who never saw the ring push can still find it. This is a
  // presence hint, not a source of truth: the key is short-lived and refreshed by connected
  // clients, so if everyone leaves (or crashes) it simply expires and the banner disappears
  // on its own. Nothing needs to write a "call ended" event, which is exactly why this is a
  // TTL key and not a row.
  await touchGroupCallPresence(conversation_id, identity);

  return res.json({ url, token, room, identity, ttl_seconds: LIVEKIT_TOKEN_TTL_SECONDS });
}));

/**
 * How long an ongoing-call marker survives without a heartbeat. Deliberately a small
 * multiple of the client heartbeat interval (clients refresh every ~20s): long enough that
 * one dropped request does not blink the banner off, short enough that a crashed client
 * stops advertising a call nobody is in within a minute.
 */
const GROUP_CALL_PRESENCE_TTL_SECONDS = 60;

/** Key holding the identities currently in a conversation's call. */
const groupCallPresenceKey = (conversationId: string) => `call:group:live:${conversationId}`;

/**
 * Record that `identity` is in this conversation's call, and re-arm the expiry.
 *
 * A sorted set scored by timestamp, not a plain key, so a participant count is honest:
 * a set of members with per-member staleness cannot be expressed by one TTL, and showing
 * "3 on the call" when two of them died an hour ago is worse than showing nothing.
 */
async function touchGroupCallPresence(conversationId: string, identity: string): Promise<void> {
  const key = groupCallPresenceKey(conversationId);
  const now = Date.now();
  await redis
    .multi()
    .zadd(key, now, identity)
    // Drop anyone who has not heartbeat within the TTL. Done on WRITE rather than on read so
    // the read path stays a single command and cannot be made to do unbounded work.
    .zremrangebyscore(key, '-inf', now - GROUP_CALL_PRESENCE_TTL_SECONDS * 1000)
    .expire(key, GROUP_CALL_PRESENCE_TTL_SECONDS)
    .exec();
}

// GET /calls/group/active?conversation_id= — "is there a call happening in this chat right
// now?", which backs the in-chat "ongoing call — Join" banner. Before this, a group call was
// discoverable ONLY by catching the ring push: miss the notification and the call was
// invisible even while your friends were sitting in it.
router.get('/group/active', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const conversation_id = req.query.conversation_id;

  if (typeof conversation_id !== 'string' || !UUID_RE.test(conversation_id)) {
    return res.status(400).json({ error: 'conversation_id must be a uuid' });
  }

  // Membership first, and NOT as an afterthought: this endpoint reports who is on a call.
  // Without the check, any authenticated user could poll arbitrary conversation ids and read
  // out the live social graph of rooms they have no part in.
  const member = await query<{ one: number }>(
    `select 1 as one from conversation_members
       where conversation_id = $1 and user_id = $2 and left_at is null`,
    [conversation_id, user_id]
  );
  if (!member[0]) return res.status(403).json({ error: 'not a member of this conversation' });

  const key = groupCallPresenceKey(conversation_id);
  const fresh = Date.now() - GROUP_CALL_PRESENCE_TTL_SECONDS * 1000;
  const identities = await redis.zrangebyscore(key, fresh, '+inf');

  // Identity is `user_id:device_id`, so one user on two devices is ONE participant. Counting
  // raw entries would show "2 people" for one person who answered on their watch.
  const users = new Set(identities.map((i) => i.split(':')[0]));

  return res.json({
    active: users.size > 0,
    participant_count: users.size,
    // Whether YOU are already on it, so the banner can say "Return to call" rather than
    // inviting you to join something you are in.
    self_present: users.has(user_id),
  });
}));

// POST /calls/group/heartbeat  { conversation_id } — re-arm the presence marker while a
// client stays on the call. The LiveKit token is minted once and lasts far longer than the
// presence TTL, so without this the banner would vanish mid-call for everyone else.
router.post('/group/heartbeat', requireAuth, asyncHandler(async (req, res) => {
  const { user_id, device_id } = (req as any).auth;
  const { conversation_id } = req.body ?? {};

  if (typeof conversation_id !== 'string' || !UUID_RE.test(conversation_id)) {
    return res.status(400).json({ error: 'conversation_id must be a uuid' });
  }

  const member = await query<{ one: number }>(
    `select 1 as one from conversation_members
       where conversation_id = $1 and user_id = $2 and left_at is null`,
    [conversation_id, user_id]
  );
  if (!member[0]) return res.status(403).json({ error: 'not a member of this conversation' });

  await touchGroupCallPresence(conversation_id, device_id ? `${user_id}:${device_id}` : user_id);
  return res.json({ ok: true, ttl_seconds: GROUP_CALL_PRESENCE_TTL_SECONDS });
}));

// POST /calls/group/leave  { conversation_id } — drop this device from the presence set as
// soon as the user hangs up, instead of waiting out the TTL. Best-effort by design: a client
// that is killed rather than closed never sends this, which is precisely why the TTL exists
// and why this endpoint is an optimisation rather than the mechanism.
router.post('/group/leave', requireAuth, asyncHandler(async (req, res) => {
  const { user_id, device_id } = (req as any).auth;
  const { conversation_id } = req.body ?? {};

  if (typeof conversation_id !== 'string' || !UUID_RE.test(conversation_id)) {
    return res.status(400).json({ error: 'conversation_id must be a uuid' });
  }

  // No membership check: this only ever REMOVES the caller's own identity, so the worst a
  // non-member can do is delete an entry that was never there.
  await redis.zrem(
    groupCallPresenceKey(conversation_id),
    device_id ? `${user_id}:${device_id}` : user_id
  );
  return res.json({ ok: true });
}));

// POST /calls/group/ring  { conversation_id, call_kind } — advertise that a group call
// STARTED so the other members can join it. A group call has no single callee, so unlike the
// 1:1 /ring this fans out to EVERY other active member of the conversation. Without this,
// group calls were "join-only" — a member only ever discovered a call by independently
// opening the same chat and tapping call while the starter happened to still be connected,
// which is why "the call gets sent but no one can join". A WAKE push (NOT VoIP) is used so it
// surfaces as a tappable "join" notification rather than forcing an iOS CallKit report (a
// group call has no single peer to report). Foreground clients also receive the data payload.
router.post('/group/ring', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { conversation_id, call_kind } = req.body ?? {};

  if (typeof conversation_id !== 'string' || !UUID_RE.test(conversation_id)) {
    return res.status(400).json({ error: 'conversation_id must be a uuid' });
  }
  if (call_kind !== 'voice' && call_kind !== 'video') {
    return res.status(400).json({ error: "call_kind must be 'voice' or 'video'" });
  }

  // Only an active member may ring the group.
  const caller = await query<{ one: number }>(
    `select 1 as one from conversation_members
       where conversation_id = $1 and user_id = $2 and left_at is null`,
    [conversation_id, user_id]
  );
  if (!caller[0]) return res.status(403).json({ error: 'not a member of this conversation' });

  // Every OTHER active member's push-capable devices.
  const devices = await query<{ push_token: string; push_provider: string }>(
    `select d.push_token, d.push_provider
       from devices d
       join conversation_members m on m.user_id = d.user_id
      where m.conversation_id = $1 and m.user_id <> $2 and m.left_at is null
        and d.revoked_at is null and d.push_token is not null and d.push_provider is not null`,
    [conversation_id, user_id]
  );

  const meta = {
    type: 'group_call',
    conversation_id,
    call_kind,
    caller_id: user_id,
  } as const;

  const wakeTargets = devices.map((d) => ({ push_token: d.push_token, push_provider: d.push_provider }));
  if (wakeTargets.length) void sendWakePush(wakeTargets, meta);

  return res.json({ rung_devices: wakeTargets.length });
}));

// --- Anonymous call-quality metrics (Section 4.14) ---------------------------------
//
// WHY THIS EXISTS: "did the call connect, how fast, did it hold up, did it need a
// relay" are the only numbers that tell us whether calling actually works for real
// users on real networks. Without them, call reliability is guesswork.
//
// ============================ PRIVACY DECISION ====================================
// The `call_metrics` table stores NO user_id, NO device_id, and NO call_id.
//
// WHY NO user_id: a row of (user, when, duration, peer-ish signal) is a call detail
// record — the exact metadata shape that makes "who talked to whom, when, for how
// long" reconstructible. That is the thing VOIID exists to not have. Even a "coarse
// bucket" of the user id (a hash prefix / cohort) was rejected: buckets are stable
// pseudonyms, and a stable pseudonym plus timestamps plus durations re-identifies
// people through correlation. So the row is a genuinely anonymous sample.
//
// WHY NO call_id: `calls.id` is the primary key of a table holding caller_user_id
// and conversation_id. Storing it here would make this table JOINABLE straight back
// onto the identity we just removed. Instead we store `dedupe_hash` — an HMAC-SHA256
// of the call id under a server-side secret (VOIID_METRICS_DEDUPE_SECRET). It still
// makes a client retry idempotent, it is not reversible without the secret, and
// rotating the secret permanently severs the linkage for all existing rows. When the
// secret is unset the key is a random per-process value: dedupe degrades to
// per-process, and linkage becomes impossible by construction. Safe default.
//
// WHY AN HOUR BUCKET, NOT A TIMESTAMP: an exact `created_at` correlates one-to-one
// with `calls.ended_at`, which would re-link the anonymous row to an identified one
// by timing alone. We store `bucket_hour` (the hour, truncated) — enough resolution
// for reliability trends, far too coarse to align with a specific call.
//
// WHAT IS NEVER ACCEPTED: SDP, ICE candidates, IP addresses, peer identity, call
// content. `normalizeCallMetrics` builds the persisted row key-by-key from a fixed
// whitelist rather than copying the request body, so an extra client field cannot
// become stored data even by accident. Unknown keys are dropped and only their NAMES
// are echoed back (never their values), for client-side debugging.
// ==================================================================================

// POST /calls/metrics — submit one anonymous aggregate sample when a call ends.
// requireAuth is present to keep the endpoint from being an open write surface for
// the internet; the authenticated identity is used ONLY for that gate and is
// deliberately NOT persisted with the row.
router.post('/metrics', requireAuth, asyncHandler(async (req, res) => {
  const result = normalizeCallMetrics(req.body);
  if (!result.ok) return res.status(400).json({ error: result.error });
  const m = result.value;

  await query(
    `insert into call_metrics (
       dedupe_hash, bucket_hour, platform, connected, relayed, end_reason,
       setup_ms, duration_ms, ice_restarts, avg_rtt_ms, avg_packet_loss_pct, jitter_ms)
     values ($1, date_trunc('hour', now()), $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
     on conflict (dedupe_hash) do nothing`,
    [
      dedupeHash(result.call_id),
      m.platform,
      m.connected,
      m.relayed,
      m.end_reason,
      m.setup_ms ?? null,
      m.duration_ms ?? null,
      m.ice_restarts ?? null,
      m.avg_rtt_ms ?? null,
      m.avg_packet_loss_pct ?? null,
      m.jitter_ms ?? null,
    ]
  );

  // `dropped` is key NAMES only — never the rejected values.
  return res.json({ recorded: true, dropped: result.dropped });
}));

// GET /calls/metrics/summary?hours=24[&platform=ios|android] — the headline call
// reliability numbers for ops.
//
// Gating: auth'd, and additionally restricted to VOIID_OPS_USER_IDS when that env is
// set (comma-separated user ids). Leaving it unset keeps the endpoint auth'd-only,
// which is acceptable because the response is aggregate-only and contains nothing
// attributable to any user.
router.get('/metrics/summary', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const opsAllowlist = (process.env.VOIID_OPS_USER_IDS ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  if (opsAllowlist.length && !opsAllowlist.includes(user_id)) {
    return res.status(403).json({ error: 'ops access required' });
  }

  const hours = clampWindowHours(req.query.hours);
  const platform =
    req.query.platform === 'ios' || req.query.platform === 'android'
      ? (req.query.platform as string)
      : null;

  // One pass over the window. Percentiles are computed only over calls that
  // actually connected — a never-connected call has no meaningful time-to-connect.
  const rows = await query<{
    total: string;
    connected: string;
    relayed: string;
    dropped: string;
    p50_setup_ms: number | null;
    p95_setup_ms: number | null;
  }>(
    `select
       count(*)                                            as total,
       count(*) filter (where connected)                   as connected,
       count(*) filter (where relayed)                     as relayed,
       count(*) filter (where connected and end_reason = any($2)) as dropped,
       percentile_cont(0.5) within group (order by setup_ms)
         filter (where connected and setup_ms is not null) as p50_setup_ms,
       percentile_cont(0.95) within group (order by setup_ms)
         filter (where connected and setup_ms is not null) as p95_setup_ms
     from call_metrics
     where bucket_hour >= date_trunc('hour', now()) - make_interval(hours => $1)
       and ($3::text is null or platform = $3)`,
    [hours, DROP_REASONS, platform]
  );

  const r = rows[0];
  const total = Number(r?.total ?? 0);
  const connected = Number(r?.connected ?? 0);
  const relayed = Number(r?.relayed ?? 0);
  const dropped = Number(r?.dropped ?? 0);
  const pct = (n: number, d: number) => (d > 0 ? Math.round((n / d) * 1000) / 10 : null);

  return res.json({
    window_hours: hours,
    platform: platform ?? 'all',
    samples: total,
    // Headline reliability numbers.
    setup_success_rate_pct: pct(connected, total),
    time_to_connect_ms: {
      p50: r?.p50_setup_ms != null ? Math.round(Number(r.p50_setup_ms)) : null,
      p95: r?.p95_setup_ms != null ? Math.round(Number(r.p95_setup_ms)) : null,
    },
    // Of the calls that DID connect, how many died abnormally.
    drop_rate_pct: pct(dropped, connected),
    relayed_pct: pct(relayed, total),
    end_reasons: END_REASONS,
  });
}));

// POST /calls/:id/status — update a call's lifecycle (answered/ended/missed/declined).
// Signaling stays ephemeral; this only maintains the history/missed-call record.
// Authorization: the requester must be an active member of the call's conversation.
router.post('/:id/status', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const callId = req.params.id;
  const { status, end_reason } = req.body ?? {};

  if (!UUID_RE.test(callId)) return res.status(400).json({ error: 'invalid call id' });
  const allowed = ['connected', 'ended', 'missed', 'declined'];
  if (typeof status !== 'string' || !allowed.includes(status)) {
    return res.status(400).json({ error: `status must be one of ${allowed.join(', ')}` });
  }
  if (end_reason != null && typeof end_reason !== 'string') {
    return res.status(400).json({ error: 'end_reason must be a string' });
  }

  const calls = await query<{ conversation_id: string }>(
    `select conversation_id from calls where id = $1`,
    [callId]
  );
  if (!calls[0]) return res.status(404).json({ error: 'call not found' });

  // Only a member of the call's conversation may mutate its record.
  const member = await query<{ one: number }>(
    `select 1 as one from conversation_members
       where conversation_id = $1 and user_id = $2 and left_at is null`,
    [calls[0].conversation_id, user_id]
  );
  if (!member[0]) return res.status(403).json({ error: 'not a member of this conversation' });

  // Stamp answered_at on connect, ended_at on any terminal state (idempotent via coalesce).
  await query(
    `update calls set
       status      = $2,
       answered_at = case when $2 = 'connected' then coalesce(answered_at, now()) else answered_at end,
       ended_at    = case when $2 in ('ended','missed','declined') then coalesce(ended_at, now()) else ended_at end,
       end_reason  = coalesce($3, end_reason)
     where id = $1`,
    [callId, status, end_reason ?? null]
  );

  return res.json({ call_id: callId, status });
}));

// ═══════════════════════════════════════════════════════════════════════════════════
// AD-HOC CONFERENCE — adding a third person to a live 1:1 call
//
// ┌───────────────────────────────────────────────────────────────────────────────┐
// │ A SHARED CALL GRANTS NO MESSAGING RIGHTS.                                      │
// │                                                                                │
// │ *** NOTHING BELOW THIS LINE MAY INSERT INTO OR UPDATE `conversations` OR        │
// │     `conversation_members`. ***                                                │
// │                                                                                │
// │ That is not a style preference, it is the whole feature. The only multi-party   │
// │ room that existed before this block is `voiid-<conversation_id>`, authorized by │
// │ conversation membership and keyed by the conversation's MLS state — so the only │
// │ way to get a third person into a call was to CREATE A GROUP CONVERSATION        │
// │ containing them, which hands a stranger a permanent messaging surface with both │
// │ participants and bypasses the 6-digit contact-PIN gate in 020_reachability.sql  │
// │ entirely. Exactly what the product forbids (029: "FOLLOWING ADDS NO FOURTH      │
// │ PATH" — same rule, applied to calls).                                          │
// │                                                                                │
// │ So: the room is named for the CALL (`voiid-call-<call_id>`), membership lives   │
// │ in `call_participants` (014 + 031), and the media key is a per-call CallSecret  │
// │ distributed pairwise over the Double Ratchet — never a conversation key.        │
// │                                                                                │
// │ Conversation tables are READ here (to answer "may this person reach that        │
// │ person") and never written. If you are about to add a write, you are about to   │
// │ break the requirement. backend/api/test/callConference.test.ts fails on it.     │
// └───────────────────────────────────────────────────────────────────────────────┘
// ═══════════════════════════════════════════════════════════════════════════════════

/** LiveKit config, or null when this deployment has no SFU provisioned. */
function livekitConfig(): { url: string; apiKey: string; apiSecret: string } | null {
  const url = process.env.LIVEKIT_URL;
  const apiKey = process.env.LIVEKIT_API_KEY;
  const apiSecret = process.env.LIVEKIT_API_SECRET;
  if (!url || !apiKey || !apiSecret) return null;
  return { url, apiKey, apiSecret };
}

interface CallRow {
  id: string;
  conversation_id: string;
  caller_user_id: string;
  call_kind: string;
  status: string;
}

async function loadCall(callId: string): Promise<CallRow | null> {
  const rows = await query<CallRow>(
    `select id, conversation_id, caller_user_id, call_kind, status from calls where id = $1`,
    [callId]
  );
  return rows[0] ?? null;
}

/**
 * MAY `requester` PULL `invitee` INTO A CALL?
 *
 * The same question the message path asks, answered the same way — deliberately, so there
 * is no second reachability policy to keep in sync with 020. Two ways in:
 *
 *   1. mutual contact  — both have saved each other in contact_sync (020 path 1), or
 *   2. accepted 1:1/group — they share a conversation where BOTH memberships are active
 *      AND both are `request_state = 'accepted'`.
 *
 * BOTH sides must be 'accepted'. A pending request is not a relationship: if a one-way
 * `pending` sufficed, sending someone an unanswered message request would earn the right
 * to make their phone ring inside a conference — turning the request inbox into a ringing
 * channel and undoing the point of 020.
 *
 * The invitee's relationship to the OTHER participant is deliberately NOT required. That
 * is the entire feature: the added person may be a complete stranger to the peer, who will
 * see their @username and nothing more, and who must still pass the PIN gate to message
 * them afterwards.
 */
async function canReachForCall(requester: string, invitee: string): Promise<boolean> {
  const rows = await query<{ a_saved_b: boolean; b_saved_a: boolean; accepted_conv: boolean }>(
    `select
       exists(select 1 from contact_sync where owner_user_id = $1 and contact_user_id = $2) as a_saved_b,
       exists(select 1 from contact_sync where owner_user_id = $2 and contact_user_id = $1) as b_saved_a,
       exists(
         select 1 from conversation_members m1
           join conversation_members m2 on m2.conversation_id = m1.conversation_id
          where m1.user_id = $1 and m2.user_id = $2
            and m1.left_at is null and m2.left_at is null
            and m1.request_state = 'accepted' and m2.request_state = 'accepted'
       ) as accepted_conv`,
    [requester, invitee]
  );
  const r = rows[0];
  if (!r) return false;
  return (r.a_saved_b && r.b_saved_a) || r.accepted_conv;
}

/**
 * Is `userId` allowed to act on this call right now?
 *
 * Two accepted proofs, because a 1:1 call writes NO participant rows — 014's
 * `call_participants` has never been written by anything, and the first escalation is
 * precisely the moment it starts being. So:
 *
 *   - a live `call_participants` row (state <> 'left'), for anyone already in the room; or
 *   - active membership of the call's own conversation, for the ORIGINAL two participants
 *     of the 1:1 leg, whose only record of being on this call is the `calls` row itself.
 *
 * The second proof is a READ of conversation_members and grants nothing beyond this call.
 */
async function isLiveCallParticipant(call: CallRow, userId: string): Promise<boolean> {
  const rows = await query<{ ok: boolean }>(
    `select (
        exists(select 1 from call_participants
                where call_id = $1 and user_id = $2 and state <> 'left')
     or exists(select 1 from conversation_members
                where conversation_id = $3 and user_id = $2 and left_at is null)
     ) as ok`,
    [call.id, userId, call.conversation_id]
  );
  return rows[0]?.ok === true;
}

/**
 * Materialise the ORIGINAL 1:1 participants into `call_participants`, once.
 *
 * Guarded by "this call has no participant rows yet" so a second escalation cannot
 * resurrect someone who has already LEFT the call by re-seeding them from the underlying
 * conversation. `on conflict (call_id, user_id)` targets the TOTAL unique index added in
 * 031 — never the 014 `(call_id, user_id, device_id)` one, whose NULL device_id makes
 * every ON CONFLICT miss and insert a duplicate (the 027 bug class).
 */
async function seedOriginalParticipants(call: CallRow): Promise<void> {
  await query(
    `insert into call_participants (call_id, user_id, state, state_changed_at)
     select $1, cm.user_id, 'joined', now()
       from conversation_members cm
      where cm.conversation_id = $2
        and cm.left_at is null
        and not exists (select 1 from call_participants cp where cp.call_id = $1)
     on conflict (call_id, user_id) do nothing`,
    [call.id, call.conversation_id]
  );
}

/** Every user id currently permitted to be in this call, in join order. */
async function liveParticipantIds(callId: string): Promise<string[]> {
  const rows = await query<{ user_id: string }>(
    `select user_id from call_participants
      where call_id = $1 and state <> 'left'
      order by joined_at asc, user_id asc`,
    [callId]
  );
  return rows.map((r) => r.user_id);
}

/**
 * Rewrite the Redis ring grant from the LIVE roster.
 *
 * This is the one place conference membership becomes signaling authorization, and it runs
 * on every membership change (escalate / join / leave) rather than only at ring time — so
 * a participant who leaves loses the ability to relay frames on the next change instead of
 * whenever the TTL happens to lapse.
 *
 * `a`/`b` keep naming the ORIGINAL 1:1 pair (see encodeCallGrant): during make-before-break
 * the 1:1 PeerConnection is still up and its hangup/ICE must keep relaying even on a relay
 * build that has not yet learned to read `p`.
 */
async function refreshCallGrant(call: CallRow): Promise<string[]> {
  const participants = await liveParticipantIds(call.id);

  // The original callee = the other active member of the call's conversation. Read-only.
  const peerRows = await query<{ user_id: string }>(
    `select user_id from conversation_members
      where conversation_id = $1 and user_id <> $2 and left_at is null
      order by joined_at asc
      limit 1`,
    [call.conversation_id, call.caller_user_id]
  );
  const originalPeer = peerRows[0]?.user_id ?? participants.find((p) => p !== call.caller_user_id);

  const legacyPair: [string, string] | undefined = originalPeer
    ? [call.caller_user_id, originalPeer]
    : undefined;

  await redis.set(
    ringGrantKey(call.id),
    encodeCallGrant(participants, legacyPair),
    'EX',
    CONFERENCE_GRANT_TTL_SECONDS
  );
  return participants;
}

/**
 * The roster, as one participant is allowed to see it.
 *
 * USERNAME ONLY — no full_name, no photo_url, no phone, no bio. A shared call is not an
 * introduction, and `GET /users/:id` still hands full_name to any authenticated caller
 * (see 3.5), so routing call rosters through THIS endpoint instead is what keeps a
 * stranger's private-plane profile out of a call they were added to. A null username
 * renders as "Unknown" on the clients — never a raw user id.
 */
async function loadRoster(callId: string, selfId: string): Promise<CallRosterEntry[]> {
  const rows = await query<{
    user_id: string;
    username: string | null;
    state: CallParticipantState;
    invited_by: string | null;
  }>(
    `select cp.user_id, u.username, cp.state, cp.invited_by
       from call_participants cp
       join users u on u.id = cp.user_id
      where cp.call_id = $1 and cp.state <> 'left'
      order by cp.joined_at asc, cp.user_id asc`,
    [callId]
  );
  return rows.map((r) => ({
    user_id: r.user_id,
    username: r.username,
    state: r.state,
    invited_by: r.invited_by,
    is_self: r.user_id === selfId,
  }));
}

// ─────────────────────────────────────────────────────────────────────────────────
// POST /calls/:id/escalate   { invitee_user_id }  ->  invite a third person
//
// Turns a live 1:1 into an ad-hoc conference. Authorization is TWO independent checks:
//   1. the requester must be live on this call (isLiveCallParticipant), and
//   2. the requester must be allowed to reach the invitee (canReachForCall — the 020
//      policy, not a new one).
// The invitee's relationship to the PEER is not checked and must not be: that is the
// "unknown participant" case the whole feature exists for.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/escalate', requireAuth, asyncHandler(async (req, res) => {
  const { user_id, device_id } = (req as any).auth;
  const callId = req.params.id;
  const { invitee_user_id } = req.body ?? {};

  if (!UUID_RE.test(callId)) return res.status(400).json({ error: 'invalid call id' });
  if (typeof invitee_user_id !== 'string' || !UUID_RE.test(invitee_user_id)) {
    return res.status(400).json({ error: 'invitee_user_id must be a uuid' });
  }
  if (invitee_user_id === user_id) {
    return res.status(400).json({ error: 'cannot invite yourself' });
  }

  // Fail on missing SFU config BEFORE anything is written or anyone's phone rings: an
  // escalation with no room to escalate INTO would leave the invitee ringing into nothing.
  const lk = livekitConfig();
  if (!lk) {
    return res.status(503).json({
      error: 'conference calling is not configured on this server',
      livekit_configured: false,
    });
  }

  const call = await loadCall(callId);
  if (!call) return res.status(404).json({ error: 'call not found' });
  if (call.status !== 'ringing' && call.status !== 'connected') {
    // Deliberately 409, not 403: the requester may well be entitled to this call, it is
    // simply over. A finished call must never be re-openable as a ringing channel.
    return res.status(409).json({ error: 'call is not live' });
  }

  if (!(await isLiveCallParticipant(call, user_id))) {
    return res.status(403).json({ error: 'not a participant of this call' });
  }

  // The invitee must exist and not be a deleted account.
  const inviteeRows = await query<{ id: string; username: string | null }>(
    `select id, username from users where id = $1 and deleted_at is null`,
    [invitee_user_id]
  );
  const invitee = inviteeRows[0];
  // 403, not 404, and identical to the unreachable case below: distinguishing "no such
  // user" from "you may not reach them" turns this endpoint into a user-id oracle.
  if (!invitee) return res.status(403).json({ error: 'not permitted to add this user' });

  if (!(await canReachForCall(user_id, invitee_user_id))) {
    return res.status(403).json({ error: 'not permitted to add this user' });
  }

  // Bring the original 1:1 pair into call_participants (idempotent, once per call), then
  // record the requester's current device.
  await seedOriginalParticipants(call);
  await query(
    `insert into call_participants (call_id, user_id, device_id, state, state_changed_at)
     values ($1, $2, $3, 'joined', now())
     on conflict (call_id, user_id) do update
        set state = 'joined',
            device_id = coalesce(excluded.device_id, call_participants.device_id),
            left_at = null,
            state_changed_at = now()`,
    [callId, user_id, device_id ?? null]
  );

  // Room-size cap, checked AFTER seeding so it counts the real roster.
  const before = await liveParticipantIds(callId);
  if (!before.includes(invitee_user_id) && before.length >= MAX_CALL_PARTICIPANTS) {
    return res.status(409).json({
      error: `a call can hold at most ${MAX_CALL_PARTICIPANTS} participants`,
      max_participants: MAX_CALL_PARTICIPANTS,
    });
  }

  // Upsert the invitee as `invited`. The CASE keeps an already-`joined` participant
  // joined: re-inviting someone who is in the room must not demote them to "Ringing…".
  await query(
    `insert into call_participants (call_id, user_id, state, invited_by, state_changed_at)
     values ($1, $2, 'invited', $3, now())
     on conflict (call_id, user_id) do update
        set state = case when call_participants.state = 'joined' then 'joined' else 'invited' end,
            invited_by = coalesce(call_participants.invited_by, excluded.invited_by),
            left_at = null,
            state_changed_at = now()`,
    [callId, invitee_user_id, user_id]
  );

  const participants = await refreshCallGrant(call);
  const room = adhocRoomName(callId);

  // ── Wake the invitee's devices. CONTENT-FREE, exactly like /ring: routing ids only.
  //
  // `type: 'call'` so it takes the existing ring path byte for byte — the 60s ring TTL,
  // the PushKit/CallKit route on iOS, the full-screen incoming-call surface on Android.
  //
  // `conversation_id` is DELIBERATELY OMITTED, and its absence is the wire signal for
  // "this is an ad-hoc conference invite". The invitee is not a member of the call's
  // conversation and must not be handed its id — that id is the other participants'
  // private context, and a client that received it might try to open it. A woken client
  // that sees a call push with a call_id and NO conversation_id must go to
  // POST /calls/:id/adhoc-token, not to the 1:1 answer path.
  const devices = await query<{
    platform: string;
    push_token: string | null;
    push_provider: string | null;
    voip_token: string | null;
  }>(
    `select platform, push_token, push_provider, voip_token from devices
       where user_id = $1 and revoked_at is null
         and (voip_token is not null
              or (push_token is not null and push_provider is not null))`,
    [invitee_user_id]
  );

  const meta = {
    type: 'call',
    call_id: callId,
    call_kind: call.call_kind,
    caller_id: user_id,
  } as const;

  const voipTokens: string[] = [];
  const wakeTargets: { push_token: string; push_provider: string }[] = [];
  const useVoip = voipConfigured();
  for (const d of devices) {
    if (useVoip && d.platform === 'ios' && d.voip_token) voipTokens.push(d.voip_token);
    else if (d.push_token && d.push_provider) {
      wakeTargets.push({ push_token: d.push_token, push_provider: d.push_provider });
    }
  }
  if (voipTokens.length) void sendVoipPush(voipTokens, meta);
  if (wakeTargets.length) void sendWakePush(wakeTargets, meta);

  return res.json({
    call_id: callId,
    room,
    livekit_url: lk.url,
    livekit_configured: true,
    invitee: { user_id: invitee.id, username: invitee.username },
    participants: await loadRoster(callId, user_id),
    ringing_devices: voipTokens.length + wakeTargets.length,
    voip_devices: voipTokens.length,
    grant_ttl_seconds: CONFERENCE_GRANT_TTL_SECONDS,
  });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /calls/:id/adhoc-token  ->  a LiveKit JWT for `voiid-call-<call_id>`
//
// The counterpart of /calls/group/token, with the authorization swapped: a live
// `call_participants` row instead of conversation membership. That swap IS the feature —
// it is what lets a stranger into the room without being made a member of anything.
//
// Read-only: minting a token does not change the roster. POST /calls/:id/join does.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/adhoc-token', requireAuth, asyncHandler(async (req, res) => {
  const { user_id, device_id } = (req as any).auth;
  const callId = req.params.id;
  if (!UUID_RE.test(callId)) return res.status(400).json({ error: 'invalid call id' });

  const lk = livekitConfig();
  if (!lk) {
    return res.status(503).json({
      error: 'conference calling is not configured on this server',
      livekit_configured: false,
    });
  }

  // NOTE the gate: `call_participants`, state invited|joined. NOT conversation membership,
  // and NOT "is the call live" — an invitee answers before anyone marks them joined.
  const rows = await query<{ state: CallParticipantState }>(
    `select state from call_participants
      where call_id = $1 and user_id = $2 and state <> 'left'`,
    [callId, user_id]
  );
  if (!rows[0]) return res.status(403).json({ error: 'not a participant of this call' });

  const room = adhocRoomName(callId);
  const identity = callIdentity(user_id, device_id);
  const grant = buildLiveKitCallGrant({
    apiKey: lk.apiKey,
    identity,
    room,
    ttlSeconds: LIVEKIT_TOKEN_TTL_SECONDS,
  });
  // Sign the claims verbatim — `exp`/`nbf` are already set and jsonwebtoken rejects
  // combining them with `expiresIn`.
  const token = jwt.sign(grant, lk.apiSecret, { algorithm: 'HS256' });

  return res.json({
    url: lk.url,
    token,
    room,
    identity,
    state: rows[0].state,
    ttl_seconds: LIVEKIT_TOKEN_TTL_SECONDS,
  });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /calls/:id/join  ->  invited | joined  =>  joined
//
// The membership event the clients hang rekeying off: the inviter mints a fresh CallSecret
// and re-fans it pairwise on every join, so the joiner gets no access to media sent before
// they arrived. The server never sees that secret — this endpoint only moves the row and
// rewrites the relay grant.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/join', requireAuth, asyncHandler(async (req, res) => {
  const { user_id, device_id } = (req as any).auth;
  const callId = req.params.id;
  if (!UUID_RE.test(callId)) return res.status(400).json({ error: 'invalid call id' });

  const call = await loadCall(callId);
  if (!call) return res.status(404).json({ error: 'call not found' });

  // Joining requires an EXISTING non-left row: you may only join a call you were invited
  // to (or were already in). There is no self-service join — that would make a known
  // call_id a way into any room.
  const updated = await query<{ user_id: string }>(
    `update call_participants
        set state = 'joined',
            device_id = coalesce($3, device_id),
            left_at = null,
            joined_at = case when state = 'invited' then now() else joined_at end,
            state_changed_at = now()
      where call_id = $1 and user_id = $2 and state <> 'left'
      returning user_id`,
    [callId, user_id, device_id ?? null]
  );
  if (!updated[0]) return res.status(403).json({ error: 'not a participant of this call' });

  const participants = await refreshCallGrant(call);
  return res.json({
    call_id: callId,
    room: adhocRoomName(callId),
    state: 'joined',
    participant_count: participants.length,
    participants: await loadRoster(callId, user_id),
  });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /calls/:id/leave   { reason? }  ->  state = 'left'
//
// Also the DECLINE path: an invitee who never joined declines by leaving. One transition,
// one place that rewrites the grant, no second state machine to keep consistent.
//
// Leaving is a STATE, not a row deletion (031): the participant keeps their row so a
// rejoin reuses it and `on conflict (call_id, user_id)` stays a valid upsert target.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/:id/leave', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const callId = req.params.id;
  if (!UUID_RE.test(callId)) return res.status(400).json({ error: 'invalid call id' });

  const call = await loadCall(callId);
  if (!call) return res.status(404).json({ error: 'call not found' });

  const updated = await query<{ state: string }>(
    `update call_participants
        set state = 'left', left_at = now(), state_changed_at = now()
      where call_id = $1 and user_id = $2 and state <> 'left'
      returning state`,
    [callId, user_id]
  );
  // Idempotent: leaving twice is a no-op success, not a 403. Clients retry this on
  // teardown and a failing retry would strand the grant naming someone who is gone.
  const remaining = await refreshCallGrant(call);

  // Last one out ends the call record. Writes `calls` only — never a conversation row.
  if (remaining.length === 0) {
    await query(
      `update calls
          set status = case when status in ('ringing','connected') then 'ended' else status end,
              ended_at = coalesce(ended_at, now()),
              end_reason = coalesce(end_reason, 'hangup')
        where id = $1`,
      [callId]
    );
    // Nobody may signal on this call any more. Dropping the grant is what makes that
    // immediate rather than TTL-eventual.
    await redis.del(ringGrantKey(callId));
  }

  return res.json({
    call_id: callId,
    left: true,
    was_participant: !!updated[0],
    participant_count: remaining.length,
  });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /calls/:id/participants  ->  the roster, @username ONLY
//
// The identity surface for a conference, and the reason clients must not resolve call
// participants through `GET /users/:id`: that endpoint returns full_name to ANY
// authenticated caller, so using it here would leak the private-plane profile name of a
// person who has not passed your PIN gate to a stranger who merely shares a call with you.
// This returns username and state, and nothing else, to participants only.
//
// Clients still apply their own precedence on top: for someone already in the local
// UserDirectory (saved contact or accepted-conversation peer) show the saved name; for
// everyone else show @username, or "Unknown" if username is null — NEVER a raw user id.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/:id/participants', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const callId = req.params.id;
  if (!UUID_RE.test(callId)) return res.status(400).json({ error: 'invalid call id' });

  const call = await loadCall(callId);
  if (!call) return res.status(404).json({ error: 'call not found' });
  if (!(await isLiveCallParticipant(call, user_id))) {
    return res.status(403).json({ error: 'not a participant of this call' });
  }

  return res.json({
    call_id: callId,
    room: adhocRoomName(callId),
    call_kind: call.call_kind,
    status: call.status,
    participants: await loadRoster(callId, user_id),
  });
}));

export default router;
