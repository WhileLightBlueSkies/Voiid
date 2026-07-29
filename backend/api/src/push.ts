// Content-free "wake" push (Section 10 realtime flow — offline/backgrounded path).
//
// The Redis relay in routes/messages.ts only reaches recipient devices that hold a
// LIVE websocket. Offline or backgrounded devices get nothing. This module fans a
// SILENT, DATA-ONLY push out to those devices so the app wakes, calls the API, and
// fetches + decrypts locally.
//
// PRIVACY GOLDEN RULE (Section 4.14): the push carries NO ciphertext and NO message
// content — only a `type: 'wake'` marker. Apple/Google (and anyone observing the
// push) learn nothing about the message. All plaintext stays E2E on the device.
//
// Robustness: fire-and-forget. Nothing here throws into the caller; every provider
// call is isolated so one dead token never fails the others. Dead tokens (APNs 410 /
// FCM NotRegistered) are logged and cleared so we stop pushing to them.

import http2 from 'http2';
import { readFileSync } from 'fs';
import jwt from 'jsonwebtoken';
import { getFirebaseAdminApp } from './firebase';
import { query } from './db';
import {
  wakeTtlSeconds,
  buildFcmData,
  buildApnsAlertPayload,
  buildApnsAlertHeaders,
  buildVoipPayload,
  buildVoipHeaders,
  voipTopicFor,
} from './pushPayload';

export interface PushTarget {
  push_token: string;
  push_provider: string; // 'apns' | 'fcm'
}

/** An iOS device's PushKit token (distinct from its APNs alert token). */
export interface VoipTarget {
  voip_token: string;
}

/**
 * NON-SECRET routing metadata carried alongside the wake signal (Section 4.14).
 * These are opaque identifiers only — they let the client fetch the right
 * ciphertext and deep-link to the right conversation. They are NOT content:
 * no plaintext, no sender name, no message body, no ciphertext ever rides here.
 */
export interface PushMeta {
  message_id?: string;
  conversation_id?: string;
  // Call ring routing (Section 4.14): NON-SECRET identifiers only, so a
  // backgrounded/offline callee wakes and shows the incoming-call UI. No SDP,
  // no ICE, no SRTP keys, no media — signaling stays on the WS/E2E path.
  type?: string; // 'wake' (default) | 'call' | 'story'
  call_id?: string;
  call_kind?: string; // 'voice' | 'video'
  caller_id?: string;
  // Story routing (Section 4.14): a NON-SECRET identifier so a woken device knows to
  // call GET /stories/feed and pull ITS OWN encrypted key envelope. A caption,
  // thumbnail, author display name, media key, or R2 key here is a privacy-rule
  // violation and must be rejected in review.
  story_id?: string;
  /**
   * True for a PROTOCOL CONTROL message that the user never sent and must never see —
   * map_key / map_off / live_* (docs/LOCATION.md P2), routed as an ordinary message so
   * it rides the ratchet. Without this, enabling Map visibility fired a "New message"
   * banner at everyone in the audience: the NSE can only REPLACE a placeholder alert,
   * never withhold one, so a control message it cannot render as chat was delivered as
   * the generic placeholder.
   *
   * A silent push still WAKES the device (that is the point — the peer must fetch and
   * decrypt the map key); it simply draws no banner. Never set on a real message.
   */
  silent?: boolean;
}

// --- APNs config (token-based .p8 auth over HTTP/2) --------------------------------
const APNS_KEY_ID = process.env.APNS_KEY_ID;
const APNS_TEAM_ID = process.env.APNS_TEAM_ID;
const APNS_BUNDLE_ID = process.env.APNS_BUNDLE_ID;
const APNS_KEY_PATH = process.env.APNS_KEY_PATH;
const APNS_KEY_P8 = process.env.APNS_KEY_P8; // inline PEM alternative to APNS_KEY_PATH
const APNS_ENV = process.env.APNS_ENV ?? 'production'; // 'sandbox' | 'production'

function apnsConfigured(): boolean {
  return !!((APNS_KEY_P8 || APNS_KEY_PATH) && APNS_KEY_ID && APNS_TEAM_ID && APNS_BUNDLE_ID);
}

/**
 * Fan a content-free wake push out to the given devices, split by provider.
 *
 * Fire-and-forget: callers should NOT await this before responding to the client —
 * push delivery must never block (or fail) the HTTP request. Resolves once the
 * provider calls have settled; never rejects.
 */
