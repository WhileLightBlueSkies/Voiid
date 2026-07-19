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

export interface PushTarget {
  push_token: string;
  push_provider: string; // 'apns' | 'fcm'
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
}

// FCM's maximum (and default) hold time for an undelivered message: 28 days, in
// milliseconds. An offline device still receives the wake on reconnect within this window.
const OFFLINE_TTL_MS = 2419200000; // 28 days

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
    const data: Record<string, string> = { type: 'wake' };
    if (meta?.message_id) data.message_id = meta.message_id;
    if (meta?.conversation_id) data.conversation_id = meta.conversation_id;
    const resp = await getMessaging(app).sendEachForMulticast({
      tokens,
      data,
      // TTL: hold the wake for an offline device and deliver on reconnect (28d max).
      android: { priority: 'high', ttl: OFFLINE_TTL_MS },
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
    // Offline TTL: hold the alert for up to 28 days and deliver on reconnect (absolute
    // UNIX epoch seconds, per APNs `apns-expiration` semantics).
    const expiration = Math.floor((Date.now() + OFFLINE_TTL_MS) / 1000);
    let req: http2.ClientHttp2Stream;
    try {
      const session = getApnsSession();
      req = session.request({
        ':method': 'POST',
        ':path': `/3/device/${token}`,
        authorization: `bearer ${auth}`,
        'apns-topic': APNS_BUNDLE_ID as string,
        'apns-push-type': 'alert', // alert delivery (reliable; triggers the NSE)
        'apns-priority': '10', // deliver immediately
        'apns-expiration': String(expiration),
      });
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
    const payload: Record<string, unknown> = {
      aps: {
        'mutable-content': 1,
        alert: { title: 'New message' },
        sound: 'default',
      },
    };
    if (meta?.message_id) payload.message_id = meta.message_id;
    if (meta?.conversation_id) payload.conversation_id = meta.conversation_id;
    req.end(JSON.stringify(payload));
  });
}
