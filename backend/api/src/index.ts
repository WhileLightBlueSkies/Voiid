import { sweepExpiredConferenceInvites } from './routes/calls';
import { sweepMissedCallNotifications, sweepUnansweredCalls } from './missedCallNotifications';
import { sweepEventLiveActivities } from './eventLiveActivities';
// VOIID API service (Phase 0/1). HTTPS-only in prod; JWT validation; rate limiting (Section 4.6/4.9).
import { secretboxAvailable } from './secretbox';
import { installErrorHandler } from './errors';
import express from 'express';
import { pool } from './db';
import { redis } from './redis';
import { rateLimit } from './security';
import { firebaseStatus } from './firebase';
import { r2Configured } from './r2';
import authRoutes from './routes/auth';
import deviceRoutes from './routes/devices';
import prekeyRoutes from './routes/prekeys';
import messageRoutes from './routes/messages';
import conversationRoutes from './routes/conversations';
import userRoutes from './routes/users';
import contactRoutes from './routes/contacts';
import receiptRoutes from './routes/receipts';
import linkingRoutes from './routes/linking';
import mediaRoutes from './routes/media';
import mlsRoutes from './routes/mls';
import recoveryRoutes from './routes/recovery';
import backupRoutes from './routes/backup';
import callsRoutes from './routes/calls';
import locationRoutes from './routes/location';
import storiesRoutes from './routes/stories';
import reachabilityRoutes from './routes/reachability';
import profileKeyRoutes from './routes/profileKeys';
import gifRoutes from './routes/gifs';
import adminRoutes from './routes/admin';
import lawfulRoutes from './routes/lawful';
import { requireAdmin } from './routes/admin';
import clipsRoutes from './routes/clips';
import creatorRoutes from './routes/creators';
import highlightRoutes from './routes/highlights';
import reportRoutes from './routes/reports';
import consentRoutes from './routes/consent';
import blockRoutes from './routes/blocks';
import dpdpRoutes from './routes/dpdp';
import eventRoutes from './routes/events';
import paymentRoutes from './routes/payments';
import kycRoutes from './routes/kyc';
import { register as registerPaymentProvider } from './payments/provider';
import { razorpayFromEnv } from './payments/razorpay';
import { cashfreeFromEnv } from './payments/cashfree';
import tournamentRoutes from './routes/tournaments';
import communityRoutes from './routes/communities';
import communityHostThreadRoutes from './routes/communityHostThreads';
import gamesRoutes from './routes/games';
import configRoutes from './routes/config';
import { forceUpdateGate } from './version';
import baskAgentRoutes, { assertBaskAgentConfig } from './routes/baskAgent';
import baskHealthRoutes from './routes/baskHealth';

const app = express();
// Public, content-free Universal Link association for authenticated event tickets.
app.get('/.well-known/apple-app-site-association', (_req,res) => {
  res.set('Cache-Control','public, max-age=3600').json({applinks:{details:[{
    appIDs:['ZX246KFTQD.in.voiid.app'],components:[{'/':'/tickets/*'}]
  }]}});
});
app.get('/tickets/:id', (_req,res) => {
  res.set('Cache-Control','no-store').type('text/plain').send('Open this ticket in Voiid, signed in to the account that booked it. You can also find it in My tickets.');
});


// Client IP keys the per-IP rate limiter and is written into admin_sessions,
// security_events and the admin audit log — the records a breach investigation reads —
// so it must not be attacker-supplied. Express only honours x-forwarded-for when the
// connection itself arrives from a trusted address; with this unset it ignores the
// header, and any hand-rolled parse of it is forgeable by anyone who can reach the port.
//
// 'loopback' covers both deployed topologies (docs/VULTR_DEPLOY.md): prod puts Caddy on
// the same box reverse-proxying to localhost:4000, so the single trusted hop is
// 127.0.0.1; dev exposes :4000 directly with no proxy at all, where loopback never
// matches a real client and req.ip falls back to the socket address. TRUST_PROXY (a hop
// count or a comma-separated CIDR list) overrides it if a proxy ever moves off-box —
// a wrong value fails in BOTH directions: too permissive and spoofing works again, too
// restrictive and every request looks like the proxy, throttling all users as one client.
const trustProxy = process.env.TRUST_PROXY?.trim() || 'loopback';
app.set('trust proxy', /^\d+$/.test(trustProxy) ? Number(trustProxy) : trustProxy);

