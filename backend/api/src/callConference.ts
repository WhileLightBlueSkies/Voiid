// Ad-hoc conference calls — the pure, testable half.
//
// ═══════════════════════════════════════════════════════════════════════════════════
// THE RULE THIS MODULE EXISTS TO PROTECT
//
//   A SHARED CALL GRANTS NO MESSAGING RIGHTS.
//
// You can be pulled into a call by someone you know and end up sharing that call with a
// total stranger. That stranger sees your @username and nothing else, and to send you a
// single message afterwards they must still pass the 020 reachability gate (mutual
// contact, contact request, or @username + your 6-digit PIN). This is the same principle
// 029 states for follows: "FOLLOWING ADDS NO FOURTH PATH".
//
// Which is why a conference is NOT a group conversation. Today's only multi-party room is
// `voiid-<conversation_id>`, keyed on a group conversation's MLS state, so escalating a
// 1:1 that way would mean CREATING A GROUP CONVERSATION containing the stranger — handing
// them a permanent messaging surface with both participants. Instead the room is keyed on
// the CALL:
//
//   *** NOTHING IN THE CALL PATH MAY WRITE TO conversations OR conversation_members. ***
//
// Call membership lives in `call_participants` (031_call_conference.sql) and is read by
// the call path ONLY. If a future change makes reachability, conversations, or messages
// consult `call_participants` to decide whether someone may be MESSAGED, the PIN gate is
// bypassed and the product requirement is broken — that is a bug, not a feature.
// backend/api/test/callConference.test.ts fails on both halves of that.
// ═══════════════════════════════════════════════════════════════════════════════════
//
// Everything here is PURE — no database, no Redis, no express. That is deliberate: the
// grant encoding below is a security boundary shared with a second service (the WS relay
// parses exactly these bytes), and a shared wire format that cannot be unit-tested without
// standing up two servers is a format that silently drifts.

/**
 * Room-name prefix for a CALL-scoped room. The counterpart, `voiid-<conversation_id>`,
 * names a CONVERSATION and is what we must not use here — a room named for a conversation
 * can only be authorized by conversation membership, and conversation membership is the
 * messaging right we refuse to grant.
 */
export const ADHOC_ROOM_PREFIX = 'voiid-call-';

/** The LiveKit room for an ad-hoc conference escalated out of call `callId`. */
export function adhocRoomName(callId: string): string {
  return `${ADHOC_ROOM_PREFIX}${callId}`;
}

/** True for a room this module owns (i.e. authorized by call_participants, not membership). */
export function isAdhocRoomName(room: string): boolean {
  return room.startsWith(ADHOC_ROOM_PREFIX);
}

/**
 * Participant lifecycle. `invited` is not just cosmetic: 014 defaults `joined_at` to now()
 * on insert, so without a state an invitee who never answers is indistinguishable from
 * someone who was in the room the whole time. The inviter shows "Ringing…" for `invited`;
 * the SFU token is issued for `invited` and `joined` but never `left`.
 */
export const CALL_PARTICIPANT_STATES = ['invited', 'joined', 'left'] as const;
export type CallParticipantState = (typeof CALL_PARTICIPANT_STATES)[number];

/** A participant who may still hold (or obtain) a token for the room. */
export function isActiveParticipantState(state: string): boolean {
  return state === 'invited' || state === 'joined';
}

/**
 * Hard cap on room size. An ad-hoc conference is "a call you added someone to", not a
 * broadcast: every membership change re-keys (the inviter mints a fresh CallSecret and
 * re-fans it pairwise over the ratchet), so cost is O(participants x devices) per change.
 * Past a handful of people that is a rekey storm, and the product wants a group
 * conversation at that point anyway.
 */
export const MAX_CALL_PARTICIPANTS = 8;

// ─────────────────────────────────────────────────────────────────────────────────
// THE RING GRANT — how the relay learns who may signal on this call
//
// The WS relay (backend/websocket) holds NO database connection by design: it is
// stateless fan-out over Redis. So the authorization decision is made here, in the API,
// where the database is, and deposited in Redis under `callgrant:<call_id>` for the relay
// to verify on every call frame. Fail-closed: no grant, no relay.
//
// The grant shipped by the /calls/ring security fix named EXACTLY TWO parties, `{a, b}`,
// and the relay checks `(a===from && b===to) || (a===to && b===from)`. A conference has N.
//
// SO THE FORMAT IS ADDITIVE, NOT REPLACED:
//
//   { "a": <original caller>, "b": <original callee>, "p": [<every live participant>], "v": 2 }
//
// `p` is the real answer and the only field a conference-aware relay should read. `a`/`b`
// are kept, and kept pointing at the ORIGINAL 1:1 pair, for two reasons:
//
//   1. Rollout order. The relay is deployed separately; until it learns to read `p`, a
//      grant that dropped `a`/`b` would kill the 1:1 leg of every call.
//   2. Make-before-break. During escalation the original 1:1 PeerConnection stays up
//      until both original participants report SFU-connected, and its hangup/ICE frames
//      travel between exactly `a` and `b`. Those must keep flowing even on an old relay.
//
// `callGrantAllows` below is the reference implementation of the check. The relay's copy
// must behave identically; this one is unit-tested (test/callConference.test.ts) so the
// two cannot drift silently.
// ─────────────────────────────────────────────────────────────────────────────────

export interface CallGrant {
  /** Original 1:1 caller — legacy pair field, still honoured by the current relay. */
  a: string;
  /** Original 1:1 callee — legacy pair field. Equals `a` only in the degenerate case. */
  b: string;
  /** Every user allowed to signal on this call right now. The authoritative field. */
  p: string[];
  /** Format version. 1 = implicit (pair only, no `p`); 2 = this shape. */
  v: number;
}

