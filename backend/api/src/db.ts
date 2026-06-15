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
