import { randomUUID } from 'node:crypto';
import { query } from './db';
import { deleteObject, r2Configured } from './r2';

export async function claimObjects(limit = 100) {
  return query<{ r2_key: string; claim_token: string }>(
    `with candidates as (
       select r2_key from erasure_pending_objects
       where next_attempt_at <= now() and (lease_until is null or lease_until <= now())
       order by next_attempt_at, queued_at limit $1 for update skip locked
     ) update erasure_pending_objects p
       set claim_token = $2, lease_until = now() + interval '5 minutes',
           attempts = attempts + 1, last_attempt_at = now()
       from candidates c where p.r2_key = c.r2_key returning p.r2_key, p.claim_token`,
    [limit, randomUUID()]
  );
}

export async function completeObject(key: string, token: string): Promise<number> {
  const rows = await query(
    `delete from erasure_pending_objects where r2_key = $1 and claim_token = $2
       and lease_until > now() returning r2_key`, [key, token]);
  return rows.length;
}

// Bounded pass, unlimited durable retries with capped backoff. No private keys in errors.
export async function drainObjects(remove = deleteObject, configured = r2Configured()) {
  let objectsDeleted = 0;
  let failed = 0;
  if (configured) {
    for (const row of await claimObjects()) {
      try {
        await remove(row.r2_key);
        objectsDeleted += await completeObject(row.r2_key, row.claim_token);
      } catch {
        failed++;
        await query(`update erasure_pending_objects
          set claim_token = null, lease_until = null,
              next_attempt_at = now() + make_interval(secs => least(3600, 30 * least(attempts, 120))),
              last_error = 'object deletion failed'
          where r2_key = $1 and claim_token = $2 and lease_until > now()`,
          [row.r2_key, row.claim_token]);
      }
    }
  }
  const pending = await query<{ n: string }>('select count(*)::text as n from erasure_pending_objects');
  return { objectsDeleted, failed, objectsPending: Number(pending[0].n) };
}
