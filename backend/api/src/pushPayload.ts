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
 * The complete set of keys allowed to leave the server in ANY push payload, at any
 * nesting level. Tests assert payloads against this; anything new must be added here
 * deliberately (and must be a non-secret routing identifier).
 */
export const ALLOWED_PUSH_KEYS = [
  'aps',
  'mutable-content',
  'alert',
  'title',
  'sound',
  'type',
  'message_id',
  'conversation_id',
  'call_id',
  'call_kind',
  'caller_id',
] as const;

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
  return data;
}

/**
 * NSE-triggering APNs ALERT payload (message arrival, and the non-PushKit call ring
 * fallback). `mutable-content: 1` wakes the Notification Service Extension so it can
 * decrypt and REPLACE the placeholder title before display — which is why the title
 * here is a generic constant and never carries a sender or a body.
 */
export function buildApnsAlertPayload(meta?: PushMeta): Record<string, unknown> {
  const isCall = meta?.type === 'call';
  const payload: Record<string, unknown> = {
    aps: {
      'mutable-content': 1,
      // Generic placeholder title (no sender/content); the NSE replaces it.
      alert: { title: isCall ? 'Incoming call' : 'New message' },
      sound: 'default',
    },
  };
  if (meta?.type) payload.type = meta.type;
  if (meta?.message_id) payload.message_id = meta.message_id;
  if (meta?.conversation_id) payload.conversation_id = meta.conversation_id;
  if (meta?.call_id) payload.call_id = meta.call_id;
  if (meta?.call_kind) payload.call_kind = meta.call_kind;
  if (meta?.caller_id) payload.caller_id = meta.caller_id;
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
  return payload;
}

export type ApnsHeaders = Record<string, string>;

/** APNs HTTP/2 headers for the alert path: 28-day expiry, `alert` push type. */
export function buildApnsAlertHeaders(args: {
  token: string;
  auth: string;
  topic: string;
  nowMs?: number;
}): ApnsHeaders {
  const expiration = Math.floor(((args.nowMs ?? Date.now()) + OFFLINE_TTL_MS) / 1000);
  return {
    ':method': 'POST',
    ':path': `/3/device/${args.token}`,
    authorization: `bearer ${args.auth}`,
    'apns-topic': args.topic,
    'apns-push-type': 'alert', // alert delivery (reliable; triggers the NSE)
    'apns-priority': '10', // deliver immediately
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
