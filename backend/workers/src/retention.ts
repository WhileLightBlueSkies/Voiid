// Retention sweep — the enforced half of the storage-limitation statement (Act s.8(7)).
//
// ============================ READ THIS FIRST ======================================
// UNTIL THIS FILE EXISTED, NOTHING HAD EVER DELETED A ROW FROM ANY OF THESE TABLES.
//   * security_events holds an IP address and, for pre-auth events, a phone number, and
//     grew without bound.
//   * otp_sessions holds a phone number and carries an `expires_at` that every read path
//     checks and no write path ever acted on — the row stopped being useful in five
//     minutes and stayed forever.
//   * admin_sessions holds an IP and a user agent; the only delete was the per-token
//     logout, so every expired session kept its IP.
//   * contact_pin_attempts holds sender_ip (missed by the original survey because it is a
//     security control rather than a log — the IP does not care what we call the table).
//   * call_metrics carried a suggested 90-day prune in its own migration, described as an
//     "ops cron" that was never wired up. That comment is the whole reason this process
//     exists: a retention period that lives in a console, or in a sentence, is not a
//     retention period.
// A stated period with no mechanism is not storage limitation; it is a sentence in a
// document. This is the mechanism.
// ===================================================================================
//
// METADATA ONLY. Nothing here can read a message, a call, a location share or a moment —
// those are end-to-end encrypted and the server holds ciphertext and no key. Every table
// swept here is telemetry or session bookkeeping.
//
// THE PERIODS ARE NAMED CONSTANTS IN THIS FILE, ON PURPOSE. data_retention_policy
// (030_dpdp.sql) is the DECLARED policy — what a notice or a console can quote. This file
// is the ENFORCED policy. They are deliberately two different things so that drift is
// visible: every pass writes its own constant back into `enforced_interval`, and a
// console showing declared ≠ enforced is showing a real defect rather than a value to
// quietly reconcile. Changing a period here is a diff someone reviews; changing it in a
// database console at 2am is not.
//
// EVERY DURATION IS AN ENGINEERING PLACEHOLDER pending legal sign-off. This code
// implements controls; it certifies nothing. [COUNSEL] docs/research/11_admin_dpdp.md §6.3
// carries the open question, and §6.4 the one that could invert it: IT Rules 2021 may
// impose a retention FLOOR on some of this, in which case 90 days is a minimum to check
// rather than a maximum to enforce.
import { pool, query } from './db';

// ── THE PERIODS ────────────────────────────────────────────────────────────────────
// Postgres interval literals, passed as parameters (never concatenated into SQL).

/** Grace ADDED to the row's own expiry. Exists only so a late verify attempt fails as
 *  "expired" rather than as "unknown session" — a 5-minute-old OTP row is already dead to
 *  every code path; this is purely about the error message. */
const OTP_SESSION_GRACE = '24 hours';

/** Abuse investigation window. Long enough to answer "was this account being brute-forced
 *  last quarter", short enough that an IP address is not kept for a year. */
const SECURITY_EVENT_RETENTION = '90 days';

/** Same window, same reason: the PIN limiter itself only ever reads the last hour and the
 *  last day (routes/reachability.ts), so everything older is evidence, not mechanism. */
const PIN_ATTEMPT_RETENTION = '90 days';

/** The number 016_call_metrics.sql suggested and left to nobody. Anonymous by
 *  construction — no user id, no call id, hour-bucketed — but the longer an anonymous
 *  sample set is kept the more surface it offers to correlation. */
const CALL_METRIC_RETENTION = '90 days';

/** The retention log is evidence about retention, and evidence is not exempt from it.
 *  Long enough to answer "was this enforced last year". */
const SWEEP_LOG_RETENTION = '365 days';

/** Rows per statement. A first run against a table that has been growing since launch
 *  must not be one enormous transaction holding locks while it rewrites the table. */
const DELETE_BATCH = 5000;

/** Statements per table per pass. Bounds the work a single pass can do, so a huge backlog
 *  drains over several passes instead of monopolising the worker (and the connection
 *  pool) for minutes on the first one. */
const MAX_BATCHES_PER_TABLE = 20;

interface SweepSpec {
  /** Must match a row in data_retention_policy, or the sweep refuses to run — see below. */
  table: string;
  /** The timestamp the period is measured from. */
  timeColumn: string;
  /** Age (fixed_interval) or grace past the row's own expiry (until_expiry). Null means
   *  the row's own expiry IS the period, with no grace. */
  interval: string | null;
  /** One line for the log; the full reasoning lives on the constant above. */
  why: string;
}

// `table` and `timeColumn` are interpolated into SQL because an identifier cannot be a
// bind parameter. They are compile-time constants in this file and never touch a request,
// a column value or an environment variable — the only string in these statements that
// comes from anywhere else is the interval, which IS a bind parameter.
const SWEEPS: SweepSpec[] = [
  {
    table: 'otp_sessions',
    timeColumn: 'expires_at',
    interval: OTP_SESSION_GRACE,
    why: 'phone number, useless once the code has expired',
  },
  {
    table: 'security_events',
    timeColumn: 'created_at',
    interval: SECURITY_EVENT_RETENTION,
    why: 'IP address and pre-auth phone number',
  },
  {
    table: 'admin_sessions',
    timeColumn: 'expires_at',
    interval: null,
    why: 'admin IP and user agent; an expired session authenticates nothing and only holds an IP',
  },
  {
    table: 'contact_pin_attempts',
    timeColumn: 'attempted_at',
    interval: PIN_ATTEMPT_RETENTION,
    why: 'sender IP on the PIN brute-force ledger',
  },
  {
    table: 'call_metrics',
    timeColumn: 'bucket_hour',
    interval: CALL_METRIC_RETENTION,
    why: 'anonymous call-quality samples; correlation surface grows with age',
  },
  {
    table: 'retention_sweep_log',
    timeColumn: 'swept_at',
    interval: SWEEP_LOG_RETENTION,
    why: 'the evidence trail, which is itself bounded',
  },
];

