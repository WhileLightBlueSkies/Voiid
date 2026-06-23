// VOIID API service (Phase 0/1). HTTPS-only in prod; JWT validation; rate limiting (Section 4.6/4.9).
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
import configRoutes from './routes/config';
import { forceUpdateGate } from './version';

const app = express();
app.use(express.json({ limit: '5mb' }));

// Health (Section 8 minimal ops). Reports DB + Redis reachability for Uptime Kuma / load balancer.
app.get('/health', async (_req, res) => {
  const out: Record<string, unknown> = { service: 'api', status: 'ok' };
  try { await pool.query('select 1'); out.db = 'up'; } catch { out.db = 'down'; out.status = 'degraded'; }
  try { await redis.ping(); out.redis = 'up'; } catch { out.redis = 'down'; out.status = 'degraded'; }
  // Firebase Admin status (no secrets) — confirms the box CAN verify real tokens.
  out.firebase = firebaseStatus();
  // R2 media storage configured? (no secrets) — confirms media uploads will work.
  out.media = { configured: r2Configured() };
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
app.listen(port, () => console.log(`[voiid:api] listening on :${port}`));
