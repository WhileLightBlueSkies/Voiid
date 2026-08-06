// Push payload + header construction, extracted from push.ts.
//
// WHY SEPARATE: the "content-free push" guarantee (Section 4.14) is the single most
// privacy-load-bearing property of the notification path — Apple and Google see every
// one of these payloads. Building them in a pure module means the guarantee can be
// asserted by tests ("no key outside this allowlist ever appears") instead of being
// re-verified by eye inside an http2 callback.
//
// The rule these builders enforce: ONLY opaque routing identifiers ship. No message
// text, no ciphertext, no sender name, no SDP, no ICE candidates, no SRTP keys.

import type { PushMeta } from './push';

/**
 * FCM's maximum (and default) hold time for an undelivered message: 28 days, in ms.
 * An offline device still receives the wake on reconnect within this window.
 */
export const OFFLINE_TTL_MS = 2419200000; // 28 days

/**
 * A ring is only meaningful while the caller is still waiting. Unlike the 28-day
 * message wake, a VoIP push expires in ~30s so a device that comes back online
 * tomorrow is NOT resumed to ring a long-dead call (which would crash it against
 * CallKit's "must report every VoIP push" requirement).
 */
export const VOIP_TTL_SECONDS = 30;

/**
 * The FCM/APNs-alert ring path needs the same short life as the VoIP one above. A ring
 * is dead the moment the caller gives up — iOS caps an incoming ring at 45s
 * (`CallService.incomingRingCap`) — so a device that comes back online tomorrow must
 * not be woken to full-screen-ring a call that ended last week. Worse than cosmetic:
 * the relay's offer buffer expires in 60s, so a late-delivered ring is unanswerable —
 * the callee accepts into nothing and hangs. 60s = the 45s ring cap plus delivery slack.
 */
export const CALL_RING_TTL_SECONDS = 60;

/**
 * A story is dead after 24h, so holding its wake push for the default 28 days is
 * wrong twice over: the device would be woken to fetch a story the feed query has
 * already filtered out (`expires_at > now()`), and the push would sit in Apple's /
 * Google's queue long after the content it refers to stopped existing. Per-type TTLs
 * are established practice here — VOIP_TTL_SECONDS above is the precedent.
 */
export const STORY_TTL_SECONDS = 86400; // 24h — matches stories.expires_at

/**
 * The complete set of keys allowed to leave the server in ANY push payload, at any
 * nesting level. Tests assert payloads against this (test/pushPayload.test.ts);
 * anything new must be added here deliberately (and must be a non-secret routing
 * identifier). A caption, thumbnail, author display name, or any part of a story
 * envelope belongs NOWHERE in this list.
 */
export const ALLOWED_PUSH_KEYS = [
  'aps',
  'mutable-content',
  // Silent control-message wake (no banner) — see `silent` in PushMeta.
  'content-available',
  'alert',
  'title',
  'sound',
  'type',
  'message_id',
  'conversation_id',
  'call_id',
  'call_kind',
  'caller_id',
  'story_id',
] as const;

/**
 * Offline hold time for a wake push, in seconds, by notification type. Shared by the
 * APNs `apns-expiration` header and the FCM `ttl`, so the two transports cannot drift.
 */
export function wakeTtlSeconds(meta?: PushMeta): number {
  if (meta?.type === 'story') return STORY_TTL_SECONDS;
  if (meta?.type === 'call' || meta?.type === 'group_call') return CALL_RING_TTL_SECONDS;
  return Math.floor(OFFLINE_TTL_MS / 1000);
}

/**
 * FCM data-only wake payload. No `notification` block => the OS hands it silently to
 * the app instead of drawing a banner; the client fetches, decrypts locally and
 * builds the notification itself. FCM `data` values must be strings.
 */
export function buildFcmData(meta?: PushMeta): Record<string, string> {
  const data: Record<string, string> = { type: meta?.type ?? 'wake' };
  if (meta?.message_id) data.message_id = meta.message_id;
  if (meta?.conversation_id) data.conversation_id = meta.conversation_id;
  // Call ring routing (non-secret) — lets the app show the incoming-call UI.
  if (meta?.call_id) data.call_id = meta.call_id;
  if (meta?.call_kind) data.call_kind = meta.call_kind;
  if (meta?.caller_id) data.caller_id = meta.caller_id;
  // FCM data values must be strings — a boolean here is dropped silently by the SDK.
  if (meta?.conference) data.conference = 'true';
  // Story routing (non-secret): the woken client calls GET /stories/feed and pulls
  // its own encrypted key envelope. NOTHING about the story's content ships here.
  if (meta?.story_id) data.story_id = meta.story_id;
  return data;
}

/**
 * NSE-triggering APNs ALERT payload (message arrival, and the non-PushKit call ring
 * fallback). `mutable-content: 1` wakes the Notification Service Extension so it can
 * decrypt and REPLACE the placeholder title before display — which is why the title
 * here is a generic constant and never carries a sender or a body.
 */
