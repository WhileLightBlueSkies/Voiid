// Plain Postgres pool (Section 2.2). No Supabase-only magic in critical paths —
// swapping Supabase -> Vultr Managed Postgres / RDS is a DATABASE_URL change.
import { Pool } from 'pg';

// Supabase requires TLS. Enable SSL unless connecting to a local Postgres.
// (Stays a DATABASE_URL change to swap hosts — Section 2.2.)
const url = process.env.DATABASE_URL ?? '';
const isLocal = url.includes('localhost') || url.includes('127.0.0.1');

export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: isLocal ? undefined : { rejectUnauthorized: false },
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
