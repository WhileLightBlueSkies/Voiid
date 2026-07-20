// Calls backend (voice/video) — WebRTC bootstrap surface (Phase: calls).
//
// SCOPE: this route only issues time-limited ICE/TURN credentials, rings an
// offline callee with a content-free push, and keeps a lean call-history record.
// The actual signaling (SDP/ICE) rides the WebSocket relay (backend/websocket)
// over Redis; call MEDIA and SRTP keys are derived E2E on the devices (e2e-core).
// The server NEVER sees media, keys, SDP, or candidates here (Section 4.14).
import { Router } from 'express';
import crypto from 'crypto';
import { query } from '../db';
import { requireAuth } from '../auth';
import { asyncHandler } from '../util';
import jwt from 'jsonwebtoken';
import { sendWakePush, sendVoipPush, voipConfigured } from '../push';

const router = Router();

// TURN credential TTL (coturn REST scheme + Cloudflare). Default 1 hour.
const TTL_SECONDS = Number(process.env.VOIID_TURN_TTL_SECONDS) || 3600;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function splitEnvList(value: string | undefined): string[] {
  return (value ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

// STUN is safe to expose unconditionally (public reflexive-address discovery).
function stunUrls(): string[] {
  const raw = process.env.VOIID_STUN_URLS?.trim();
  return raw ? splitEnvList(raw) : ['stun:stun.l.google.com:19302'];
}

interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

// --- coturn REST ephemeral-credential scheme (use-auth-secret) ---------------------
// username = "<unixExpiry>:<userId>", credential = base64(HMAC_SHA1(secret, username)).
// Works with self-hosted coturn configured with `use-auth-secret` + `static-auth-secret`.
// Per-user and time-limited: a leaked credential expires within TTL and is scoped
// to the requesting user (the userId is bound into the HMAC'd username).
function coturnCredentials(userId: string): { username: string; credential: string; expiry: number } {
  const expiry = Math.floor(Date.now() / 1000) + TTL_SECONDS;
  const username = `${expiry}:${userId}`;
  const secret = process.env.VOIID_TURN_STATIC_AUTH_SECRET as string;
  const credential = crypto.createHmac('sha1', secret).update(username).digest('base64');
  return { username, credential, expiry };
}

// --- Cloudflare TURN (managed) -----------------------------------------------------
// If configured, Cloudflare mints the credentials for us. We prefer this over the
// self-hosted coturn scheme when its env is present. Returns null on any failure so
// the caller can fall back rather than 500.
async function cloudflareIceServers(): Promise<IceServer[] | null> {
  const keyId = process.env.VOIID_TURN_CLOUDFLARE_KEY_ID;
  const token = process.env.VOIID_TURN_CLOUDFLARE_API_TOKEN;
  if (!keyId || !token) return null;
  try {
    const resp = await fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate`,
      {
        method: 'POST',
        headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify({ ttl: TTL_SECONDS }),
      }
    );
    if (!resp.ok) {
      console.warn(`[calls] cloudflare TURN generate failed: ${resp.status}`);
      return null;
    }
    // CF returns { iceServers: { urls: string[]|string, username, credential } }.
    const body = (await resp.json()) as { iceServers?: { urls?: string[] | string; username?: string; credential?: string } };
    const ice = body?.iceServers;
    if (!ice?.urls) return null;
    const urls = Array.isArray(ice.urls) ? ice.urls : [ice.urls];
    return [{ urls, username: ice.username, credential: ice.credential }];
  } catch (e) {
    console.warn('[calls] cloudflare TURN request error:', (e as Error).message);
    return null;
  }
}

// GET /calls/turn — time-limited ICE servers for the client's RTCPeerConnection.
// Precedence: Cloudflare (if configured) -> coturn HMAC (if secret set) -> STUN-only.
// Never 500s just because TURN is unconfigured in dev: falls back to STUN with a
// clear `turn_configured: false` flag so the client can still attempt (P2P-only) calls.
router.get('/turn', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const iceServers: IceServer[] = [{ urls: stunUrls() }];

  // 1) Cloudflare managed TURN (preferred when configured).
  const cf = await cloudflareIceServers();
  if (cf) {
    iceServers.push(...cf);
    return res.json({ ice_servers: iceServers, ttl_seconds: TTL_SECONDS, turn_configured: true });
  }

  // 2) Self-hosted coturn REST scheme (HMAC over static-auth-secret).
  const turnUrls = splitEnvList(process.env.VOIID_TURN_URLS);
  if (turnUrls.length && process.env.VOIID_TURN_STATIC_AUTH_SECRET) {
    const { username, credential } = coturnCredentials(user_id);
    iceServers.push({ urls: turnUrls, username, credential });
    return res.json({ ice_servers: iceServers, ttl_seconds: TTL_SECONDS, turn_configured: true });
  }

  // 3) STUN-only fallback (dev / TURN not provisioned). Not an error.
  return res.json({ ice_servers: iceServers, ttl_seconds: TTL_SECONDS, turn_configured: false });
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