export function buildApnsAlertPayload(meta?: PushMeta): Record<string, unknown> {
  // CONTROL MESSAGES DRAW NO BANNER. A map_key / map_off rides the ordinary message
  // route so it can use the ratchet, but the user never sent it and must never see it.
  // `content-available: 1` with NO `alert` and NO `sound` wakes the app to fetch and
  // decrypt silently. This must be decided HERE, not in the NSE: the extension can only
  // replace a placeholder alert, never suppress one, so anything alert-shaped that
  // reaches it is already a visible notification.
  if (meta?.silent) {
    const payload: Record<string, unknown> = { aps: { 'content-available': 1 } };
    if (meta.type) payload.type = meta.type;
    if (meta.message_id) payload.message_id = meta.message_id;
    if (meta.conversation_id) payload.conversation_id = meta.conversation_id;
    return payload;
  }
  // Constant placeholder per type — never an author name, caption, or thumbnail.
  // "New update" for a story is deliberately vague: the NSE replaces it after it has
  // fetched and decrypted the envelope LOCALLY, so the only string Apple ever sees is
  // this one, identical for every story from every author.
  const title =
    meta?.type === 'call' ? 'Incoming call'
      : meta?.type === 'group_call' ? 'Group call · tap to join'
      : meta?.type === 'story' ? 'New update'
      : 'New message';
  const payload: Record<string, unknown> = {
    aps: {
      'mutable-content': 1,
      // Generic placeholder title (no sender/content); the NSE replaces it.
      alert: { title },
      sound: 'default',
    },
  };
  if (meta?.type) payload.type = meta.type;
  if (meta?.message_id) payload.message_id = meta.message_id;
  if (meta?.conversation_id) payload.conversation_id = meta.conversation_id;
  if (meta?.call_id) payload.call_id = meta.call_id;
  if (meta?.call_kind) payload.call_kind = meta.call_kind;
  if (meta?.caller_id) payload.caller_id = meta.caller_id;
  if (meta?.story_id) payload.story_id = meta.story_id;
  return payload;
}

/**
 * CONTENT-FREE PushKit payload. No `aps.alert` at all — PushKit hands the dictionary
 * straight to the app, which builds the CallKit UI itself from the routing ids.
 */
export function buildVoipPayload(meta?: PushMeta): Record<string, unknown> {
  const payload: Record<string, unknown> = { aps: {}, type: 'call' };
  if (meta?.call_id) payload.call_id = meta.call_id;
  if (meta?.call_kind) payload.call_kind = meta.call_kind;
  if (meta?.conversation_id) payload.conversation_id = meta.conversation_id;
  if (meta?.caller_id) payload.caller_id = meta.caller_id;
  // A conference invite rides the same VoIP push as a 1:1 ring so CallKit still reports it
  // correctly; the flag is what stops the client arming an offer timeout for an offer that
  // is never coming. JSON, not FCM data, so a real boolean is fine here.
  if (meta?.conference) payload.conference = true;
  return payload;
}

export type ApnsHeaders = Record<string, string>;

/**
 * APNs HTTP/2 headers for the alert path: `alert` push type, and a PER-TYPE expiry —
 * 28 days for a message wake, 24h for a story, 60s for a ring (see wakeTtlSeconds).
 * Passing `meta` is optional so existing callers keep the 28-day behaviour byte for byte.
 */
export function buildApnsAlertHeaders(args: {
  token: string;
  auth: string;
  topic: string;
  nowMs?: number;
  meta?: PushMeta;
}): ApnsHeaders {
  const expiration = Math.floor((args.nowMs ?? Date.now()) / 1000) + wakeTtlSeconds(args.meta);
  return {
    ':method': 'POST',
    ':path': `/3/device/${args.token}`,
    authorization: `bearer ${args.auth}`,
    'apns-topic': args.topic,
    // A `content-available` payload MUST be sent as push-type `background`, and APNs
    // rejects `background` at priority 10 (BadPriority) — so a silent control wake goes
    // out at 5. Mismatching either header against the payload is an APNs 400, i.e. the
    // map key would never arrive at all.
    'apns-push-type': args.meta?.silent ? 'background' : 'alert',
    'apns-priority': args.meta?.silent ? '5' : '10',
    'apns-expiration': String(expiration),
  };
}

/**
 * APNs HTTP/2 headers for the VoIP path. Three things differ from the alert path and
 * all three matter: push type `voip`, the `<bundle-id>.voip` topic (the plain bundle
 * id is rejected with TopicDisallowed), and a ~30s expiry instead of 28 days.
 */
export function buildVoipHeaders(args: {
  token: string;
  auth: string;
  topic: string;
  nowMs?: number;
}): ApnsHeaders {
  const expiration = Math.floor((args.nowMs ?? Date.now()) / 1000) + VOIP_TTL_SECONDS;
  return {
    ':method': 'POST',
    ':path': `/3/device/${args.token}`,
    authorization: `bearer ${args.auth}`,
    'apns-topic': args.topic, // `<bundle-id>.voip`
    'apns-push-type': 'voip',
    'apns-priority': '10', // immediate; VoIP pushes are never throttled
    'apns-expiration': String(expiration),
  };
}

/** Derive the VoIP topic from the app bundle id. NOT the plain bundle id. */
export function voipTopicFor(bundleId: string | undefined): string | undefined {
  return bundleId ? `${bundleId}.voip` : undefined;
}
