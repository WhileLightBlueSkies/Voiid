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

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

  return res.json({ url, token, room, identity, ttl_seconds: LIVEKIT_TOKEN_TTL_SECONDS });
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

export default router;