export const CALL_GRANT_VERSION = 2;

/**
 * How long a CONFERENCE grant lives.
 *
 * The 1:1 ring grant is 120s — sized to outlive a ring, not a call. That is fine for a
 * ring because the pair is re-derivable, but a conference grant is the ONLY record the
 * relay has of who is in the room, and the room outlives the ring by however long people
 * talk. Matched to the LiveKit token lifetime so "your token is valid" and "your frames
 * relay" expire together instead of leaving a participant half-connected.
 *
 * It is still a lease, not a permanent right: every escalate/join/leave rewrites it from
 * the live `call_participants` roster, so a participant who leaves stops being able to
 * signal on the next membership change rather than at TTL expiry.
 */
export const CONFERENCE_GRANT_TTL_SECONDS = 6 * 3600;

/**
 * Build the Redis grant value for a call.
 *
 * @param participants every user id currently permitted to signal (state <> 'left').
 * @param legacyPair   the ORIGINAL 1:1 pair, preserved in `a`/`b` (see above). Defaults to
 *                     the first two participants when the original pair is unknown.
 */
export function encodeCallGrant(participants: string[], legacyPair?: [string, string]): string {
  // Dedupe while preserving order — join order is the roster order and the first two are
  // the fallback legacy pair.
  const p = participants.filter((id, i) => typeof id === 'string' && !!id && participants.indexOf(id) === i);
  const a = legacyPair?.[0] ?? p[0] ?? '';
  const b = legacyPair?.[1] ?? p[1] ?? p[0] ?? '';
  const grant: CallGrant = { a, b, p, v: CALL_GRANT_VERSION };
  return JSON.stringify(grant);
}

/** Parse a grant written by either format. Returns null on absent/garbage input. */
export function decodeCallGrant(raw: string | null | undefined): CallGrant | null {
  if (!raw) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== 'object') return null;
  const o = parsed as Record<string, unknown>;
  const a = typeof o.a === 'string' ? o.a : '';
  const b = typeof o.b === 'string' ? o.b : '';
  if (!a || !b) return null;
  // A v1 grant has no `p`; its participant set IS the pair.
  const p = Array.isArray(o.p)
    ? o.p.filter((x): x is string => typeof x === 'string' && !!x)
    : [a, b];
  return { a, b, p: p.length ? p : [a, b], v: typeof o.v === 'number' ? o.v : 1 };
}

/**
 * May a call frame from `from` to `to` be relayed for this call?
 *
 * Both endpoints must be in the grant. Self-addressed frames are refused: the relay never
 * echoes to the sender, and allowing it would make the grant a way to fan a frame back to
 * your own other devices outside the `call_taken` path built for exactly that.
 *
 * This is the function the WS relay's `callPairAuthorized` must mirror.
 */
export function callGrantAllows(raw: string | null | undefined, from: string, to: string): boolean {
  const grant = decodeCallGrant(raw);
  if (!grant) return false; // fail closed
  if (!from || !to || from === to) return false;
  return grant.p.includes(from) && grant.p.includes(to);
}

// ─────────────────────────────────────────────────────────────────────────────────
// LiveKit token claims
// ─────────────────────────────────────────────────────────────────────────────────

export interface LiveKitCallGrant {
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

/**
 * Claims for an ad-hoc room token.
 *
 * NO `name` CLAIM, EVER. The server must not assert display names into a room: identity is
 * resolved viewer-side, so my "Mum" can legitimately be your "@nehal" — and for a
 * participant who is a stranger to you, @username is ALL you are entitled to see. A name
 * claim here would push the private-plane profile name (which `GET /users/:id` still
 * returns to any authenticated caller) into a room containing someone who has not passed
 * your PIN gate. Use `GET /calls/:id/participants`, which returns usernames only.
 *
 * Identity is `<user_id>:<device_id>` because LiveKit EVICTS an existing participant when
 * a second one joins with the same identity — a per-user identity would kick the user's
 * other device out of the call.
 */
export function buildLiveKitCallGrant(args: {
  apiKey: string;
  identity: string;
  room: string;
  ttlSeconds: number;
  nowSeconds?: number;
}): LiveKitCallGrant {
  const now = args.nowSeconds ?? Math.floor(Date.now() / 1000);
  return {
    iss: args.apiKey,
    sub: args.identity,
    nbf: now,
    exp: now + args.ttlSeconds,
    video: {
      room: args.room,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true, // in-call datachannel (mute state, E2EE key rotation)
    },
  };
}

/** LiveKit identity for a user's device. Falls back to the bare user id for legacy tokens. */
export function callIdentity(userId: string, deviceId?: string | null): string {
  return deviceId ? `${userId}:${deviceId}` : userId;
}

// ─────────────────────────────────────────────────────────────────────────────────
// Roster disclosure
// ─────────────────────────────────────────────────────────────────────────────────

/**
 * What one participant is allowed to learn about another from the call path.
 *
 * USERNAME ONLY. Not full_name, not photo_url, not phone, not bio — a shared call is not
 * an introduction. `username` is the public-plane handle a stranger is entitled to (it is
 * how they would be found and PIN-gated in the first place); everything else belongs to
 * the private plane that the 020 gate protects.
 *
 * `null` username (user never set one) renders as "Unknown" on the clients — NEVER a raw
 * user id. The `user_id` field is here because clients need a stable key for the roster
 * and the LiveKit identity already contains it; it must never be DISPLAYED.
 */
export interface CallRosterEntry {
  user_id: string;
  username: string | null;
  state: CallParticipantState;
  invited_by: string | null;
  is_self: boolean;
}