export async function sendWakePush(devices: PushTarget[], meta?: PushMeta): Promise<void> {
  try {
    if (!devices?.length) return;
    const fcmTokens: string[] = [];
    const apnsTokens: string[] = [];
    for (const d of devices) {
      if (!d?.push_token || !d?.push_provider) continue;
      if (d.push_provider === 'fcm') fcmTokens.push(d.push_token);
      else if (d.push_provider === 'apns') apnsTokens.push(d.push_token);
    }
    await Promise.allSettled([
      fcmTokens.length ? sendFcmWake(fcmTokens, meta) : Promise.resolve(),
      apnsTokens.length ? sendApnsWake(apnsTokens, meta) : Promise.resolve(),
    ]);
  } catch (e) {
    // Belt-and-suspenders: this function must never throw into the caller.
    console.warn('[push] sendWakePush failed:', (e as Error).message);
  }
}

/** Null out a device's VoIP (PushKit) token so we stop pushing to a dead endpoint. */
async function clearDeadVoipToken(token: string): Promise<void> {
  try {
    await query(`update devices set voip_token = null where voip_token = $1`, [token]);
  } catch (e) {
    console.warn('[push] clearDeadVoipToken failed:', (e as Error).message);
  }
}

/** Null out a device's push token so we stop pushing to a dead endpoint. */
async function clearDeadToken(token: string): Promise<void> {
  try {
    await query(`update devices set push_token = null where push_token = $1`, [token]);
  } catch (e) {
    console.warn('[push] clearDeadToken failed:', (e as Error).message);
  }
}

// --- FCM (Android) — data-only, high-priority, wake + routing -----------------------
async function sendFcmWake(tokens: string[], meta?: PushMeta): Promise<void> {
  const app = getFirebaseAdminApp();
  if (!app) {
    console.warn('[push] Firebase Admin not configured; skipping FCM wake');
    return;
  }
  try {
    const { getMessaging } =
      require('firebase-admin/messaging') as typeof import('firebase-admin/messaging');
    // DATA-ONLY (no `notification` block) => silent data message the OS hands to the
    // app's FirebaseMessagingService instead of drawing a banner. `priority: high` lets
    // it wake a dozing app. The client fetches by the routing ids, decrypts locally, and
    // BUILDS the notification itself. NON-SECRET routing metadata only — NO ciphertext,
    // plaintext, sender name, or body (Section 4.14). FCM `data` values must be strings.
    const data = buildFcmData(meta);
    const resp = await getMessaging(app).sendEachForMulticast({
      tokens,
      data,
      // TTL: hold the wake for an offline device and deliver on reconnect. PER TYPE —
      // 28d (FCM's max) for a message, 24h for a story, so a story wake expires with
      // the story instead of waking a device to fetch something already filtered out.
      android: { priority: 'high', ttl: wakeTtlSeconds(meta) * 1000 },
    });
    resp.responses.forEach((r, i) => {
      if (r.success) return;
      const code = r.error?.code ?? '';
      if (
        code === 'messaging/registration-token-not-registered' ||
        code === 'messaging/invalid-registration-token'
      ) {
        console.warn(`[push] fcm dead token (${code}); clearing`);
        void clearDeadToken(tokens[i]);
      } else {
        console.warn(`[push] fcm send failed: ${code || r.error?.message}`);
      }
    });
  } catch (e) {
    console.warn('[push] fcm send batch failed:', (e as Error).message);
  }
}

// --- APNs (iOS) — background/silent push over HTTP/2 --------------------------------

// One provider auth JWT (ES256, signed with the .p8 key) is reused for ~40min per
// Apple's guidance (valid 60min, refresh no more than once every 20min).
let cachedAuth: { token: string; iat: number } | null = null;
function apnsAuthToken(): string {
  const now = Math.floor(Date.now() / 1000);
  if (cachedAuth && now - cachedAuth.iat < 40 * 60) return cachedAuth.token;
  const key = APNS_KEY_P8 ?? readFileSync(APNS_KEY_PATH as string, 'utf8');
  const token = jwt.sign({ iss: APNS_TEAM_ID }, key, {
    algorithm: 'ES256',
    keyid: APNS_KEY_ID,
  });
  cachedAuth = { token, iat: now };
  return token;
}

function apnsHost(): string {
  return APNS_ENV === 'sandbox'
    ? 'https://api.sandbox.push.apple.com'
    : 'https://api.push.apple.com';
}

// Reuse a single HTTP/2 session across pushes; re-open lazily if it drops.
let apnsSession: http2.ClientHttp2Session | null = null;
function getApnsSession(): http2.ClientHttp2Session {
  if (apnsSession && !apnsSession.closed && !apnsSession.destroyed) return apnsSession;
  const session = http2.connect(apnsHost());
  session.on('error', (e) => console.warn('[push] apns session error:', e.message));
  session.on('close', () => {
    if (apnsSession === session) apnsSession = null;
  });
  apnsSession = session;
  return session;
}