// THE PAYMENT WEBHOOK MOUNTS BEFORE express.json(), and this ordering is load-bearing.
// Body parsing consumes the request stream once, so a webhook parsed as JSON first receives
// nothing and its signature can NEVER verify — every payment would fail as a bad signature,
// which is a very hard failure to read from the outside. routes/payments.ts installs its own
// raw-body parser and detects the wrong order explicitly, but the right order is here.
//
// It is also the one endpoint in this API called by a stranger: no requireAuth, because the
// caller is a payment provider. Its authenticity comes from the signature, and its
// idempotency from an insert into payment_webhook_events — a provider WILL deliver twice.
// Registered BEFORE the routes that ask for it. activeProvider() reads the registry on
// every call, so ordering is not strictly required — but a provider registered after the
// first request is a race nobody should have to reason about.
//
// Absent config is the supported state, not an error: with nothing registered, free events
// work end to end and a paid one is refused with a 501 rather than half-working.
{
  const razorpay = razorpayFromEnv();
  if (razorpay) {
    registerPaymentProvider(razorpay);
    console.log('[payments] razorpay registered');
  }
  // Which one CHARGES is VOIID_PAYMENT_PROVIDER. Both may be registered, so webhooks for
  // orders opened under the other provider still verify and settle after a switch.
  const cashfree = cashfreeFromEnv();
  if (cashfree) {
    registerPaymentProvider(cashfree);
    console.log(`[payments] cashfree registered (${cashfree.env})`);
  }
}

app.use(paymentRoutes);

app.use(express.json({ limit: '5mb' }));

// Health (Section 8 minimal ops). Reports DB + Redis reachability for Uptime Kuma / load balancer.
// Process start time — with `build` above, distinguishes "restarted" from "redeployed".
const STARTED_AT = new Date().toISOString();

app.get('/health', async (_req, res) => {
  const out: Record<string, unknown> = { service: 'api', status: 'ok' };
  try { await pool.query('select 1'); out.db = 'up'; } catch { out.db = 'down'; out.status = 'degraded'; }
  try { await redis.ping(); out.redis = 'up'; } catch { out.redis = 'down'; out.status = 'degraded'; }
  // Firebase Admin status (no secrets) — confirms the box CAN verify real tokens.
  out.firebase = firebaseStatus();
  // R2 media storage configured? (no secrets) — confirms media uploads will work.
  out.media = { configured: r2Configured() };
  // WHICH BUILD IS ACTUALLY SERVING. The deploy pipeline reports success against a host whose
  // address is masked in the logs, and api-dev.voiid.app resolves to a DIFFERENT IP than the one
  // in the local ssh config — so "the deploy went green" has not been the same claim as "the code
  // I pushed is the code answering requests". This makes that verifiable from anywhere with curl,
  // and it is the reason a games 500 could survive several apparently-successful deploys.
  //
  // Commit sha only: no secrets, and nothing an attacker gains from knowing the version they can
  // already fingerprint from behaviour.
  out.build = process.env.VOIID_BUILD_SHA ?? 'unknown';
  out.started_at = STARTED_AT;
  res.status(out.status === 'ok' ? 200 : 503).json(out);
});

// ─────────────────────────────────────────────────────────────────────────────────
// Bask control agent — the remote OPERATIONS plane (routes/baskAgent.ts).
//
// Mounted OUTSIDE `api` for the same reason /admin is, one step further: it does not
// authenticate a Voiid user OR an admin person, it authenticates the Bask machine with a
// static bearer token, and what it grants is process control and .env writes on this box.
// No path from a user session or an admin session reaches it.
//
// MOUNTED BEFORE the global rate limit and the force-update gate, both deliberately. The
// gate would 426 a caller that sends no app version — which Bask never will — and the
// per-IP limiter counts the reverse proxy as one client, so an ops call could be throttled
// by ordinary user traffic at exactly the moment someone is trying to restart a wedged
// service. Its own protection is the token, not a ceiling.
//
// The agent's own tight limiter still applies: this is a bearer-token endpoint, and the
// login-grinding argument that gives /admin a low ceiling applies to token guessing too.
//
// /agent/health carries NO token, matching this project's existing convention that health
// checks are open (GET /health above is reachable by the deploy gate and Uptime Kuma with
// no credential). It reports utilisation and dependency reachability — the same class of
// information the existing route already publishes, and no secret.
app.use('/agent', rateLimit({ max: 60, windowSeconds: 60, bucket: 'bask-agent' }), baskHealthRoutes);
app.use('/agent', rateLimit({ max: 60, windowSeconds: 60, bucket: 'bask-agent' }), baskAgentRoutes);

// Remote config / version negotiation — UNVERSIONED + UNGATED so the client can
// always reach it on launch (even when it must update) to learn the version, flags
// and force-update verdict. (/health stays open too.)
app.use('/config', configRoutes);

