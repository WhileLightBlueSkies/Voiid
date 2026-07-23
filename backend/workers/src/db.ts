// Postgres pool for the worker process.
//
// WHY this duplicates backend/api/src/db.ts instead of importing it: @voiid/workers
// must be independently restartable and independently deployable. Importing @voiid/api
// would drag express, firebase-admin, ioredis and the whole route tree into a process
// whose entire job is "delete expired rows", and would mean an API build failure takes
// the reaper down with it. Same DATABASE_URL, same TLS rule, ~10 duplicated lines —
// that is the accepted cost.
import { Pool } from 'pg';

const url = process.env.DATABASE_URL ?? '';
// Supabase (and any managed Postgres) requires TLS; local dev does not.
const isLocal = url.includes('localhost') || url.includes('127.0.0.1');

export const pool = new Pool({
  connectionString: url,
  ssl: isLocal ? undefined : { rejectUnauthorized: false },
  // The reaper is a single low-frequency job; it must never be the reason the DB
  // runs out of connections for the API.
  max: 2,
});

export async function query<T = any>(text: string, params?: unknown[]): Promise<T[]> {
  const res = await pool.query(text, params);
  return res.rows as T[];
}
