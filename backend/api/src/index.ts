// VOIID API service (Phase 0). HTTPS-only in prod; JWT validation; rate limiting (add at edge/Phase 0+).
import express from 'express';
import { pool } from './db';
import { redis } from './redis';
import authRoutes from './routes/auth';
import deviceRoutes from './routes/devices';
import prekeyRoutes from './routes/prekeys';
import messageRoutes from './routes/messages';

const app = express();
app.use(express.json({ limit: '5mb' }));

// Health (Section 8 minimal ops). Reports DB + Redis reachability for Uptime Kuma / load balancer.
app.get('/health', async (_req, res) => {
  const out: Record<string, string> = { service: 'api', status: 'ok' };
  try { await pool.query('select 1'); out.db = 'up'; } catch { out.db = 'down'; out.status = 'degraded'; }
  try { await redis.ping(); out.redis = 'up'; } catch { out.redis = 'down'; out.status = 'degraded'; }
  res.status(out.status === 'ok' ? 200 : 503).json(out);
});

app.use('/auth', authRoutes);
app.use('/devices', deviceRoutes);
app.use('/prekeys', prekeyRoutes);
app.use('/messages', messageRoutes);

const port = Number(process.env.API_PORT) || 4000;
app.listen(port, () => console.log(`[voiid:api] listening on :${port}`));
