//
// What a worker pass actually means (C02).
//
// ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────
//
// Each job catches its own errors and RETURNS counts — `failed`, `abandoned`,
// `objectsPending`, `stuck`. The supervisor treated any returned value as success and only
// recorded `lastError` when a job THREW. So retention could fail its SQL every pass, or the
// story reaper could abandon rows on every pass, and /health stayed green: the process was up,
// no exception escaped, and the numbers describing the failure were sitting unread in
// `lastResult`.
//
// There was also no freshness gate. A job that hung, or one whose interval stopped firing, is
// indistinguishable from an idle one if all you check is "did the last pass throw".
//
// Pure and clock-injected so every branch is testable without waiting for anything.
//

export type JobStatus = 'ok' | 'degraded' | 'stale' | 'failed';

/** Whatever a job returned. Counted, never inspected for row detail. */
export type JobResult = Record<string, unknown> | null;

export interface JobHealthInput {
  name: string;
  /** How often this job is meant to run, so staleness is relative to its own cadence. */
  intervalMs: number;
  now: number;
  lastRunAt: number | null;
  lastOkAt: number | null;
  lastError: string | null;
  lastResult: JobResult;
  /** Set while a pass is in flight, so a hung job can be told from an idle one. */
  startedAt: number | null;
}

export interface JobHealth {
  status: JobStatus;
  reasons: string[];
}

/**
 * How many intervals may pass with no success before it is worth waking someone.
 *
 * Three rather than one: a single missed tick is a slow pass or a restart, and paging on that
 * is how a health check gets muted.
 */
const STALE_INTERVALS = Number(process.env.VOIID_WORKER_STALE_INTERVALS) || 3;

/**
 * Counts that mean "this pass did not finish its work", by the name the jobs already use.
 *
 * Matched by KEY rather than by inspecting values generically, so adding a count to a result
 * cannot silently start or stop affecting health.
 */
const FAILURE_COUNTS = ['failed', 'abandoned', 'stuck', 'objectsPending', 'objectsQueued'] as const;

const rank: Record<JobStatus, number> = { ok: 0, degraded: 1, stale: 2, failed: 3 };

export function classifyJob(input: JobHealthInput): JobHealth {
  const reasons: string[] = [];
  let status: JobStatus = 'ok';
  const worsen = (to: JobStatus) => { if (rank[to] > rank[status]) status = to; };

  if (input.lastError) {
    worsen('failed');
    reasons.push(`last pass threw: ${input.lastError}`);
  }

  // THE C02 CASE. A returned count is the job telling us it could not finish, in the only
  // way it has; treating that as success is choosing not to listen.
  for (const key of FAILURE_COUNTS) {
    const value = Number((input.lastResult as Record<string, unknown> | null)?.[key] ?? 0);
    if (Number.isFinite(value) && value > 0) {
      worsen('degraded');
      reasons.push(`${key}=${value}`);
    }
  }

  const staleAfter = input.intervalMs * STALE_INTERVALS;

  // A pass still running long past its own interval is hung, not busy.
  // `>=`: a pass that has been running for a full staleness window IS hung, not on the
  // boundary of being fine.
  if (input.startedAt !== null && input.now - input.startedAt >= staleAfter) {
    worsen('stale');
    reasons.push(`still running after ${Math.round((input.now - input.startedAt) / 1000)}s`);
  }

  // Never having run is not a failure: the process may have just booted, and the first tick
  // has not landed. Only a job that HAS run and then stopped succeeding is stale.
  if (input.lastRunAt !== null) {
    const age = input.lastOkAt === null ? input.now - input.lastRunAt : input.now - input.lastOkAt;
    if (age >= staleAfter) {
      worsen('stale');
      reasons.push(`has not succeeded for ${Math.round(age / 1000)}s`);
    }
  }

  return { status, reasons };
}

/**
 * The service's status is its worst job's, not an average.
 *
 * One broken job among five is the thing worth knowing, and any aggregation that lets four
 * healthy ones outvote it is a health check that hides the failure it exists to report.
 */
classifyJob.service = function service(inputs: JobHealthInput[]): {
  status: JobStatus;
  jobs: Record<string, JobHealth>;
} {
  const jobs: Record<string, JobHealth> = {};
  let status: JobStatus = 'ok';
  for (const input of inputs) {
    const health = classifyJob(input);
    jobs[input.name] = health;
    if (rank[health.status] > rank[status]) status = health.status;
  }
  return { status, jobs };
};
