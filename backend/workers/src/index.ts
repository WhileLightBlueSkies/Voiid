// @voiid/workers — background jobs. Third pm2 process alongside voiid-api / voiid-ws.
//
// WHY A SEPARATE PROCESS, and not the alternatives:
//   * Opportunistic sweeps inside request handlers were rejected: if the route is cold
//     nothing ever runs, so R2 orphans live forever, and a user's request pays an
//     unbounded latency cost for someone else's cleanup.
//   * pg_cron + a bucket lifecycle rule alone was rejected: retention would become a
//     console setting living outside the repo, and the DB half and the object half
//     would drift silently apart.
// A plain interval in a supervised process keeps the whole retention policy in code,
// reviewable in a diff, and restartable on its own.
//
// The loop is deliberately dumb: no queue, no scheduler library, no leader election.
// Every job here MUST be idempotent and safe to run concurrently on two boxes.
import http from 'http';
import { reapStories, ReapResult } from './reapStories';
import { pool } from './db';
import { r2Configured } from './r2';

const INTERVAL_MS = Number(process.env.WORKERS_INTERVAL_MS) || 5 * 60 * 1000; // 5 min
const PORT = Number(process.env.WORKERS_PORT) || 3003;

// Last-run state, surfaced on /health so Uptime Kuma can see a wedged reaper. A worker
// whose process is up but whose job has been failing for hours is the failure mode that
// silently leaves expired ciphertext at rest — so /health reports the JOB, not just the
// process.
let running = false;
let lastRunAt: string | null = null;
let lastOkAt: string | null = null;
let lastError: string | null = null;
let lastResult: ReapResult | null = null;

async function tick(): Promise<void> {
  // Overlap guard: a slow pass (large batch, slow R2) must not stack passes on top of
  // each other and multiply the connection/API load.
  if (running) {
    console.warn('[workers] previous pass still running; skipping this tick');
    return;
  }
  running = true;
  lastRunAt = new Date().toISOString();
  try {
    const result = await reapStories();
    lastResult = result;
    lastOkAt = new Date().toISOString();
    lastError = null;
    if (result.claimed || result.abandoned) {
      console.log(
        `[workers] reapStories claimed=${result.claimed} objects=${result.objectsDeleted} ` +
          `rows=${result.rowsDeleted} failed=${result.failed} abandoned=${result.abandoned}`
      );
    }
  } catch (e) {
    lastError = (e as Error).message;
    // NEVER rethrow: an unhandled rejection here would kill the process and stop every
    // future pass because one DB blip failed one query.
    console.error('[workers] reapStories pass failed:', lastError);
  } finally {
    running = false;
  }
}

const server = http.createServer(async (req, res) => {
  if (req.url?.split('?')[0] !== '/health') {
    res.writeHead(404, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ error: 'not found' }));
  }
  const out: Record<string, unknown> = {
    service: 'workers',
    status: 'ok',
    interval_ms: INTERVAL_MS,
    last_run_at: lastRunAt,
    last_ok_at: lastOkAt,
    last_error: lastError,
    last_result: lastResult,
    media: { configured: r2Configured() },
  };
  try {
    await pool.query('select 1');
    out.db = 'up';
  } catch {
    out.db = 'down';
    out.status = 'degraded';
  }
  // A pass that has never succeeded, or that failed most recently, is degraded even
  // when the DB answers — expired ciphertext is piling up at rest.
  if (lastError) out.status = 'degraded';
  res.writeHead(out.status === 'ok' ? 200 : 503, { 'content-type': 'application/json' });
  res.end(JSON.stringify(out));
});

server.listen(PORT, () => console.log(`[voiid:workers] listening on :${PORT} (interval ${INTERVAL_MS}ms)`));

// Run once at boot so a restart immediately clears whatever piled up while down.
void tick();
const timer = setInterval(() => void tick(), INTERVAL_MS);
timer.unref?.(); // never hold the process open on the timer alone; the HTTP server does that

process.on('unhandledRejection', (reason) => {
  console.error('[voiid:workers] unhandledRejection:', (reason as Error)?.message ?? reason);
});

for (const sig of ['SIGTERM', 'SIGINT'] as const) {
  process.on(sig, () => {
    console.log(`[voiid:workers] ${sig} — shutting down`);
    clearInterval(timer);
    server.close(() => {
      void pool.end().finally(() => process.exit(0));
    });
  });
}
