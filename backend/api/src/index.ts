// VOIID API service (Phase 0/1). HTTPS-only in prod; JWT validation; rate limiting (Section 4.6/4.9).
import express from 'express';
import { pool } from './db';
import { redis } from './redis';
import { rateLimit } from './security';
import authRoutes from './routes/auth';
import deviceRoutes from './routes/devices';
import prekeyRoutes from './routes/prekeys';
import messageRoutes from './routes/messages';
import conversationRoutes from './routes/conversations';
import userRoutes from './routes/users';
import contactRoutes from './routes/contacts';
import receiptRoutes from './routes/receipts';
import linkingRoutes from './routes/linking';

const app = express();
app.use(express.json({ limit: '5mb' }));

// Health (Section 8 minimal ops). Reports DB + Redis reachability for Uptime Kuma / load balancer.
app.get('/health', async (_req, res) => {
  const out: Record<string, string> = { service: 'api', status: 'ok' };
  try { await pool.query('select 1'); out.db = 'up'; } catch { out.db = 'down'; out.status = 'degraded'; }
  try { await redis.ping(); out.redis = 'up'; } catch { out.redis = 'down'; out.status = 'degraded'; }
  res.status(out.status === 'ok' ? 200 : 503).json(out);
});

// Global API abuse guard (per-IP). Auth/OTP routes get tighter per-phone limits inside the route.
app.use(rateLimit({ max: 300, windowSeconds: 60, bucket: 'api' }));

app.use('/auth', rateLimit({ max: 30, windowSeconds: 60, bucket: 'auth' }), authRoutes);
app.use('/devices', deviceRoutes);
app.use('/prekeys', prekeyRoutes);
app.use('/messages', messageRoutes);
app.use('/conversations', conversationRoutes);
app.use('/users', userRoutes);
app.use('/contacts', contactRoutes);
app.use('/receipts', receiptRoutes);
app.use('/linking', linkingRoutes);

// Global error handler — turns thrown errors (incl. malformed JSON and bad
// base64 in inputs) into a clean 400/500 instead of crashing the socket. No
// secrets in the response. (Express 4: this catches sync throws + next(err);
// async route rejections are also surfaced here via the wrapper in security.ts.)
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
