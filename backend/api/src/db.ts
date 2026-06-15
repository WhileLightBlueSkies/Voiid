// Plain Postgres pool (Section 2.2). No Supabase-only magic in critical paths —
// swapping Supabase -> Vultr Managed Postgres / RDS is a DATABASE_URL change.
import { Pool } from 'pg';

export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

export async function query<T = any>(text: string, params?: unknown[]): Promise<T[]> {
  const res = await pool.query(text, params);
  return res.rows as T[];
}