// Global API abuse guard (per-IP). Auth/OTP routes get tighter per-phone limits inside the route.
app.use(rateLimit({ max: 300, windowSeconds: 60, bucket: 'api' }));

// Force-update gate: 426 any client below the minimum supported app version.
app.use(forceUpdateGate);

// All API routes live on a router mounted at BOTH /v1 (the stable, versioned
// contract clients should use) and the legacy root (so already-deployed,
// pre-versioning builds keep working during migration). /v1 is additive-only;
// breaking changes ship as a future /v2 router.
const api = express.Router();
api.use('/auth', rateLimit({ max: 30, windowSeconds: 60, bucket: 'auth' }), authRoutes);
api.use('/devices', deviceRoutes);
api.use('/prekeys', prekeyRoutes);
api.use('/messages', messageRoutes);
api.use('/conversations', conversationRoutes);
api.use('/users', userRoutes);
api.use('/contacts', contactRoutes);
api.use('/receipts', receiptRoutes);
api.use('/linking', linkingRoutes);
api.use('/media', mediaRoutes);
api.use('/mls', mlsRoutes);
// Recovery is a sensitive surface: add a tighter per-IP limit on top of the global
// guard (the existing rateLimit middleware, redis-backed). This slows network-level
// abuse. Client-reported PIN outcomes are telemetry, not proof that guesses are limited.
api.use('/recovery', rateLimit({ max: 30, windowSeconds: 60, bucket: 'recovery' }), recoveryRoutes);
api.use('/backup', backupRoutes);
// Calls: TURN credential issuance + ring push + lean call-history records. Signaling
// (SDP/ICE) is on the WS relay; media/keys are E2E on-device and never touch here.
api.use('/calls', callsRoutes);
// Location: share SESSIONS only (start/stop/extend/revoke). Position fixes never come
// here — they are E2E-encrypted on-device and relayed over the WS process. No endpoint
// in this router accepts or returns a coordinate; see routes/location.ts.
api.use('/location', locationRoutes);
// Stories: 24h ephemeral media. The blob is encrypted on-device and PUT straight to R2;
// this router only stores the opaque object key plus one opaque per-recipient-DEVICE
// key envelope, and signs short-lived URLs. It never sees media bytes or a media key.
api.use('/stories', storiesRoutes);
// Reachability: who may open a 1:1 with you (docs 020_reachability.sql). Username lookup,
// PIN-gated requests, Accept/Decline. A LOW ceiling on purpose — this router is the surface
// an attacker would use to enumerate handles or grind a 6-digit PIN, and the per-target
// throttle inside the route is backed up by this per-IP one.
api.use('/reachability', reachabilityRoutes);
// Profile keys: encrypted-avatar key distribution (021_profile_keys.sql). Moves opaque
// per-device ciphertext only — the server never holds a profile key. A rotation fans out one
// envelope per contact device, so the ceiling is higher than the reachability router's.
api.use('/profile-keys', profileKeyRoutes);
// Clips: short-form PUBLIC video. Unlike every router above it, this content is NOT
// end-to-end encrypted — the media is plaintext in R2 and the server attributes
// view/like/comment counts. That is a deliberate, scoped exception (a broadcast has
// no fixed recipient set to encrypt to); see the header of routes/clips.ts and
// 022_clips.sql. It does not touch the message/call/location/story paths.
api.use('/clips', clipsRoutes);
// ─────────────────────────────────────────────────────────────────────────────────
// Communities. The container, its roster, search and invites are NOT E2EE (see the
// header of 030_communities.sql); the channels themselves are ordinary MLS group
// conversations and stay encrypted.
//
// JOINING A COMMUNITY IS NOT A MESSAGING RIGHT. Membership lets you into the
// community's channels and grants exactly one private line — to the OWNER, and only
// the owner (community_host_threads has nowhere to put a second member, so widening it
// takes a migration and a review). Reaching any other member still requires one of the
// three paths in 020_reachability.sql.
//
// THE HOST-THREAD ROUTER MOUNTS FIRST, AND AT THE ROOT. It declares its paths in full
// ('/communities/:id/host-thread'), so it needs no prefix — and mounting it ahead of the
// communities router keeps a future one-segment '/:handle' route from shadowing it.
// A tighter ceiling than the general API guard because this endpoint CREATES
// conversations: walking a directory opening a line to every host is the abuse it invents.
api.use(communityHostThreadRoutes);
api.use('/communities', communityRoutes);
// Creator profiles + the follow graph — the public identity behind Clips, same scoped
// non-E2EE exception (029_social_profiles.sql). A FOLLOW GRANTS NO MESSAGING RIGHT: the
// three reachability paths in 020 are untouched, and nothing here may ever be used to
// authorise opening a conversation.
api.use('/creators', creatorRoutes);
// Creator story highlights. Declares its paths IN FULL ('/creators/:handle/highlights' and
// '/highlights/:id'), so it mounts at the router root with no prefix — the same arrangement
// tournaments.ts and events.ts use, and for the same reason: the read path is keyed on a
// handle and the write paths on a highlight id, which are two different prefixes.
//
// MOUNTED AFTER the creators router but reached BEFORE it for this path, because Express
// matches '/creators/:handle/highlights' (two segments under the prefix) against a router
// whose own wildcard is the single-segment 'GET /:handle' — that wildcard cannot match a
// two-segment path, so there is no shadowing either way. See the header of highlights.ts.
api.use(highlightRoutes);
// Content reports. A LOW ceiling deliberately: a report is a considered act, and a client
// firing them in bulk is either broken or report-bombing. The per-(reporter,target)
// uniqueness in 035 stops duplicates; this stops volume.
api.use('/reports', reportRoutes);
// Consent and data-principal requests (DPDP). Both declare relative paths, so both take a
// prefix. A LOW ceiling on /dpdp: an export is expensive to produce and a right that is
// exercised occasionally, not in a loop.
api.use('/consent', consentRoutes);

