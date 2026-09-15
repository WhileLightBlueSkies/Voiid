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
  community_id?: string;
  community_handle?: string;
  message_id?: string;
  conversation_id?: string;
  // Call ring routing (Section 4.14): NON-SECRET identifiers only, so a
  // backgrounded/offline callee wakes and shows the incoming-call UI. No SDP,
  // no ICE, no SRTP keys, no media — signaling stays on the WS/E2E path.
  type?: string; // 'wake' (default) | 'call' | 'story'
  call_id?: string;
  /**
   * TRUE when this ring is an invitation to join an ad-hoc CONFERENCE rather than a 1:1
   * call. It rides the same `type: 'call'` push on purpose — CallKit/Telecom, the
   * full-screen intent, the system call log and the ringtone all keep working with no
   * second code path — but the client MUST route it differently once it lands:
   *
   *   * a 1:1 ring promises an SDP offer over the socket within seconds, and the clients
   *     arm an offer timeout that ends the call when none arrives;
   *   * a conference invitee NEVER receives an offer — it joins the SFU by fetching a
   *     token — so that timeout would reliably kill every invite about 30s in.
   *
   * Without this flag the two are indistinguishable at the push layer, so a
   * FCM/VoIP-woken invitee was routed into the 1:1 handler and the invite always died.
   * The conference-invite handlers on both clients were only reachable over the
   * WebSocket, which a backgrounded or killed device does not have.
   */
  conference?: boolean;
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

/**
 * Strikes against a push token, in memory, keyed by the token itself.
 *
 * A wrongly-cleared token leaves the device RING-DEAF until something happens to
 * re-register it — the user may not find out until they notice they stopped getting calls.
 * That asymmetry is why one "not registered" response is not enough: the providers do
 * occasionally return it transiently, and the cost of believing a false one is far higher
 * than the cost of one extra wasted send to a token that really is dead.
 *
 * In memory on purpose. Strikes are a debounce, not a record: a restart losing them means
 * at worst a genuinely dead token survives one more send before being cleared, and putting
 * them in Postgres or Redis would add a write to every failed push to buy nothing.
 */
const deadTokenStrikes = new Map<string, { count: number; first: number }>();

/** A strike older than this is stale evidence about a token that has since been fine. */
const STRIKE_WINDOW_MS = 60 * 60 * 1000;
/** Consecutive rejections required before a token is actually cleared. */
const STRIKES_TO_CLEAR = 2;

/**
 * Record a provider rejection, and clear the token only once it has been rejected
 * [STRIKES_TO_CLEAR] times inside [STRIKE_WINDOW_MS].
 */
async function clearDeadToken(token: string): Promise<void> {
  const now = Date.now();
  const prior = deadTokenStrikes.get(token);
  const strike = prior && now - prior.first < STRIKE_WINDOW_MS
    ? { count: prior.count + 1, first: prior.first }
    : { count: 1, first: now };

  if (strike.count < STRIKES_TO_CLEAR) {
    deadTokenStrikes.set(token, strike);
    console.warn(`[push] dead-token strike ${strike.count}/${STRIKES_TO_CLEAR}; not clearing yet`);
    return;
  }

  deadTokenStrikes.delete(token);
  try {
    await query(`update devices set push_token = null where push_token = $1`, [token]);
    console.warn('[push] token cleared after repeated provider rejection');
  } catch (e) {
    console.warn('[push] clearDeadToken failed:', (e as Error).message);
  }
}

/**
 * Forget a token's strikes after a successful send — the strikes must be CONSECUTIVE, or a
 * token that fails once a month would eventually accumulate two and be cleared while working
 * perfectly well.
 */
function noteTokenAlive(token: string): void {
  if (deadTokenStrikes.size) deadTokenStrikes.delete(token);
}

