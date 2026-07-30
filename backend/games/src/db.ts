// Plain Postgres pool, identical in shape to backend/api's — swapping hosts stays a
// DATABASE_URL change.
//
// This service touches Postgres RARELY: once when a match starts, once when it ends. Every
// read and write in between is Redis. That asymmetry is the whole storage design
// (docs/GAMES.md §2), so a new query in the move path is a red flag, not a small addition.
import { Pool } from 'pg';

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
