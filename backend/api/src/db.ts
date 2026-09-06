// Plain Postgres pool (Section 2.2). No Supabase-only magic in critical paths —
// swapping Supabase -> Vultr Managed Postgres / RDS is a DATABASE_URL change.
import { Pool } from 'pg';
import { resolveDatabaseSsl, describeDatabaseTls, poolBudget, describePoolBudget } from '@voiid/common-utils';

// Supabase requires TLS. Enable SSL unless connecting to a local Postgres.
// (Stays a DATABASE_URL change to swap hosts — Section 2.2.)
const url = process.env.DATABASE_URL ?? '';
// S05: the hostname is PARSED, and a remote server's certificate is verified. The old
// `url.includes('localhost')` matched anywhere in the string — a password, a database name, a
// host called localhost.attacker.example — and paired with `rejectUnauthorized: false` it meant
// the connection was encrypted to whoever answered. See packages/common-utils/src/databaseTls.ts.
const ssl = resolveDatabaseSsl(url);
// Said once at boot, like the secretbox line in index.ts: whether certificates are actually
// being checked is not something an operator should have to infer from an env file.
console.log(`[voiid:api] ${describeDatabaseTls(ssl)}`);
// What this process may claim from the database (P04). Stated rather than inherited:
// the pg defaults have no acquisition timeout and no statement timeout, so a slow query
// holds a connection indefinitely and a saturated pool queues callers forever.
const budget = poolBudget('api');
console.log(`[voiid:api] ${describePoolBudget('api', budget)}`);

export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl,
  ...budget,
});

export async function query<T = any>(text: string, params?: unknown[]): Promise<T[]> {
  const res = await pool.query(text, params);
  return res.rows as T[];
}

// The callback must return its result before the caller sends a response or publishes
// notifications. Row locks and writes use the same connection until commit.
export async function withTransaction<T>(work: (execute: typeof query) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('begin');
    const execute: typeof query = async (sql, params) => (await client.query(sql, params)).rows;
    const result = await work(execute);
    await client.query('commit');
    return result;
  } catch (error) {
    await client.query('rollback');
    throw error;
  } finally {
    client.release();
  }
}
