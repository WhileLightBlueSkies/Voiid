// VOIID API service (Phase 0/1). HTTPS-only in prod; JWT validation; rate limiting (Section 4.6/4.9).
import { secretboxAvailable } from './secretbox';
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
import clipsRoutes from './routes/clips';
import creatorRoutes from './routes/creators';
import communityRoutes from './routes/communities';
import communityHostThreadRoutes from './routes/communityHostThreads';
import gamesRoutes from './routes/games';
import configRoutes from './routes/config';
import { forceUpdateGate } from './version';

const app = express();

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
// abuse; per-USER online PIN-guess limiting is enforced inside the route via the
// recovery_keys.failed_attempts/locked_until lockout.
api.use('/recovery', rateLimit({ max: 30, windowSeconds: 60, bucket: 'recovery' }), recoveryRoutes);
api.use('/backup', backupRoutes);
// Calls: TURN credential issuance + ring push + lean call-history records. Signaling
// (SDP/ICE) is on the WS relay; media/keys are E2E on-device and never touch here.
api.use('/calls', callsRoutes);
// Location: share SESSIONS only (start/stop/extend/revoke). Position fixes never come
// here — they are E2E-encrypted on-device and relayed over the WS process. No endpoint
// in this router accepts or returns a coordinate; see routes/location.ts.
api.use('/location', rateLimit({ max: 60, windowSeconds: 60, bucket: 'location' }), locationRoutes);
// Stories: 24h ephemeral media. The blob is encrypted on-device and PUT straight to R2;
// this router only stores the opaque object key plus one opaque per-recipient-DEVICE
// key envelope, and signs short-lived URLs. It never sees media bytes or a media key.
api.use('/stories', rateLimit({ max: 120, windowSeconds: 60, bucket: 'stories' }), storiesRoutes);
// Reachability: who may open a 1:1 with you (docs 020_reachability.sql). Username lookup,
// PIN-gated requests, Accept/Decline. A LOW ceiling on purpose — this router is the surface
// an attacker would use to enumerate handles or grind a 6-digit PIN, and the per-target
// throttle inside the route is backed up by this per-IP one.
api.use('/reachability', rateLimit({ max: 30, windowSeconds: 60, bucket: 'reachability' }), reachabilityRoutes);
// Profile keys: encrypted-avatar key distribution (021_profile_keys.sql). Moves opaque
// per-device ciphertext only — the server never holds a profile key. A rotation fans out one
// envelope per contact device, so the ceiling is higher than the reachability router's.
api.use('/profile-keys', rateLimit({ max: 120, windowSeconds: 60, bucket: 'profile-keys' }), profileKeyRoutes);
// Clips: short-form PUBLIC video. Unlike every router above it, this content is NOT
// end-to-end encrypted — the media is plaintext in R2 and the server attributes
// view/like/comment counts. That is a deliberate, scoped exception (a broadcast has
// no fixed recipient set to encrypt to); see the header of routes/clips.ts and
// 022_clips.sql. It does not touch the message/call/location/story paths.
api.use('/clips', rateLimit({ max: 240, windowSeconds: 60, bucket: 'clips' }), clipsRoutes);
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
api.use(rateLimit({ max: 30, windowSeconds: 60, bucket: 'community-host-thread' }),
        communityHostThreadRoutes);
api.use('/communities', rateLimit({ max: 120, windowSeconds: 60, bucket: 'communities' }),
        communityRoutes);
// Creator profiles + the follow graph — the public identity behind Clips, same scoped
// non-E2EE exception (029_creator_profiles.sql). A FOLLOW GRANTS NO MESSAGING RIGHT: the
// three reachability paths in 020 are untouched, and nothing here may ever be used to
// authorise opening a conversation.
api.use('/creators', rateLimit({ max: 180, windowSeconds: 60, bucket: 'creators' }), creatorRoutes);
// Games: match lifecycle only — the catalog, creating/joining a match, history. MOVES DO
// NOT COME THROUGH HERE; they ride the WebSocket relay to backend/games, which referees
// them (see the header of routes/games.ts for why the move path is deliberately absent).
// Like clips, game state is a scoped exception to E2EE: the server must read moves to
// validate them. The invite itself is still an ordinary encrypted message.
api.use('/games', rateLimit({ max: 120, windowSeconds: 60, bucket: 'games' }), gamesRoutes);
// GIF search: a thin proxy in front of Tenor so the API key never ships in the app and users'
// searches don't go straight to Google with their IP. Returns URLs only — the CLIENT downloads
// the chosen GIF, encrypts it, and sends it as ordinary E2EE media, so recipients never touch
// Tenor. Typing in a search box is bursty, hence the higher ceiling.
api.use('/gifs', rateLimit({ max: 180, windowSeconds: 60, bucket: 'gifs' }), gifRoutes);

// Admin: the moderation plane. Mounted OUTSIDE `api` because it does not use the app's
// user auth at all — it has its own email+password credential and its own session table
// (028_admin_users.sql), so a compromised phone number can never reach it.
//
// The rate limit is deliberately tight: this is a password endpoint, and the login route is
// the one surface where an attacker would grind credentials.
app.use('/admin', rateLimit({ max: 60, windowSeconds: 60, bucket: 'admin' }), adminRoutes);

app.use('/v1', api);
app.use(api);   // legacy unversioned alias (migration safety) — remove once all clients send /v1

// Global error handler — turns thrown errors (incl. malformed JSON and bad
// base64 in inputs) into a clean 400/500 instead of crashing the socket. No
// secrets in the response. (Express 4: this catches sync throws + next(err);
// async route rejections reach here via the asyncHandler wrapper in util.ts.)
app.use((err: any, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  const status = err?.type === 'entity.parse.failed' || /base64|invalid input/i.test(err?.message ?? '')
    ? 400
    : 500;
  if (status === 500) console.error('[voiid:api] unhandled error:', err?.message);
  if (!res.headersSent) res.status(status).json({ error: status === 400 ? 'bad request' : 'internal error' });
});

// Surface unhandled async rejections instead of letting them tear down sockets.
process.on('unhandledRejection', (reason) => {
  console.error('[voiid:api] unhandledRejection:', (reason as Error)?.message ?? reason);
});

const port = Number(process.env.API_PORT) || 4000;
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
