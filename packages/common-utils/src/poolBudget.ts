// What each service is allowed to consume from the database (P04).
//
// ── WHAT WAS UNBOUNDED ───────────────────────────────────────────────────────────
//
// The API and games pools took node-postgres defaults: `max: 10` per process, no connection
// acquisition timeout, no statement timeout. Three consequences, all of which only show up
// under load:
//
//   * A slow query holds a connection until it finishes, and with no statement timeout there
//     is no "until" — one pathological query holds a connection for the life of the process.
//   * With no acquisition timeout a request that cannot get a connection waits FOREVER instead
//     of failing. Under saturation the queue grows without limit and every waiting request
//     holds its socket and its memory with it.
//   * The database enforces a connection ceiling across the WHOLE deployment. Four processes
//     each claiming an unstated share is how the fifth cannot connect at all.
//
// ── THESE ARE BUDGETS, NOT TUNING ────────────────────────────────────────────────
//
// P04 says to choose final pool sizes from measurement, and that measurement has NOT been
// done. What this file provides is the thing measurement needs first: a number written down in
// one place, per service, that a load test can be run against and adjusted. The values are
// argued from the connection ceiling and the shape of each service's work, and every one is
// overridable per deployment.
import type { PoolConfig } from 'pg';

export type PoolService = 'api' | 'games' | 'workers' | 'websocket';

export interface PoolBudget extends PoolConfig {
  max: number;
  connectionTimeoutMillis: number;
  idleTimeoutMillis: number;
  /** Server-side, in milliseconds. See the note on `statement_timeout` below. */
  statement_timeout: number;
}

interface Defaults {
  max: number;
  /** How long a caller may wait for a connection before being told no. */
  acquireMs: number;
  /** How long ONE statement may run on the server before Postgres cancels it. */
  statementMs: number;
  env: string;
  why: string;
}

/**
 * Per-service defaults. The sum is deliberately well under the ceiling of the smallest paid
 * Supabase tier (60 direct connections), leaving room for migrations, a psql session and a
 * deploy running alongside the services.
 */
const DEFAULTS: Record<PoolService, Defaults> = {
  api: {
    max: 20, acquireMs: 3_000, statementMs: 10_000, env: 'VOIID_API_POOL_MAX',
    why: 'the only service on the request path; everything else is background',
  },
  games: {
    max: 8, acquireMs: 3_000, statementMs: 10_000, env: 'VOIID_GAMES_POOL_MAX',
    why: 'turn resolution is short and bounded, and a match is not a web request',
  },
  workers: {
    max: 2, acquireMs: 5_000, statementMs: 30_000, env: 'VOIID_WORKERS_POOL_MAX',
    why: 'one low-frequency job at a time, and it must never starve the API. Its sweeps are ' +
         'legitimately slower than a request, hence the longer statement budget',
  },
  websocket: {
    max: 2, acquireMs: 2_000, statementMs: 5_000, env: 'VOIID_WS_POOL_MAX',
    why: 'one indexed lookup per socket connect (S03) and nothing else. A socket that cannot ' +
         'verify its session quickly should be told to retry, not queued',
  },
};

function positiveInt(raw: string | undefined, fallback: number): number {
  if (!raw) return fallback;
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

/**
 * The pg pool options for a service.
 *
 * `statement_timeout` is passed as a CONNECTION PARAMETER rather than kept client-side on
 * purpose: a client-side deadline abandons the caller but leaves the query running on the
 * database, which is the expensive half. Postgres cancels it for real.
 */
export function poolBudget(
  service: PoolService,
  env: Record<string, string | undefined> = process.env
): PoolBudget {
  const d = DEFAULTS[service];
  return {
    max: positiveInt(env[d.env], d.max),
    // A caller that cannot get a connection in this long is better told so: under saturation an
    // unbounded wait converts a slow database into an out-of-memory process.
    connectionTimeoutMillis: positiveInt(env[`${d.env}_ACQUIRE_MS`], d.acquireMs),
    // Idle connections are returned rather than held against the deployment ceiling forever.
    idleTimeoutMillis: positiveInt(env[`${d.env}_IDLE_MS`], 30_000),
    statement_timeout: positiveInt(env[`${d.env}_STATEMENT_MS`], d.statementMs),
  };
}

/** One line for the boot log, so the share this process claims is visible without the env. */
export function describePoolBudget(service: PoolService, b: PoolBudget): string {
  return `${service} pool: max=${b.max} acquire=${b.connectionTimeoutMillis}ms ` +
    `statement=${b.statement_timeout}ms idle=${b.idleTimeoutMillis}ms — ${DEFAULTS[service].why}`;
}