// --- FCM (Android) — data-only, high-priority, wake + routing -----------------------
export async function sendFcmWake(tokens: string[], meta?: PushMeta, retryable = false): Promise<void> {
  const app = getFirebaseAdminApp();
  if (!app) {
    console.warn('[push] Firebase Admin not configured; skipping FCM wake');
    if (retryable) throw new Error('Firebase Admin is not configured');
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
      // A success ends any strike streak — see noteTokenAlive.
      if (r.success) return noteTokenAlive(tokens[i]);
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
    if (retryable && resp.responses.some(r => !r.success && ![
      'messaging/registration-token-not-registered', 'messaging/invalid-registration-token',
    ].includes(r.error?.code ?? ''))) throw new Error('FCM rejected one or more notifications');
  } catch (e) {
    console.warn('[push] fcm send batch failed:', (e as Error).message);
    if (retryable) throw e;
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

const APNS_PROD_HOST = 'https://api.push.apple.com';
const APNS_SANDBOX_HOST = 'https://api.sandbox.push.apple.com';

function apnsHost(): string {
  return APNS_ENV === 'sandbox' ? APNS_SANDBOX_HOST : APNS_PROD_HOST;
}

function otherApnsHost(host: string): string {
  return host === APNS_SANDBOX_HOST ? APNS_PROD_HOST : APNS_SANDBOX_HOST;
}

/**
 * WHICH GATEWAY A GIVEN DEVICE TOKEN BELONGS TO.
 *
 * An APNs token carries no marker saying which environment issued it, and the two
 * gateways do not accept each other's: production answers a sandbox token with
 * `BadDeviceToken`, and vice versa. `APNS_ENV` is therefore a guess that is right for
 * exactly one kind of build at a time — and a deployment serves both at once. A debug
 * build installed from Xcode is signed `aps-environment: development` (automatic signing
 * rewrites the entitlement) and mints a SANDBOX token, while the TestFlight and App Store
 * builds of the same app mint PRODUCTION ones.
 *
 * Making that an env var to flip is a footgun: the flip has to be remembered before every
 * release, and forgetting it breaks push for real users with no error anyone sees —
 * `BadDeviceToken` is indistinguishable from a genuinely dead token, so the old code
 * DELETED the token and the device went permanently silent.
 *
 * So the gateway is DISCOVERED instead. `APNS_ENV` remains the first guess; on a
 * `BadDeviceToken` we retry once against the other host, and remember the answer per
 * token. Only a token both gateways reject is treated as dead.
 */
const apnsHostForToken = new Map<string, string>();

/** Bound so a long-lived process cannot accumulate one entry per token forever. */
const APNS_HOST_CACHE_MAX = 20_000;
function rememberApnsHost(token: string, host: string): void {
  if (apnsHostForToken.size >= APNS_HOST_CACHE_MAX) apnsHostForToken.clear();
  apnsHostForToken.set(token, host);
}

// Reuse one HTTP/2 session PER HOST across pushes; re-open lazily if it drops. Keyed by
// host because both gateways can legitimately be in use at once (a dev build and a
// TestFlight build of the same app), and a single shared slot would thrash between them.
const apnsSessions = new Map<string, http2.ClientHttp2Session>();
function getApnsSession(host: string = apnsHost()): http2.ClientHttp2Session {
  const existing = apnsSessions.get(host);
  if (existing && !existing.closed && !existing.destroyed) return existing;
  const session = http2.connect(host);
  session.on('error', (e) => {
    console.warn(`[push] apns session error (${host}):`, e.message);
    // EVICT AND DESTROY, don't just log.
    //
    // An errored HTTP/2 session is not necessarily `closed` or `destroyed`, so the cache
    // check above happily handed the same dead session to every subsequent send — and each
    // one failed with "the pending stream has been canceled", forever, until the process
    // restarted. One transient network blip therefore took the whole APNs path down
    // permanently, which is precisely what the logs show.
    if (apnsSessions.get(host) === session) apnsSessions.delete(host);
    if (!session.destroyed) session.destroy();
  });
  // A GOAWAY is the server telling us this connection is finished. Without handling it the
  // session lingers in the cache in a state that is neither usable nor closed.
  session.on('goaway', () => {
    if (apnsSessions.get(host) === session) apnsSessions.delete(host);
    if (!session.destroyed) session.destroy();
  });
  session.on('close', () => {
    if (apnsSessions.get(host) === session) apnsSessions.delete(host);
  });
  apnsSessions.set(host, session);
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
/**
 * Send to the gateway this token is known (or guessed) to belong to, retrying once
 * against the other one if APNs says the token does not belong here. See
 * `apnsHostForToken` for why the environment is discovered rather than configured.
 */
function apnsSendOne(token: string, auth: string, meta?: PushMeta): Promise<void> {
  const host = apnsHostForToken.get(token) ?? apnsHost();
  return apnsSendOneTo(token, auth, host, meta);
}

function apnsSendOneTo(
  token: string,
  auth: string,
  host: string,
  meta: PushMeta | undefined,
  isRetry = false
): Promise<void> {
  return new Promise((resolve) => {
    // Offline TTL: hold the alert for up to 28 days (24h for a story) and deliver on
    // reconnect (absolute UNIX epoch seconds, per APNs `apns-expiration` semantics).
    let req: http2.ClientHttp2Stream;
    try {
      const session = getApnsSession(host);
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
      const msg = (e as Error).message;
      console.warn('[push] apns request error:', msg);
      // A stream cancelled underneath us means the SESSION died, not that the token is
      // bad. The session has already been evicted by its own error handler, so one retry
      // gets a fresh connection — without this, every push queued against a dying
      // connection was silently lost.
      if (!isRetry && /cancel|GOAWAY|closed/i.test(msg)) {
        return resolve(apnsSendOneTo(token, auth, host, meta, true));
      }
      resolve();
    });
    req.on('end', () => {
      if (status === 200) {
        rememberApnsHost(token, host);   // this gateway owns the token — stop guessing
        noteTokenAlive(token);           // a success ends any strike streak
        return resolve();
      }
      let reason = '';
      try {
        reason = JSON.parse(body)?.reason ?? '';
      } catch {
        /* non-JSON error body */
      }
      // BadDeviceToken is AMBIGUOUS: it is what APNs says both for a malformed/dead token
      // and for a perfectly live token sent to the wrong gateway. Retry once on the other
      // host before believing it — clearing here is what made a sandbox-token device
      // permanently unreachable the first time it was pushed to.
      if (reason === 'BadDeviceToken' && !isRetry) {
        const alt = otherApnsHost(host);
        console.warn(`[push] apns BadDeviceToken on ${host}; retrying on ${alt}`);
        return resolve(apnsSendOneTo(token, auth, alt, meta, true));
      }
      // 410 Unregistered is unambiguous (the app was uninstalled), and a BadDeviceToken
      // that BOTH gateways refuse really is a dead token.
      if (status === 410 || reason === 'Unregistered' || reason === 'BadDeviceToken') {
        console.warn(`[push] apns dead token (${status} ${reason}); clearing`);
        apnsHostForToken.delete(token);
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
  return voipSendOneTo(token, auth, apnsHostForToken.get(token) ?? apnsHost(), meta);
}

function voipSendOneTo(
  token: string,
  auth: string,
  host: string,
  meta: PushMeta | undefined,
  isRetry = false
): Promise<void> {
  return new Promise((resolve) => {
    // A ring is only meaningful while the caller is still waiting. Unlike the 28-day
    // message wake, expire this in ~30s so a device that comes back online tomorrow
    // is NOT resumed to ring a long-dead call (which would crash it against CallKit).
    let req: http2.ClientHttp2Stream;
    try {
      // Same APNs host as the alert path, so the HTTP/2 session is shared — APNs
      // multiplexes topics over one connection; the topic is a per-request header.
      //
      // A PushKit token is a DIFFERENT token from the alert one, so it gets its own
      // cache entry rather than borrowing the alert token's. Same environment rule
      // applies: a development-signed build mints sandbox tokens on both channels.
      const session = getApnsSession(host);
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
      const msg = (e as Error).message;
      console.warn('[push] voip request error:', msg);
      // Same transport-vs-verdict distinction as the alert path above. A lost ring is
      // a missed call, so this retry matters more here than anywhere else.
      if (!isRetry && /cancel|GOAWAY|closed/i.test(msg)) {
        return resolve(voipSendOneTo(token, auth, host, meta, true));
      }
      resolve();
    });
    req.on('end', () => {
      if (status === 200) {
        rememberApnsHost(token, host);
        return resolve();
      }
      let reason = '';
      try {
        reason = JSON.parse(body)?.reason ?? '';
      } catch {
        /* non-JSON error body */
      }
      // Ambiguous exactly as on the alert path — try the other gateway before concluding
      // the token is dead. Losing a VoIP token silently means calls stop ringing.
      if (reason === 'BadDeviceToken' && !isRetry) {
        const alt = otherApnsHost(host);
        console.warn(`[push] voip BadDeviceToken on ${host}; retrying on ${alt}`);
        return resolve(voipSendOneTo(token, auth, alt, meta, true));
      }
      if (status === 410 || reason === 'Unregistered' || reason === 'BadDeviceToken') {
        console.warn(`[push] voip dead token (${status} ${reason}); clearing`);
        apnsHostForToken.delete(token);
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

// ═════════════════════════════════════════════════════════════════════════════════
//  ADMIN BROADCAST
// ═════════════════════════════════════════════════════════════════════════════════
//
// ── WHY THIS IS A SEPARATE PATH, AND MUST STAY ONE ────────────────────────────────
// Everything above is CONTENT-FREE by design: a wake push carries opaque routing ids and
// the client fetches and decrypts the real thing. That rule protects message content, and
// §4.14 states it plainly — no plaintext, no sender name, no body, ever.
//
// An operator announcement is the opposite by nature. Its text IS the payload: there is no
// ciphertext on the server for a client to fetch, and nothing to decrypt. That is legitimate
// — an announcement is not a private message and carries no E2E promise — but it must never
// be reached by widening `sendWakePush`, or the next person to read this file will conclude
// that message pushes may carry text too.
//
// So: one function, one door, and the distinction stated where both are visible.
//
// ── WHAT MUST NEVER RIDE HERE ─────────────────────────────────────────────────────
// Operator-authored copy only. Never a message body, a sender's name, a conversation
// subject, or anything derived from user content — the fact that this path CAN carry text
// is exactly why it must not be fed from anything private.

export interface BroadcastTarget {
  push_token: string;
  push_provider: string; // 'apns' | 'fcm'
}

export interface BroadcastResult {
  attempted: number;
  apns: number;
  fcm: number;
  skipped: number;
}

/**
 * Fan an operator announcement out to the given devices.
 *
 * Never rejects: a broadcast that throws halfway has already delivered to some unknown
 * prefix of the audience, and an exception makes that worse rather than recoverable. The
 * result reports what was attempted so the caller can record it.
 */
export async function sendAdminBroadcast(
  devices: BroadcastTarget[],
  title: string,
  body: string,
): Promise<BroadcastResult> {
  const result: BroadcastResult = { attempted: 0, apns: 0, fcm: 0, skipped: 0 };
  if (!devices?.length) return result;

  const apnsTokens: string[] = [];
  const fcmTokens: string[] = [];
  for (const d of devices) {
    if (!d?.push_token || !d?.push_provider) { result.skipped++; continue; }
    if (d.push_provider === 'apns') apnsTokens.push(d.push_token);
    else if (d.push_provider === 'fcm') fcmTokens.push(d.push_token);
    else result.skipped++;
  }
  result.attempted = apnsTokens.length + fcmTokens.length;

  await Promise.allSettled([
    apnsTokens.length ? broadcastApns(apnsTokens, title, body).then((n) => { result.apns = n; })
                      : Promise.resolve(),
    fcmTokens.length ? broadcastFcm(fcmTokens, title, body).then((n) => { result.fcm = n; })
                     : Promise.resolve(),
  ]);
  return result;
}

/**
 * VISIBLE alert, and deliberately WITHOUT `mutable-content`.
 *
 * The message path sets it so the Notification Service Extension can replace a placeholder
 * with decrypted content. There is nothing to decrypt here, and an NSE that runs anyway
 * would try to fetch a message id this payload does not have. So the banner ships as-is.
 */
async function broadcastApns(tokens: string[], title: string, body: string): Promise<number> {
  if (!apnsConfigured()) {
    console.warn('[push] APNs not configured; skipping broadcast');
    return 0;
  }
  let auth: string;
  try {
    auth = apnsAuthToken();
  } catch (e) {
    console.warn('[push] apns auth failed for broadcast:', (e as Error).message);
    return 0;
  }

  const payload = JSON.stringify({
    aps: {
      alert: { title, body },
      sound: 'default',
      // Announcements are not per-conversation, so they collapse into one thread rather
      // than stacking under whatever chat happened to be last.
      'thread-id': 'voiid.announcement',
    },
    // Lets the client tell an announcement from a message wake without inspecting the
    // alert — the same non-secret routing discipline the rest of this file uses.
    type: 'announcement',
  });

  let sent = 0;
  // Serial in bounded chunks rather than all at once: a broadcast is the one push path
  // that can address every device at the same instant, and an unbounded fan-out is how a
  // send takes the API process down with it.
  const CHUNK = 100;
  for (let i = 0; i < tokens.length; i += CHUNK) {
    const slice = tokens.slice(i, i + CHUNK);
    const results = await Promise.allSettled(
      slice.map((token) => broadcastApnsOne(token, auth, payload))
    );
    sent += results.filter((r) => r.status === 'fulfilled' && r.value).length;
  }
  return sent;
}

function broadcastApnsOne(token: string, auth: string, payload: string): Promise<boolean> {
  return new Promise((resolve) => {
    let req: http2.ClientHttp2Stream;
    try {
      // Reuses whichever gateway the message path already proved for this token, so an
      // admin announcement reaches dev builds too. No retry here: a broadcast is a bulk
      // best-effort send, and the per-device truth is learned by the message path.
      const session = getApnsSession(apnsHostForToken.get(token) ?? apnsHost());
      req = session.request({
        ':method': 'POST',
        ':path': `/3/device/${token}`,
        authorization: `bearer ${auth}`,
        'apns-topic': APNS_BUNDLE_ID as string,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        // An announcement older than a day is noise. Unlike a message, nobody is waiting
        // for it and it cannot be caught up on.
        'apns-expiration': String(Math.floor(Date.now() / 1000) + 24 * 3600),
      });
    } catch (e) {
      console.warn('[push] broadcast request setup failed:', (e as Error).message);
      return resolve(false);
    }
    let status = 0;
    req.on('response', (h) => { status = Number(h[':status']) || 0; });
    req.on('error', () => resolve(false));
    req.on('end', () => resolve(status === 200));
    req.setEncoding('utf8');
    req.on('data', () => { /* drain */ });
    req.write(payload);
    req.end();
  });
}

/**
 * FCM with a `notification` block — the one place this file uses one.
 *
 * Every other Android push is DATA-ONLY so the client builds the notification itself after
 * decrypting. An announcement has nothing to decrypt, so the OS draws it directly, which
 * also means it still appears if the app is force-stopped.
 */
async function broadcastFcm(tokens: string[], title: string, body: string): Promise<number> {
  const app = getFirebaseAdminApp();
  if (!app) {
    console.warn('[push] Firebase Admin not configured; skipping broadcast');
    return 0;
  }
  try {
    const { getMessaging } =
      require('firebase-admin/messaging') as typeof import('firebase-admin/messaging');
    let sent = 0;
    const CHUNK = 500; // sendEachForMulticast's documented ceiling
    for (let i = 0; i < tokens.length; i += CHUNK) {
      const res = await getMessaging(app).sendEachForMulticast({
        tokens: tokens.slice(i, i + CHUNK),
        notification: { title, body },
        data: { type: 'announcement' },
        android: { priority: 'high', notification: { channelId: 'voiid_announcements' } },
      });
      sent += res.successCount;
    }
    return sent;
  } catch (e) {
    console.warn('[push] fcm broadcast failed:', (e as Error).message);
    return 0;
  }
}

/** ActivityKit tokens use their own topic, never the ordinary notification channel. */
export const eventActivityPushConfigured = apnsConfigured;
export async function sendEventActivityPush(token: string, sandbox: boolean, aps: Record<string, unknown>, allowFallback = true): Promise<number> {
  if (!apnsConfigured()) throw new Error('Activity push unavailable');
  return new Promise((resolve, reject) => {
    const req = getApnsSession(sandbox ? APNS_SANDBOX_HOST : APNS_PROD_HOST).request({
      ':method': 'POST', ':path': `/3/device/${token}`,
      authorization: `bearer ${apnsAuthToken()}`,
      'apns-topic': `${APNS_BUNDLE_ID}.push-type.liveactivity`,
      'apns-push-type': 'liveactivity', 'apns-priority': '5',
      'apns-expiration': String(Math.floor(Date.now() / 1000) + 60),
    });
    let status = 0;
    let responseBody = '';
    req.on('response', h => { status = Number(h[':status']); });
    req.on('data', chunk => { if (responseBody.length<4096) responseBody += chunk.toString(); });
    req.on('error', reject);
    req.on('end', () => {
      if (allowFallback && status===400 && responseBody.includes('BadDeviceToken')) {
        sendEventActivityPush(token,!sandbox,aps,false).then(resolve,reject);
      } else resolve(status);
    });
    req.setTimeout(10_000, () => { req.close(); reject(new Error('Activity push timeout')); });
    req.end(JSON.stringify({ aps }));
  });
}
