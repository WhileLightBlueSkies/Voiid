// Plain Postgres pool, identical in shape to backend/api's — swapping hosts stays a
// DATABASE_URL change.
//
// This service touches Postgres RARELY: once when a match starts, once when it ends. Every
// read and write in between is Redis. That asymmetry is the whole storage design
// (docs/GAMES.md §2), so a new query in the move path is a red flag, not a small addition.
import { Pool } from 'pg';
import { resolveDatabaseSsl, describeDatabaseTls, poolBudget, describePoolBudget } from '@voiid/common-utils';

const url = process.env.DATABASE_URL ?? '';
// S05: the hostname is PARSED, and a remote server's certificate is verified. The old
// `url.includes('localhost')` matched anywhere in the string — a password, a database name, a
// host called localhost.attacker.example — and paired with `rejectUnauthorized: false` it meant
// the connection was encrypted to whoever answered. See packages/common-utils/src/databaseTls.ts.
const ssl = resolveDatabaseSsl(url);
// Said once at boot, like the secretbox line in index.ts: whether certificates are actually
// being checked is not something an operator should have to infer from an env file.
console.log(`[voiid:games] ${describeDatabaseTls(ssl)}`);
// What this process may claim from the database (P04). Stated rather than inherited:
// the pg defaults have no acquisition timeout and no statement timeout, so a slow query
// holds a connection indefinitely and a saturated pool queues callers forever.
const budget = poolBudget('games');
console.log(`[voiid:games] ${describePoolBudget('games', budget)}`);

export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl,
  ...budget,
});

export async function query<T = any>(text: string, params?: unknown[]): Promise<T[]> {
  const res = await pool.query(text, params);
  return res.rows as T[];
}
