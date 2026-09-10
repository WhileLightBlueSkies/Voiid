// GET /agent/health — the metrics shape Bask polls for its graphs.
//
// SEPARATE FROM THE EXISTING GET /health, deliberately, and neither replaces the other.
// The old one is consumed by deploy-dev.sh's readiness gate, by Uptime Kuma and by the
// rollback logic, all of which parse specific fields (`build`, `status`) and would break
// under a reshape — its 503-when-degraded behaviour is load-bearing for the deploy gate.
// This one answers a FIXED external schema that rejects extra fields, so it cannot carry
// this project's `build`/`firebase`/`media` keys and cannot be merged into that route.
//
// It returns 200 whatever the health verdict, because the verdict is IN the body: a
// monitoring client that graphs `status` needs the payload, and a 503 with a body is the
// kind of thing HTTP clients turn into an exception before anything reads it.
import { Router } from 'express';
import { asyncHandler } from '../util';
import { pool } from '../db';
import { redis } from '../redis';
import { cpus, loadavg, totalmem, freemem } from 'node:os';
import { statfsSync } from 'node:fs';

const router = Router();

/** Process start, captured at module load — the same notion as index.ts' STARTED_AT. */
const STARTED_AT = new Date();

type Health = 'healthy' | 'degraded' | 'unhealthy';

/** Round to one decimal and clamp into the 0–100 the contract specifies. */
function percent(value: number): number {
  return Math.max(0, Math.min(100, Math.round(value * 10) / 10));
}

/**
 * Time a dependency check, and never let a hung dependency hang the poll.
 *
 * The whole point of a health endpoint is that it answers when things are broken; a probe
 * with no timeout inherits the outage it is trying to report, and Bask sees a timeout
 * rather than the "unhealthy postgres" it could have graphed.
 */
async function probe(name: string, check: () => Promise<unknown>, timeoutMs = 2_000) {
  const started = Date.now();
  try {
    await Promise.race([
      check(),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), timeoutMs)),
    ]);
    const latencyMs = Date.now() - started;
    // Reachable but slow is its own state, and the one worth catching early — a database
    // answering `select 1` in over a second is already in trouble.
    return { name, status: (latencyMs > 1_000 ? 'degraded' : 'healthy') as Health, latencyMs };
  } catch {
    return { name, status: 'unhealthy' as Health, latencyMs: Date.now() - started };
  }
}

router.get('/health', asyncHandler(async (_req, res) => {
  const now = new Date();

  const dependencies = await Promise.all([
    probe('postgres', () => pool.query('select 1')),
    probe('redis', () => redis.ping()),
  ]);

  // CPU from the 1-minute load average over core count, not from a sampled busy loop: this
  // endpoint is polled on a schedule and must stay cheap. It is an approximation of
  // utilisation, which is what a graph wants.
  const cpuPercent = percent((loadavg()[0] / Math.max(1, cpus().length)) * 100);
  const memoryPercent = percent(((totalmem() - freemem()) / Math.max(1, totalmem())) * 100);

  let diskPercent: number | undefined;
  try {
    const fs = statfsSync('/');
    const total = Number(fs.blocks) * Number(fs.bsize);
    const free = Number(fs.bfree) * Number(fs.bsize);
    if (total > 0) diskPercent = percent(((total - free) / total) * 100);
  } catch {
    // The contract makes each metric individually optional, so an unreadable filesystem
    // drops the field rather than reporting a zero that would graph as an empty disk.
  }

  const worst = dependencies.reduce<Health>((acc, d) => {
    if (d.status === 'unhealthy' || acc === 'unhealthy') return 'unhealthy';
    if (d.status === 'degraded' || acc === 'degraded') return 'degraded';
    return 'healthy';
  }, 'healthy');

  res.status(200).json({
    schemaVersion: 1,
    status: worst,
    service: 'api',
    // The npm version of @voiid/api. VOIID_BUILD_SHA below is the precise identifier;
    // this is the human one, and the deploy stamps the other.
    version: process.env.npm_package_version ?? '0.1.0',
    environment: process.env.NODE_ENV === 'production' ? 'production' : 'development',
    // Stamped onto .env by deploy-dev.sh. Null rather than the string 'unknown' when absent,
    // because the contract allows null and a hand-run box genuinely has no deploy sha.
    commitSha: process.env.VOIID_BUILD_SHA ?? null,
    startedAt: STARTED_AT.toISOString(),
    uptimeSeconds: Math.floor((now.getTime() - STARTED_AT.getTime()) / 1000),
    observedAt: now.toISOString(),
    metrics: {
      cpuPercent,
      memoryPercent,
      ...(diskPercent === undefined ? {} : { diskPercent }),
    },
    dependencies,
    // The background services on this box, reported from the API's own point of view.
    // Shelling out to pm2 on every poll would make a health check depend on a subprocess,
    // so this route does not — POST /command with `status` is the authoritative view, and
    // this is the cheap one Bask can poll on a schedule.
    workers: [],
  });
}));

export default router;
