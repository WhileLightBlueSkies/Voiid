// Visibility expires in read paths. Cleanup transfers keys and removes metadata atomically.
import { pool } from './db';

export interface ReapResult {
  claimed: number;
  objectsDeleted: number;
  rowsDeleted: number;
  failed: number;
  abandoned: number;
  objectsQueued: number;
}

export async function reapStories(): Promise<ReapResult> {
  const client = await pool.connect();
  try {
    await client.query('begin');
    const batch = await client.query<{ id: string; r2_key: string; reap_attempts: number }>(
      `select id, r2_key, reap_attempts from stories
       where expires_at < now() - interval '1 hour'
       order by expires_at limit 200 for update skip locked`
    );
    let queued = 0;
    for (const row of batch.rows) {
      if (!row.r2_key) continue;
      const inserted = await client.query(
        `insert into erasure_pending_objects(r2_key) values ($1) on conflict (r2_key) do nothing`,
        [row.r2_key]
      );
      queued += inserted.rowCount ?? 0;
    }
    const gone = await client.query('delete from stories where id = any($1::uuid[])', [batch.rows.map(r => r.id)]);
    await client.query('commit');
    return { claimed: batch.rowCount ?? 0, objectsDeleted: 0, rowsDeleted: gone.rowCount ?? 0,
      failed: 0, abandoned: batch.rows.filter(r => r.reap_attempts >= 5).length, objectsQueued: queued };
  } catch (e) {
    await client.query('rollback').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}