async function sendApnsWake(tokens: string[], meta?: PushMeta): Promise<void> {
  if (!apnsConfigured()) {
    console.warn('[push] APNs not configured; skipping APNs wake');
    return;
  }
  let auth: string;
  try {
    auth = apnsAuthToken();
  } catch (e) {
    console.warn('[push] apns auth token failed:', (e as Error).message);
    return;
  }
  await Promise.allSettled(tokens.map((t) => apnsSendOne(t, auth, meta)));
}

/**
 * Send one NSE-triggering alert push; resolves regardless of outcome (never rejects).
 *
 * iOS silent (content-available) pushes are throttled/coalesced and unreliable, so the
 * message-arrival push is an ALERT with `mutable-content: 1`. That guarantees delivery
 * AND wakes a Notification Service Extension, which fetches by the routing ids, decrypts
 * locally, and REPLACES the placeholder alert with the real notification before display.
 * The generic "New message" title is only a placeholder; routing keys are NON-SECRET
 * top-level customs. NO ciphertext, plaintext, sender name, or body ships here (§4.14).
 */
function apnsSendOne(token: string, auth: string, meta?: PushMeta): Promise<void> {
  return new Promise((resolve) => {
    // Offline TTL: hold the alert for up to 28 days (24h for a story) and deliver on
    // reconnect (absolute UNIX epoch seconds, per APNs `apns-expiration` semantics).
    let req: http2.ClientHttp2Stream;
    try {
      const session = getApnsSession();
      req = session.request(
        buildApnsAlertHeaders({ token, auth, topic: APNS_BUNDLE_ID as string, meta })
      );
    } catch (e) {
      console.warn('[push] apns request setup failed:', (e as Error).message);
      return resolve();
    }

    let status = 0;
    let body = '';
    req.on('response', (headers) => {
      status = Number(headers[':status']) || 0;
    });
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      body += chunk;
    });
    req.on('error', (e) => {
      console.warn('[push] apns request error:', (e as Error).message);
      resolve();
    });
    req.on('end', () => {
      if (status === 200) return resolve();
      let reason = '';
      try {
        reason = JSON.parse(body)?.reason ?? '';
      } catch {
        /* non-JSON error body */
      }
      // 410 (or 400 BadDeviceToken / Unregistered) => token is dead: clear it.
      if (status === 410 || reason === 'Unregistered' || reason === 'BadDeviceToken') {
        console.warn(`[push] apns dead token (${status} ${reason}); clearing`);
        void clearDeadToken(token);
      } else {
        console.warn(`[push] apns send failed (${status} ${reason})`);
      }
      resolve();
    });

    // NSE-triggering alert payload. `mutable-content: 1` wakes the Notification Service
    // Extension so it can decrypt + rewrite the notification before it's shown; the
    // generic alert is a placeholder the NSE replaces. `message_id`/`conversation_id`
    // are NON-SECRET top-level routing customs the NSE (and the app on tap) read — never
    // any ciphertext or message content (Section 4.14).
    req.end(JSON.stringify(buildApnsAlertPayload(meta)));
  });
}

// --- APNs VoIP / PushKit (iOS) — CALL RINGING ONLY ---------------------------------
//
// WHY a second push path exists (Section 4.14, calls):
//   A normal alert push (sendWakePush above) is fine for messages but CANNOT reliably
//   ring a call. If the iOS app is killed or has been backgrounded a while, an alert
//   push only draws a banner — the process is not resumed in time to set up WebRTC,
//   and iOS will not let a non-foreground app start audio. A VoIP push (PushKit) is
//   the only mechanism that resumes a TERMINATED app immediately and lets it report
//   the incoming call to CallKit. iOS *requires* that report: receiving a VoIP push
//   and failing to call `CXProvider.reportNewIncomingCall` kills the app.
//
// It differs from the alert path in three ways that all matter:
//   1. `apns-push-type: voip` (not `alert`)
//   2. topic = `<bundle-id>.voip` — a DIFFERENT topic from the app's bundle id
//   3. a DIFFERENT device token (PushKit token != APNs token) and, usually, a
//      different APNs signing key.
//
// PRIVACY: payload is content-free — opaque routing ids only. No SDP, no ICE, no
// SRTP keys, no caller name, no message content. Identical guarantee to the wake push.

