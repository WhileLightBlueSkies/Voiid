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
//
// TWO OF THESE JOBS NOW DELETE PERSONAL DATA ON A CLOCK (erasure, retention). That raises
// the stakes on the paragraph above: this process being dead is no longer only "expired
// ciphertext sits in a bucket", it is "a phone number is retained after its owner asked
// us to erase it, and that person stays locked out of their own number". /health reports
// each job separately for exactly that reason, and the deploy script's health gate is not
// decoration.
import http from 'http';
import { reapStories } from './reapStories';
import { runErasure } from './erasure';
import { runRetentionSweep } from './retention';
import { pool } from './db';
import { r2Configured } from './r2';

const INTERVAL_MS = Number(process.env.WORKERS_INTERVAL_MS) || 5 * 60 * 1000; // 5 min
const PORT = Number(process.env.WORKERS_PORT) || 3003;

// ── THE JOBS ──────────────────────────────────────────────────────────────────────
// Each runs on every tick, in this order, each in its own try/catch: erasure and
// retention delete personal data on a legal clock, and there is no reason a slow R2
// bucket holding up the story reaper should also hold up deleting a phone number.
//
// WHY THEY ALL SHARE THE 5-MINUTE TICK rather than getting their own schedules: none of
// them is schedule-sensitive. Every one is a bounded, idempotent set of deletes whose
// PREDICATE decides what dies — a pass that never ran yesterday simply deletes
// yesterday's rows today. Adding per-job intervals would add state and a class of bug
// ("did the hourly one fire?") in exchange for nothing.
const JOBS = [
  { name: 'reapStories', run: reapStories },
  { name: 'erasure', run: runErasure },
  { name: 'retention', run: runRetentionSweep },
] as const;

interface JobState {
  lastRunAt: string | null;
  lastOkAt: string | null;
  lastError: string | null;
  lastResult: unknown;
}

// Last-run state, surfaced on /health so Uptime Kuma can see a wedged job. A worker whose
// process is up but whose job has been failing for hours is the failure mode that silently
// leaves expired ciphertext at rest — and, now, the one that silently leaves a phone
// number in the database after its owner asked to be erased. So /health reports each JOB,
// not just the process.
let running = false;
const jobs: Record<string, JobState> = Object.fromEntries(
  JOBS.map((j) => [j.name, { lastRunAt: null, lastOkAt: null, lastError: null, lastResult: null }])
);

async function tick(): Promise<void> {
  // Overlap guard: a slow pass (large batch, slow R2) must not stack passes on top of
  // each other and multiply the connection/API load.
  if (running) {
    console.warn('[workers] previous pass still running; skipping this tick');
    return;
  }
  running = true;
  try {
    for (const job of JOBS) {
      const state = jobs[job.name];
      state.lastRunAt = new Date().toISOString();
      try {
        const result = await job.run();
        state.lastResult = result;
        state.lastOkAt = new Date().toISOString();
        state.lastError = null;
        logIfInteresting(job.name, result);
      } catch (e) {
        state.lastError = (e as Error).message;
        // NEVER rethrow: an unhandled rejection here would kill the process and stop every
        // future pass of every job because one DB blip failed one query.
        console.error(`[workers] ${job.name} pass failed:`, state.lastError);
      }
    }
  } finally {
    running = false;
  }
}

/** One line per pass that did something. Silent passes stay silent — a log that prints
 *  every five minutes is a log nobody reads. COUNTS ONLY: never a user id, a phone number
 *  or an object key, because a retention worker that logs what it deleted has not deleted
 *  it. */
function logIfInteresting(name: string, result: any): void {
  if (name === 'reapStories' && (result.claimed || result.abandoned)) {
    console.log(
      `[workers] reapStories claimed=${result.claimed} objects=${result.objectsDeleted} ` +
        `rows=${result.rowsDeleted} failed=${result.failed} abandoned=${result.abandoned}`
    );
  } else if (name === 'erasure' && (result.claimed || result.objectsPending || result.stuck)) {
    console.log(
      `[workers] erasure claimed=${result.claimed} erased=${result.usersErased} ` +
        `objects=${result.objectsDeleted} queued=${result.objectsQueued} ` +
        `pending=${result.objectsPending} failed=${result.failed} stuck=${result.stuck}`
    );
  }
  // retention logs its own totals only when it deleted something (see retention.ts).
}

const server = http.createServer(async (req, res) => {
  if (req.url?.split('?')[0] !== '/health') {
    res.writeHead(404, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ error: 'not found' }));
  }
  const errored = JOBS.filter((j) => jobs[j.name].lastError).map((j) => j.name);
  const out: Record<string, unknown> = {
    service: 'workers',
    status: 'ok',
    interval_ms: INTERVAL_MS,
    jobs,
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
  // when the DB answers — expired ciphertext is piling up at rest, and an erasure that
  // is not running means personal data is being retained past the period we published.
  if (errored.length) {
    out.status = 'degraded';
    out.failing_jobs = errored;
  }
  // An account that asked to be erased and could not be is a standing alarm, not a
  // transient one: the last pass "succeeded" precisely by skipping it.
  const erasure = jobs.erasure.lastResult as { stuck?: number } | null;
  if (erasure?.stuck) {
    out.status = 'degraded';
    out.stuck_erasures = erasure.stuck;
  }
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
