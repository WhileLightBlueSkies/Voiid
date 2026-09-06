// The sweep that keeps the promise the send transaction made (M01).
//
// POST /messages/send writes one `message_outbox` row per recipient channel in the SAME
// transaction as the message, then publishes them inline immediately after commit. That
// inline publish settles almost everything — this job exists for the rest: the wakes owed
// when Redis was unreachable, or when the process died between the commit and the publish.
// Without it, those messages exist and nobody is ever told; they surface whenever the
// recipient next happens to poll, which on a backgrounded phone is not soon.
//
// AT-LEAST-ONCE, DELIBERATELY. A duplicate wake costs a redundant fetch of a message the
// client already holds and dedupes by id. A lost wake costs a message nobody knows about.
import { query } from './db';

/**
 * How many times a wake is attempted before it is left for a person.
 *
 * A row that has failed this many times is not failing for a reason another attempt will fix
 * — a malformed channel, a payload Redis will not take — and retrying it forever would let
 * one bad row consume the batch ahead of live traffic. It stays in the table, `failed` and
 * visible, rather than being deleted: an undelivered notification is exactly the sort of
 * thing that must not disappear quietly.
 */
export const OUTBOX_MAX_ATTEMPTS = Number(process.env.VOIID_OUTBOX_MAX_ATTEMPTS) || 8;

/** Rows per sweep. Bounded so a backlog drains steadily instead of in one enormous batch. */
const OUTBOX_BATCH = Number(process.env.VOIID_OUTBOX_BATCH) || 200;

/**
 * How many publishes are in flight at once.
 *
 * Bounded because the whole batch firing at Redis simultaneously is how a sweep meant to
 * recover from an outage turns into the thing that causes the next one.
 */
const OUTBOX_CONCURRENCY = Number(process.env.VOIID_OUTBOX_CONCURRENCY) || 8;

/** Long enough for a slow publish, short enough that a dead worker's rows come back soon. */
const OUTBOX_LEASE_SECONDS = Number(process.env.VOIID_OUTBOX_LEASE_SECONDS) || 60;

export type Publish = (channel: string, payload: string) => Promise<unknown>;

export interface SweepResult {
  claimed: number;
  published: number;
  failed: number;
}

interface Claimed {
  id: string;
  channel: string;
  payload: unknown;
}

/**
 * Claim, publish, settle.
 *
 * `for update skip locked` is what makes two boxes running this job safe: the second sweep
 * steps over whatever the first is holding rather than blocking on it or duplicating it. The
 * lease covers the other half — a worker that dies mid-publish releases nothing, so without
 * an expiry its rows would sit in flight forever.
 */
export async function flushOutbox(
  publish: Publish,
  opts: { batch?: number } = {}
): Promise<SweepResult> {
  const claimed = await query<Claimed>(
    `with due as (
        select id from message_outbox
         where status in ('pending', 'failed')
           and attempts < $2
           and (lease_until is null or lease_until < now())
         order by created_at
         limit $1
         for update skip locked
     )
     update message_outbox o
        set attempts = o.attempts + 1,
            lease_until = now() + make_interval(secs => $3)
       from due
      where o.id = due.id
     returning o.id, o.channel, o.payload`,
    [opts.batch ?? OUTBOX_BATCH, OUTBOX_MAX_ATTEMPTS, OUTBOX_LEASE_SECONDS]
  );
  if (!claimed.length) return { claimed: 0, published: 0, failed: 0 };

  const delivered: string[] = [];
  const failures: { id: string; error: string }[] = [];

  // Fixed-size workers over a shared cursor, rather than chunked Promise.all: a chunk runs at
  // the speed of its slowest member, so one hanging publish idles the rest of the batch.
  let cursor = 0;
  await Promise.all(
    Array.from({ length: Math.min(OUTBOX_CONCURRENCY, claimed.length) }, async () => {
      while (cursor < claimed.length) {
        const row = claimed[cursor++];
        try {
          await publish(row.channel, JSON.stringify(row.payload));
          delivered.push(row.id);
        } catch (e) {
          failures.push({ id: row.id, error: String((e as Error)?.message ?? e).slice(0, 500) });
        }
      }
    })
  );

  if (delivered.length) {
    await query(
      `update message_outbox
          set status = 'published', published_at = now(), lease_until = null, last_error = null
        where id = any($1::uuid[])`,
      [delivered]
    );
  }
  if (failures.length) {
    // The lease is released rather than left to expire: the row is known to be free now, and
    // making the next sweep wait out a lease nobody holds would delay every retry by a minute.
    await query(
      `update message_outbox o
          set status = 'failed', lease_until = null, last_error = f.error
         from unnest($1::uuid[], $2::text[]) as f(id, error)
        where o.id = f.id`,
      [failures.map((f) => f.id), failures.map((f) => f.error)]
    );
  }

  return { claimed: claimed.length, published: delivered.length, failed: failures.length };
}