export interface RetentionResult {
  /** Rows deleted per table this pass. Absent key = nothing to delete. */
  deleted: Record<string, number>;
  /** Tables the sweep refused to touch because no declared policy row authorises it. */
  undeclared: string[];
  /** Tables where the declared period and the enforced constant disagree. */
  drift: string[];
  /** Tables whose delete threw. */
  failed: string[];
}

/**
 * One sweep pass. Pure idempotent deletes: safe to re-run, safe to run concurrently on two
 * boxes (the second finds the rows already gone), and safe to interrupt — the predicate,
 * not the schedule, decides what dies, so a pass that never ran yesterday deletes
 * yesterday's rows today.
 */
export async function runRetentionSweep(): Promise<RetentionResult> {
  const result: RetentionResult = { deleted: {}, undeclared: [], drift: [], failed: [] };

  // A table with no row in data_retention_policy is a table nobody declared a period for,
  // and a background job is not the place that decision gets made. The foreign key on
  // retention_sweep_log enforces the same rule at the database level; checking it here
  // means the sweep declines rather than deleting rows it cannot log.
  const declared = new Set(
    (await query<{ table_name: string }>(`select table_name from data_retention_policy`)).map(
      (r) => r.table_name
    )
  );

  for (const spec of SWEEPS) {
    if (!declared.has(spec.table)) {
      result.undeclared.push(spec.table);
      console.warn(
        `[workers] retention: ${spec.table} has no declared policy row; not sweeping ` +
          '(add it in a migration — the declared policy is what authorises the delete)'
      );
      continue;
    }
    try {
      const startedAt = Date.now();
      const deleted = await sweepTable(spec);
      const durationMs = Date.now() - startedAt;
      if (deleted) result.deleted[spec.table] = deleted;
      const drifted = await recordSweep(spec, deleted, durationMs);
      if (drifted) result.drift.push(spec.table);
    } catch (e) {
      // One broken table must not stop the others: they hold different people's data and
      // there is no reason a lock on call_metrics should delay deleting a phone number.
      result.failed.push(spec.table);
      console.error(`[workers] retention sweep failed for ${spec.table}: ${(e as Error).message}`);
    }
  }

  const total = Object.values(result.deleted).reduce((a, b) => a + b, 0);
  if (total) {
    const detail = Object.entries(result.deleted)
      .map(([t, n]) => `${t}=${n}`)
      .join(' ');
    // Counts only. A retention sweep that logged what it deleted would be retaining it.
    console.log(`[workers] retention swept ${total} row(s): ${detail}`);
  }
  return result;
}

/** Delete in bounded batches until the table is clean or the per-pass ceiling is hit. */
async function sweepTable(spec: SweepSpec): Promise<number> {
  const predicate = spec.interval
    ? `${spec.timeColumn} < now() - $1::interval`
    : `${spec.timeColumn} < now()`;
  const params = spec.interval ? [spec.interval] : [];

  // ctid subquery + LIMIT: the bounded form of "delete everything older than X". Deleting
  // in one statement would, on the first run against a table that has never been swept,
  // take a lock proportional to the entire backlog.
  const sql = `delete from ${spec.table}
                where ctid in (select ctid from ${spec.table}
                                where ${predicate}
                                limit ${DELETE_BATCH})`;

  let deleted = 0;
  for (let i = 0; i < MAX_BATCHES_PER_TABLE; i++) {
    const res = await pool.query(sql, params);
    const n = res.rowCount ?? 0;
    deleted += n;
    if (n < DELETE_BATCH) break; // the table is clean; stop before an empty round-trip
    if (i === MAX_BATCHES_PER_TABLE - 1) {
      console.warn(
        `[workers] retention: ${spec.table} still has rows past its period after ` +
          `${MAX_BATCHES_PER_TABLE} batches; the backlog will drain over the next passes`
      );
    }
  }
  return deleted;
}

/**
 * Write the evidence and the enforced period back. Returns true when the DECLARED period
 * and this file's constant disagree — which means the published policy and the running
 * code have drifted, and is a defect to surface rather than a value to reconcile.
 */
async function recordSweep(spec: SweepSpec, deleted: number, durationMs: number): Promise<boolean> {
  // Only rows that actually deleted something get a log row. Recording every silent pass
  // would add thousands of "0" rows a week and bury the ones that mean anything —
  // `last_sweep_at` on the policy row is the "it ran" evidence, and it is updated every
  // pass whether or not anything matched.
  if (deleted > 0) {
    await query(
      `insert into retention_sweep_log (table_name, deleted_count, duration_ms) values ($1, $2, $3)`,
      [spec.table, deleted, durationMs]
    );
  }

  const rows = await query<{ drift: boolean }>(
    `update data_retention_policy
        set enforced_interval = $2::interval,
            last_sweep_at = now(),
            last_sweep_deleted = $3
      where table_name = $1
      returning (declared_interval is distinct from $2::interval) as drift`,
    [spec.table, spec.interval, deleted]
  );
  const drift = rows[0]?.drift === true;
  if (drift) {
    console.warn(
      `[workers] retention: ${spec.table} declares a different period than the worker enforces ` +
        `(enforcing ${spec.interval ?? 'row expiry, no grace'}) — the published policy and the ` +
        'code disagree; fix one of them'
    );
  }
  return drift;
}
