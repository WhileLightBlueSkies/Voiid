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
import Redis from 'ioredis';
import { flushOutbox } from './outbox';
import { classifyJob, type JobHealthInput } from './health';
import { reapStories } from './reapStories';
import { runErasure } from './erasure';
import { runRetentionSweep } from './retention';
import { pool } from './db';
import { r2Configured } from './r2';

const INTERVAL_MS = Number(process.env.WORKERS_INTERVAL_MS) || 5 * 60 * 1000; // 5 min
const PORT = Number(process.env.WORKERS_PORT) || 3003;

// ── THE OUTBOX SWEEP RUNS ON ITS OWN, MUCH FASTER CLOCK ───────────────────────────
//
// The header above says none of these jobs is schedule-sensitive, and for the reapers that
// is true: a pass that never ran yesterday deletes yesterday's rows today. THIS ONE IS
// DIFFERENT, and the deviation is deliberate. A `message_outbox` row is a wake notification
// somebody is waiting on — the API's inline publish failed, so until this runs, a message
// exists that its recipient has not been told about. Five minutes of that is a message that
// looks lost. Seconds is the right order of magnitude, and the sweep is cheap when there is
// nothing owed: one indexed query against a partial index that is empty in the normal case.
const OUTBOX_INTERVAL_MS = Number(process.env.VOIID_OUTBOX_INTERVAL_MS) || 5_000;

// A publisher connection, used only by the sweep. The reapers need no Redis.
const publisher = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379', {
  // A worker that cannot reach Redis must keep sweeping (and keep failing visibly) rather
  // than queue commands forever and report success it never achieved.
  maxRetriesPerRequest: 2,
  enableOfflineQueue: false,
});
publisher.on('error', (e) => console.error('[workers] redis error:', e.message));

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
  /** Set while a pass is in flight (C02), so a hung job is distinguishable from an idle one.
   *  Cleared in `finally`, including on the error path. */
  startedAt: number | null;
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
  [...JOBS.map((j) => j.name), 'outbox'].map((name) => [
    name, { startedAt: null, lastRunAt: null, lastOkAt: null, lastError: null, lastResult: null },
  ])
);

// Its own overlap guard, because it has its own clock: a sweep that takes longer than the
// interval must not stack passes and multiply the publishes in flight.
let sweeping = false;
async function outboxTick(): Promise<void> {
  if (sweeping) return;
  sweeping = true;
  const state = jobs.outbox;
  state.lastRunAt = new Date().toISOString();
  state.startedAt = Date.now();
  try {
    const result = await flushOutbox((channel, payload) => publisher.publish(channel, payload));
    state.lastResult = result;
    state.lastOkAt = new Date().toISOString();
    state.lastError = null;
    // Silent when there is nothing owed, which is the normal case — a line every five seconds
    // is a log nobody reads. COUNTS ONLY: never a channel, a user id or a payload.
    if (result.claimed) {
      console.log(`[workers] outbox claimed=${result.claimed} published=${result.published} failed=${result.failed}`);
    }
  } catch (e) {
    state.lastError = (e as Error).message;
    // NEVER rethrow, for the same reason the main tick does not: one bad pass must not take
    // the process down and stop every future sweep.
    console.error('[workers] outbox sweep failed:', state.lastError);
  } finally {
    state.startedAt = null;
    sweeping = false;
  }
}

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
      state.startedAt = Date.now();
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
      } finally {
        state.startedAt = null;
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
  // C02: the status is derived from what the jobs RETURNED, not only from what they threw.
  //
  // Each job catches its own errors and reports counts — failed, abandoned, stuck,
  // objectsPending. This used to read only `lastError`, so retention could fail its SQL every
  // pass, or the reaper abandon rows every pass, and health stayed green: the process was up,
  // nothing escaped, and the numbers describing the failure sat unread in `lastResult`.
  const now = Date.now();
  const inputs: JobHealthInput[] = Object.entries(jobs).map(([name, state]) => ({
    name,
    // The outbox has its own, much faster clock; measuring its staleness against the reaper
    // interval would make a five-minute stall invisible.
    intervalMs: name === 'outbox' ? OUTBOX_INTERVAL_MS : INTERVAL_MS,
    now,
    lastRunAt: state.lastRunAt ? Date.parse(state.lastRunAt) : null,
    lastOkAt: state.lastOkAt ? Date.parse(state.lastOkAt) : null,
    lastError: state.lastError,
    lastResult: state.lastResult as Record<string, unknown> | null,
    startedAt: state.startedAt,
  }));
  const verdict = classifyJob.service(inputs);

  const out: Record<string, unknown> = {
    service: 'workers',
    status: verdict.status,
    interval_ms: INTERVAL_MS,
    outbox_interval_ms: OUTBOX_INTERVAL_MS,
    jobs,
    // Per-job status and the reasons behind it, so an operator is told WHICH job and WHY
    // rather than being handed five raw result objects to compare.
    health: verdict.jobs,
    media: { configured: r2Configured() },
  };
  try {
    await pool.query('select 1');
    out.db = 'up';
  } catch {
    out.db = 'down';
    out.status = 'failed';
  }
  // Anything other than ok is a 503: 'degraded' means work is not getting done, and a
  // monitor that only alerts on total failure will not notice a reaper that abandons every row.
  res.writeHead(out.status === 'ok' ? 200 : 503, { 'content-type': 'application/json' });
  res.end(JSON.stringify(out));
});

server.listen(PORT, () => console.log(`[voiid:workers] listening on :${PORT} (interval ${INTERVAL_MS}ms)`));

// Run once at boot so a restart immediately clears whatever piled up while down.
void tick();
const timer = setInterval(() => void tick(), INTERVAL_MS);
timer.unref?.(); // never hold the process open on the timer alone; the HTTP server does that

// The outbox debt is the one thing a restart should clear immediately: those are wakes
// somebody is already waiting on.
void outboxTick();
const outboxTimer = setInterval(() => void outboxTick(), OUTBOX_INTERVAL_MS);
outboxTimer.unref?.();

process.on('unhandledRejection', (reason) => {
  console.error('[voiid:workers] unhandledRejection:', (reason as Error)?.message ?? reason);
});

for (const sig of ['SIGTERM', 'SIGINT'] as const) {
  process.on(sig, () => {
    console.log(`[voiid:workers] ${sig} — shutting down`);
    clearInterval(timer);
    clearInterval(outboxTimer);
    server.close(() => {
      void Promise.allSettled([pool.end(), publisher.quit()]).finally(() => process.exit(0));
    });
  });
}