// User blocking. Blocking and unblocking are deliberate, infrequent acts — a low ceiling
// is plenty, and it bounds any attempt to use the endpoints to probe account existence.
api.use('/blocks', blockRoutes);
api.use('/dpdp', dpdpRoutes);
// Tournaments and community events declare their paths IN FULL ('/communities/:id/events',
// '/tournaments/:id'), so they mount at the router root with no prefix — giving them one
// would produce '/events/communities/:id/events'.
api.use(tournamentRoutes);
api.use(eventRoutes);
// Host KYC for paid events. Paths carry their own '/kyc' prefix, like eventRoutes.
api.use(kycRoutes);
// Games: match lifecycle only — the catalog, creating/joining a match, history. MOVES DO
// NOT COME THROUGH HERE; they ride the WebSocket relay to backend/games, which referees
// them (see the header of routes/games.ts for why the move path is deliberately absent).
// Like clips, game state is a scoped exception to E2EE: the server must read moves to
// validate them. The invite itself is still an ordinary encrypted message.
api.use('/games', gamesRoutes);
// GIF search: a thin proxy in front of Tenor so the API key never ships in the app and users'
// searches don't go straight to Google with their IP. Returns URLs only — the CLIENT downloads
// the chosen GIF, encrypts it, and sends it as ordinary E2EE media, so recipients never touch
// Tenor. Typing in a search box is bursty, hence the higher ceiling.
api.use('/gifs', gifRoutes);

// Admin: the moderation plane. Mounted OUTSIDE `api` because it does not use the app's
// user auth at all — it has its own email+password credential and its own session table
// (028_admin_users.sql), so a compromised phone number can never reach it.
//
// The rate limit is deliberately tight: this is a password endpoint, and the login route is
// the one surface where an attacker would grind credentials.
// CORS, and ONLY on /admin. The mobile apps are native clients with no origin, so the API
// has never needed it — which is exactly why a browser panel could not log in: the request
// reached the server and succeeded, and the browser then discarded the response for want of
// an Access-Control-Allow-Origin header. curl saw 200; Chrome saw a failure.
//
// An ALLOWLIST, never a wildcard, and never a reflection of whatever Origin arrives. This
// router can take content down and start account erasures; `*` would let any page on the
// internet drive it with a logged-in operator's session.
//
// No Access-Control-Allow-Credentials, deliberately: the panel sends its token as an
// explicit Authorization header rather than a cookie, so the browser never attaches
// ambient credentials and there is no CSRF surface to protect.
const ADMIN_ORIGINS = new Set(
  (process.env.ADMIN_ALLOWED_ORIGINS ?? 'http://localhost:3100')
    .split(',').map((o) => o.trim()).filter(Boolean),
);

