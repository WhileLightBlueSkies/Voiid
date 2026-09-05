// Retry-safe message acceptance (M01).
//
// A send that is accepted and then not acknowledged — the reply lost, the socket dropped, the
// app killed between commit and 200 — is retried by the client, because the client genuinely
// cannot tell the difference between "not delivered" and "delivered, reply lost". Without a
// stable id from the sender that retry is a NEW message. This is the machinery that lets the
// second attempt be recognised as the first one.
import { createHash } from 'crypto';
import type { query as Query } from './db';

/** Bounded because it lands in an indexed column and arrives from a client. */
export const MAX_CLIENT_MESSAGE_ID = 200;

/**
 * The fingerprint answers one question: is this the SAME message, or a different one wearing
 * the same key?
 *
 * Without it, a client with a buggy id generator (a reused counter, a reset after reinstall)
 * would have its second, genuinely different message swallowed and reported as delivered.
 * That is a worse failure than the duplicate this whole mechanism exists to prevent, because
 * it is silent — so a key reused for different content is refused rather than absorbed.
 *
 * Canonicalised, not JSON.stringify'd over the request: key order and absent-vs-null must not
 * change the digest, or a retry from a client that serialises differently on the second
 * attempt would look like a different message and be refused. Recipients are sorted for the
 * same reason — the bundle order is not meaningful and clients do not guarantee it.
 */
export function payloadFingerprint(input: {
  conversationId: string;
  contentType?: unknown;
  mediaUrl?: unknown;
  mediaMime?: unknown;
  /** Legacy single-ciphertext path. */
  ciphertext?: unknown;
  /** Fan-out path: one opaque blob per target device. */
  fanout?: { recipient_device_id: string; ciphertext: string }[];
}): Buffer {
  const text = (value: unknown) => (typeof value === 'string' ? value : '');
  const parts = [
    input.conversationId,
    text(input.contentType) || 'text',
    text(input.mediaUrl),
    text(input.mediaMime),
    text(input.ciphertext),
    (input.fanout ?? [])
      .map((entry) => `${entry.recipient_device_id.toLowerCase()}:${entry.ciphertext}`)
      .sort()
      .join(','),
  ];
  // Length-prefixed, so a value containing the separator cannot be rearranged into a
  // different message with the same digest.
  return createHash('sha256')
    .update(parts.map((part) => `${part.length}:${part}`).join('|'))
    .digest();
}

export interface ExistingSend {
  id: string;
  created_at: string;
  fingerprint: Buffer | null;
  delivered_devices: number;
}

/**
 * Find the message this client id already produced, if any.
 *
 * Read inside the caller's transaction so it sees the same snapshot as the insert that
 * follows, and so a concurrent retry serialises against it rather than racing past.
 */
export async function findByClientId(
  execute: typeof Query,
  senderId: string,
  deviceId: string | null,
  clientMessageId: string
): Promise<ExistingSend | undefined> {
  const rows = await execute<ExistingSend>(
    `select m.id, m.created_at, m.payload_fingerprint as fingerprint,
            (select count(*)::int from message_ciphertexts mc where mc.message_id = m.id)
              as delivered_devices
       from messages m
      where m.sender_id = $1
        and coalesce(m.sender_device_id, '00000000-0000-0000-0000-000000000000'::uuid)
            = coalesce($2::uuid, '00000000-0000-0000-0000-000000000000'::uuid)
        and m.client_message_id = $3`,
    [senderId, deviceId, clientMessageId]
  );
  return rows[0];
}

/**
 * Is this retry the same message, or a different one reusing the key?
 *
 * A row written before 059 (or by a path that stored no fingerprint) has none. Treating that
 * as a mismatch would refuse legitimate retries of messages sent across the upgrade, so an
 * absent fingerprint is accepted as a match — the client id is still doing its job, and the
 * only thing lost is the ability to catch key reuse for those particular rows.
 */
export function samePayload(existing: ExistingSend, fingerprint: Buffer): boolean {
  return existing.fingerprint == null || existing.fingerprint.equals(fingerprint);
}

/** Postgres unique-violation, raised when two retries reach the insert at the same time. */
export const PG_UNIQUE_VIOLATION = '23505';
