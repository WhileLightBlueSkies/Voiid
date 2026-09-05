// The durable half of "the message was sent" (M01).
//
// The route used to commit the message and then publish a wake to Redis. If that publish
// failed — Redis restarting, a blip, the process dying in between — the message existed and
// nobody was ever told. It surfaced whenever the recipient next happened to poll, which on a
// backgrounded phone is not soon.
//
// So the obligation is written down in the same transaction as the message: a committed
// message always carries its unsent announcements. The route still publishes inline right
// after commit, because that is the latency path and it settles them in milliseconds; what
// this adds is that a failure there leaves a row the worker will keep.
//
// AT-LEAST-ONCE, DELIBERATELY. A duplicate wake costs a redundant fetch of a message the
// client already has and dedupes by id. A lost wake costs a message nobody knows about.
import { publisher } from './redis';
import type { query as Query } from './db';

export interface OutboxEntry {
  channel: string;
  payload: unknown;
}

/**
 * Record the announcements this message owes, inside the transaction that creates it.
 *
 * One statement for the whole set: a group send resolves to one channel per recipient user,
 * and a row-at-a-time insert would put the per-recipient round trip back into the send path
 * that M01's bulk ciphertext insert just took out of it.
 */
export async function enqueueOutbox(
  execute: typeof Query,
  messageId: string,
  entries: OutboxEntry[]
): Promise<string[]> {
  if (!entries.length) return [];
  const rows = await execute<{ id: string }>(
    `insert into message_outbox (message_id, channel, payload)
     select $1, t.channel, t.payload::jsonb
       from unnest($2::text[], $3::text[]) as t(channel, payload)
     returning id`,
    [messageId, entries.map((e) => e.channel), entries.map((e) => JSON.stringify(e.payload))]
  );
  return rows.map((r) => r.id);
}

/**
 * The fast path: publish what was just committed and settle the rows.
 *
 * Never throws. A failure here is not a failed send — the message is committed and the
 * obligation is durable — so it must not turn a successful send into a 500 the client would
 * retry. The rows simply stay `pending` and the sweep picks them up.
 */
export async function publishOutbox(
  execute: typeof Query,
  entries: { id: string; channel: string; payload: unknown }[]
): Promise<void> {
  const settled: string[] = [];
  for (const entry of entries) {
    try {
      await publisher.publish(entry.channel, JSON.stringify(entry.payload));
      settled.push(entry.id);
    } catch {
      // Left owed on purpose. Marking it failed here would be an extra write on a path that
      // has just proved the infrastructure is unhappy; `pending` is already claimable.
    }
  }
  if (!settled.length) return;
  try {
    await execute(
      `update message_outbox set status = 'published', published_at = now(), lease_until = null
        where id = any($1::uuid[])`,
      [settled]
    );
  } catch {
    // Published but not marked. The sweep will publish these again, which is exactly the
    // at-least-once behaviour this design accepts — and the reason clients dedupe by id.
  }
}