app.use('/admin', (req, res, next) => {
  const origin = req.headers.origin;
  if (origin && ADMIN_ORIGINS.has(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    // The response varies by Origin, so any cache in front of this must key on it too.
    res.setHeader('Vary', 'Origin');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PATCH,DELETE,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization');
    res.setHeader('Access-Control-Max-Age', '600');
  }
  // Preflight ends here. It carries no credentials and must not fall through to the login
  // route, where it would burn a slot on the deliberately tight rate limit.
  if (req.method === 'OPTIONS') return res.sendStatus(origin && ADMIN_ORIGINS.has(origin) ? 204 : 403);
  next();
});

// Lawful/government requests. Mounted UNDER the admin rate limit and BEHIND requireAdmin,
// then gated again to the 'admin' role inside the router — moderation and compelled
// disclosure are different jobs with different blast radii and do not share a role.
app.use('/admin/lawful', rateLimit({ max: 60, windowSeconds: 60, bucket: 'admin' }),
        requireAdmin, lawfulRoutes);
app.use('/admin', rateLimit({ max: 60, windowSeconds: 60, bucket: 'admin' }), adminRoutes);

app.use('/v1', api);
app.use(api);   // legacy unversioned alias (migration safety) — remove once all clients send /v1

// Global error handler. See src/errors.ts for why the status is never inferred from the
// error's MESSAGE: a body-too-large arrives carrying its own 413 and was answered 500, and any
// internal failure whose text mentioned "invalid input" — which is what Postgres says for a bad
// uuid cast — was reported to the caller as their mistake.
installErrorHandler(app);

// Surface unhandled async rejections instead of letting them tear down sockets.
process.on('unhandledRejection', (reason) => {
  console.error('[voiid:api] unhandledRejection:', (reason as Error)?.message ?? reason);
});

const port = Number(process.env.API_PORT) || 4000;

// ── FAIL-CLOSED BOOT GUARD ────────────────────────────────────────────────────
// Two misconfigurations are total-compromise class: AUTH_DEV_BYPASS lets anyone
// mint a session for ANY phone number with one request, and the JWT_SECRET dev
// default lets anyone forge valid tokens outright. Both are fine on a laptop and
// catastrophic deployed, so production refuses to boot rather than trusting an
// operator to have read .env comments. Mirrored in backend/websocket/src/index.ts.
// The Bask control agent refuses to run unauthenticated: a missing or too-short
// BASK_AGENT_TOKEN exits here rather than exposing process control to anyone who can reach
// the port. Checked in EVERY environment, not just production, because a laptop with a
// weak token is how a weak token reaches the box.
assertBaskAgentConfig();

(function assertProductionSafety() {
  if (process.env.NODE_ENV !== 'production') return;
  const fatal: string[] = [];
  if (process.env.AUTH_DEV_BYPASS === '1') {
    fatal.push('AUTH_DEV_BYPASS=1 accepts "dev:<phone>" tokens with no Firebase verification');
  }
  if (!process.env.JWT_SECRET || process.env.JWT_SECRET === 'dev-only-change-me') {
    fatal.push('JWT_SECRET is missing or set to the known dev default — anyone can forge tokens');
  }
  if (fatal.length) {
    console.error('[voiid:api] REFUSING TO START in production:\n - ' + fatal.join('\n - '));
    process.exit(1);
  }
})();

app.listen(port, () => {
  console.log(`[voiid:api] listening on :${port}`);
  // Say this ONCE at boot rather than making an operator infer it from a settings screen.
  // A missing key is silent by design (PIN storage falls back to hash-only, everything else
  // works), and silent-by-design is exactly the thing that costs an afternoon to diagnose.
  console.log(
    secretboxAvailable()
      ? '[voiid:api] contact PIN storage: encrypted at rest (VOIID_SECRETBOX_KEY loaded)'
      : '[voiid:api] contact PIN storage: HASH-ONLY — VOIID_SECRETBOX_KEY is not set, so ' +
        'PINs cannot be shown after generation. Generate one with: openssl rand -base64 32'
  );
});

// Enable after migration 074. Persisted leases prevent duplicate work across replicas.
if (process.env.VOIID_MISSED_CALL_PUSH === '1') {
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try { await sweepMissedCallNotifications(); }
    catch (error) { console.warn('[missed-call-push] sweep failed:', (error as Error).message); }
    finally { running = false; }
  };
  const timer = setInterval(() => { void tick(); }, 15_000);
  timer.unref();
  void tick();
}

// Event activity updates are device-scoped and leased across API replicas.
if (process.env.VOIID_EVENT_LIVE_ACTIVITIES === '1') {
  const timer=setInterval(() => { void sweepEventLiveActivities().catch(() => console.warn('[event-activity] sweep unavailable')); },30_000);
  timer.unref();
}

// Invitation expiry is required even when missed-call push delivery is disabled.
let expiringConferences = false;
setInterval(() => {
  if (expiringConferences) return;
  expiringConferences = true;
  void sweepExpiredConferenceInvites().then(() => sweepUnansweredCalls()).catch(error => console.warn('[conference-expiry]', error))
    .finally(() => { expiringConferences = false; });
}, 15_000).unref();