// VoIP-specific APNs credentials. Each falls back to the normal APNs credential when
// unset, so a deployment that reuses one key/team across both topics only needs to set
// VOIID_APNS_VOIP_TOPIC (or nothing at all — the topic defaults to `<bundle>.voip`).
const VOIP_KEY_ID = process.env.VOIID_APNS_VOIP_KEY_ID ?? APNS_KEY_ID;
const VOIP_TEAM_ID = process.env.VOIID_APNS_VOIP_TEAM_ID ?? APNS_TEAM_ID;
const VOIP_KEY_PATH = process.env.VOIID_APNS_VOIP_KEY_PATH ?? APNS_KEY_PATH;
const VOIP_KEY_P8 = process.env.VOIID_APNS_VOIP_P8 ?? APNS_KEY_P8;
// The VoIP topic is the bundle id with a `.voip` suffix — NOT the plain bundle id.
// Sending a voip push to the plain topic is rejected by APNs (TopicDisallowed).
const VOIP_TOPIC = process.env.VOIID_APNS_VOIP_TOPIC ?? voipTopicFor(APNS_BUNDLE_ID);

export function voipConfigured(): boolean {
  return !!((VOIP_KEY_P8 || VOIP_KEY_PATH) && VOIP_KEY_ID && VOIP_TEAM_ID && VOIP_TOPIC);
}

// Separate provider-JWT cache: the VoIP key may be a different .p8 with a different
// key id, so its bearer token cannot be shared with the alert path.
let cachedVoipAuth: { token: string; iat: number } | null = null;
function voipAuthToken(): string {
  const now = Math.floor(Date.now() / 1000);
  if (cachedVoipAuth && now - cachedVoipAuth.iat < 40 * 60) return cachedVoipAuth.token;
  const key = VOIP_KEY_P8 ?? readFileSync(VOIP_KEY_PATH as string, 'utf8');
  const token = jwt.sign({ iss: VOIP_TEAM_ID }, key, { algorithm: 'ES256', keyid: VOIP_KEY_ID });
  cachedVoipAuth = { token, iat: now };
  return token;
}

/**
 * Ring iOS devices via PushKit. Fire-and-forget; never rejects.
 *
 * `meta` carries ONLY non-secret routing ids. Returns the number of tokens attempted
 * so the caller can fall back to the alert path when nothing was VoIP-deliverable.
 */
export async function sendVoipPush(tokens: string[], meta?: PushMeta): Promise<number> {
  try {
    const list = tokens.filter(Boolean);
    if (!list.length) return 0;
    if (!voipConfigured()) {
      console.warn('[push] APNs VoIP not configured; skipping VoIP ring');
      return 0;
    }
    let auth: string;
    try {
      auth = voipAuthToken();
    } catch (e) {
      console.warn('[push] voip auth token failed:', (e as Error).message);
      return 0;
    }
    await Promise.allSettled(list.map((t) => voipSendOne(t, auth, meta)));
    return list.length;
  } catch (e) {
    console.warn('[push] sendVoipPush failed:', (e as Error).message);
    return 0;
  }
}

/** Send one VoIP push; resolves regardless of outcome (never rejects). */
function voipSendOne(token: string, auth: string, meta?: PushMeta): Promise<void> {
  return new Promise((resolve) => {
    // A ring is only meaningful while the caller is still waiting. Unlike the 28-day
    // message wake, expire this in ~30s so a device that comes back online tomorrow
    // is NOT resumed to ring a long-dead call (which would crash it against CallKit).
    let req: http2.ClientHttp2Stream;
    try {
      // Same APNs host as the alert path, so the HTTP/2 session is shared — APNs
      // multiplexes topics over one connection; the topic is a per-request header.
      const session = getApnsSession();
      req = session.request(buildVoipHeaders({ token, auth, topic: VOIP_TOPIC as string }));
    } catch (e) {
      console.warn('[push] voip request setup failed:', (e as Error).message);
      return resolve();
    }

    let status = 0;
    let body = '';
    req.on('response', (headers) => {
      status = Number(headers[':status']) || 0;
    });
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      body += chunk;
    });
    req.on('error', (e) => {
      console.warn('[push] voip request error:', (e as Error).message);
      resolve();
    });
    req.on('end', () => {
      if (status === 200) return resolve();
      let reason = '';
      try {
        reason = JSON.parse(body)?.reason ?? '';
      } catch {
        /* non-JSON error body */
      }
      if (status === 410 || reason === 'Unregistered' || reason === 'BadDeviceToken') {
        console.warn(`[push] voip dead token (${status} ${reason}); clearing`);
        void clearDeadVoipToken(token);
      } else {
        console.warn(`[push] voip send failed (${status} ${reason})`);
      }
      resolve();
    });

    // CONTENT-FREE VoIP payload. No `aps.alert` — PushKit hands this dictionary
    // straight to the app, which builds the CallKit UI itself from the routing ids.
    // NON-SECRET identifiers only (Section 4.14).
    req.end(JSON.stringify(buildVoipPayload(meta)));
  });
}
