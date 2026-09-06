// Postgres pool for the worker process.
//
// WHY this duplicates backend/api/src/db.ts instead of importing it: @voiid/workers
// must be independently restartable and independently deployable. Importing @voiid/api
// would drag express, firebase-admin, ioredis and the whole route tree into a process
// whose entire job is "delete expired rows", and would mean an API build failure takes
// the reaper down with it. Same DATABASE_URL, same TLS rule, ~10 duplicated lines —
// that is the accepted cost.
import { Pool } from 'pg';
import { resolveDatabaseSsl, describeDatabaseTls, poolBudget, describePoolBudget } from '@voiid/common-utils';

const url = process.env.DATABASE_URL ?? '';
// Supabase (and any managed Postgres) requires TLS; local dev does not.
// S05: the hostname is PARSED, and a remote server's certificate is verified. The old
// `url.includes('localhost')` matched anywhere in the string — a password, a database name, a
// host called localhost.attacker.example — and paired with `rejectUnauthorized: false` it meant
// the connection was encrypted to whoever answered. See packages/common-utils/src/databaseTls.ts.
const ssl = resolveDatabaseSsl(url);
// Said once at boot, like the secretbox line in index.ts: whether certificates are actually
// being checked is not something an operator should have to infer from an env file.
console.log(`[voiid:workers] ${describeDatabaseTls(ssl)}`);
// What this process may claim from the database (P04). Stated rather than inherited:
// the pg defaults have no acquisition timeout and no statement timeout, so a slow query
// holds a connection indefinitely and a saturated pool queues callers forever.
const budget = poolBudget('workers');
console.log(`[voiid:workers] ${describePoolBudget('workers', budget)}`);

export const pool = new Pool({
  connectionString: url,
  ssl,
  // The reaper is a single low-frequency job; it must never be the reason the DB runs out of
  // connections for the API. That intent is preserved in the shared budget (P04) rather than
  // repeated here, alongside the acquisition and statement deadlines it never had.
  ...budget,
});

export async function query<T = any>(text: string, params?: unknown[]): Promise<T[]> {
  const res = await pool.query(text, params);
  return res.rows as T[];
}
