// Messaging relay (Section 10 realtime flow). Server stores CIPHERTEXT ONLY, then publishes to the
// recipient's Redis channel; the WS instance holding the socket pushes it down. Offline -> DB -> pending fetch.
//
// Two send shapes (additive, back-compatible — see docs/FANOUT_PROTOCOL.md):
//   * legacy: a single `ciphertext` stored on the `messages` row, relayed per-USER (today's behaviour).
//   * fan-out: a `messages[]` bundle of one opaque ciphertext per TARGET DEVICE, stored in
//     `message_ciphertexts`. This closes the recipient-multi-device gap: each device (incl. the
//     sender's own linked devices) receives a blob it can actually decrypt with its own session.
import { Router } from 'express';
import { assertOpaque } from '@voiid/common-utils';
import { query, withTransaction } from '../db';
import { resolveActiveDevice, UUID_RE } from '../deviceAuthorization';
import {
  MAX_CLIENT_MESSAGE_ID, PG_UNIQUE_VIOLATION, findByClientId, payloadFingerprint, samePayload,
} from '../messageIdempotency';
import { enqueueOutbox, publishOutbox, type OutboxEntry } from '../messageOutbox';
import { publisher } from '../redis';
import { requireAuth } from '../auth';
import { announcementPostDeniedReason } from '../communityGuard';
import { b64, asyncHandler } from '../util';
import { blockedCounterpartForSend, hasBlocked } from '../blocking';
import { sendWakePush, PushMeta } from '../push';

const router = Router();

/** One reconnect's worth of acknowledgements. Bounded because it arrives from a client and
 *  becomes an array parameter; the clients already page their fetches. */
const ACK_MAX_BATCH = 500;

// Content-free wake push to a set of devices (Section 4.14): the Redis relay only reaches
// devices holding a live socket; a silent, data-only push nudges the rest to fetch pending +
// decrypt locally. Fire-and-forget — the HTTP response must NOT wait on push delivery.
/**
 * Content types that are PROTOCOL CONTROL, not chat: the user never sent them and must
 * never be notified about them. `location` carries map_key / map_off / live_* (see
 * docs/LOCATION.md P2) and is routed as an ordinary message purely so it rides the
 * Double Ratchet — the clients already suppress its bubble.
 *
 * Enabling Map visibility fans a map_key out to every person in the audience, so without
 * this each of them got a "New message" banner for a message that does not exist. The
 * push must still be SENT (the peer has to wake and fetch the key) — just silently.
 */
function isControlContentType(contentType?: string | null): boolean {
  return contentType === 'location';
}

/**
 * Content-free wake push to every device matching `whereSql`, MINUS anyone the sender has a
 * block with.
 *
 * BLOCKING IS FILTERED HERE, NOT AT THE CALL SITES. `sendWakePush` takes device tokens, so
 * by the time a target reaches it there is no user id left to check. Both call sites below
 * select devices — one by device id (fan-out), one by user id (legacy) — so the filter has
 * to sit in this one query, joined back through `devices.user_id`.
 *
 * WHY THIS MATTERS FOR GROUPS SPECIFICALLY. A 1:1 send to a blocked pair never gets this
 * far: blockGuardForSend stops it. A GROUP send deliberately does not stop — one blocked
 * pair must not silence a whole room — so the message is written and relayed, and without
 * this a blocked member's phone would still light up with "New message" from the person who
 * blocked them. That is the most visible thing blocking is supposed to prevent, and it was
 * the last place it leaked.
 *
 * `senderId` is nullable so a caller with no sender (there is none today, but the signature
 * should not force one) skips the filter rather than silently pushing to nobody.
 */
function scheduleWakePush(
  whereSql: string,
  params: unknown[],
  meta?: PushMeta,
  senderId?: string | null
): void {
  // $N of the block parameter, appended after whatever the caller already passed.
  const blockParam = `$${params.length + 1}`;
  const filter = senderId
    ? `and not exists (
           select 1 from user_blocks b
            where (b.blocker_user_id = devices.user_id and b.blocked_user_id = ${blockParam})
               or (b.blocked_user_id = devices.user_id and b.blocker_user_id = ${blockParam})
         )`
    : '';
  query<{ push_token: string; push_provider: string }>(
    `select push_token, push_provider from devices
       where ${whereSql} and revoked_at is null
         and push_token is not null and push_provider is not null
         ${filter}`,
    senderId ? [...params, senderId] : params
  )
    .then((targets) => {
      if (targets.length) void sendWakePush(targets, meta);
    })
    .catch((e) => console.warn('[push] wake lookup failed:', (e as Error).message));
}

// POST /messages/send
//   fan-out: { conversation_id, sender_device_id?, content_type?, media_url?, media_mime?,
//              messages: [{ recipient_device_id, ciphertext(b64) }, ...] }
//   legacy:  { conversation_id, ciphertext(b64), device_id?, content_type?, media_url?, media_mime? }
// ─────────────────────────────────────────────────────────────────────────────────
// WRITE AUTHORIZATION
//
// Being authenticated is not permission to write into a conversation. Until now
// POST /messages/send went straight from requireAuth + assertOpaque to
// `insert into messages`, so any authenticated user who learned or guessed a
// conversation_id could insert a row into it — and conversation ids travel: they appear
// in group rosters, in shared links, in any client's local state.
//
// That made the whole reachability model (020_reachability.sql) a gate on CREATING a
// conversation and not on writing to one, which is the half that matters. The PIN, the
// mutual-contact rule and the request flow all decide who may open a thread with you;
// none of them were being consulted when someone wrote to a thread.
//
// The check is membership, for the same reason the call path uses it: every path 020
// defines for reaching a person resolves to a conversation both parties belong to, so
// membership inherits the PIN gate rather than reimplementing it. Note to Self is
// unaffected — a self conversation has exactly one member, and it is you.
//
// Applied to BOTH send paths. The fan-out path and the legacy single-ciphertext path
// each reach `insert into messages` by their own route, and guarding only one leaves
// the other as a way in.
// ─────────────────────────────────────────────────────────────────────────────────
async function isConversationMember(conversationId: string, userId: string, execute = query): Promise<boolean> {
  if (!UUID_RE.test(conversationId)) return false;
  const rows = await execute<{ one: number }>(
    `select 1 as one from conversation_members
      where conversation_id = $1 and user_id = $2 and left_at is null
      limit 1 for share`,
    [conversationId, userId]
  );
  return rows.length > 0;
}

/**
 * Block enforcement for a send, shared by BOTH send paths.
 *
 * Returns a response body to reject with, or null to allow. Two different answers on
 * purpose:
 *
 *   * The BLOCKER messaging someone they blocked gets a plain 403. They know the block
 *     exists — they created it — so silently dropping their message would read as a bug,
 *     and the client can offer to unblock.
 *
 *   * The BLOCKED party gets a 200 that looks exactly like a successful send, and the
 *     message goes nowhere. They must not be able to tell being blocked from the other
 *     person being offline. A distinctive error here would turn this endpoint into a
 *     block-detector, which is the one thing blocking has to hide.
 *
 * Groups are never gated: one blocked pair must not silence a whole room. Delivery-time
 * filtering handles that case instead.
 */
async function blockGuardForSend(
  conversationId: string,
  senderId: string
): Promise<{ status: number; body: any } | null> {
  const counterpart = await blockedCounterpartForSend(conversationId, senderId);
  if (!counterpart) return null;

  if (await hasBlocked(senderId, counterpart)) {
    return {
      status: 403,
      body: { error: 'you have blocked this user', blocked_user_id: counterpart },
    };
  }
  // Silently accepted, deliberately never delivered.
  return { status: 200, body: { message_id: null, delivered_devices: 0 } };
}

router.post('/send', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const {
    conversation_id, ciphertext, content_type, media_url, media_mime,
    messages, sender_device_id, device_id: bodyDeviceId, client_message_id,
  } = req.body ?? {};

  // The client's stable id for this message, minted before transmission and reused by every
  // retry of it. Optional: clients that predate M01 send none and keep their old behaviour,
  // which is a duplicate on retry rather than a rejection.
  if (client_message_id != null &&
      (typeof client_message_id !== 'string' || !client_message_id ||
       client_message_id.length > MAX_CLIENT_MESSAGE_ID)) {
    return res.status(400).json({ error: 'client_message_id must be a short non-empty string' });
  }

  // Golden rule (Section 4.14): the server only ever relays opaque ciphertext — reject plaintext-ish payloads.
  try { assertOpaque(req.body ?? {}); } catch (e) {
    return res.status(400).json({ error: (e as Error).message });
  }

  const postCommit: (() => Promise<unknown> | void)[] = [];
  // Announcements owed by this message. Written inside the transaction, published straight
  // after it — see messageOutbox.ts for why both halves exist.
  let owed: { id: string; channel: string; payload: unknown }[] = [];
  const send = () => withTransaction<{ status: number; body: any }>(async (query) => {
    const device_id = await resolveActiveDevice(req, user_id,
      async (sql, params) => ({ rows: await query(sql, params) }),
      sender_device_id ?? bodyDeviceId, true);
    if (device_id === undefined) return { status: 403, body: { error: 'forbidden' } };

    /**
     * Has this exact send already been accepted?
     *
     * Checked BEFORE doing the work, so an ordinary retry costs one indexed lookup instead of
     * re-validating a whole fan-out. The insert below still carries the unique index, which is
     * what makes two SIMULTANEOUS retries safe — this probe is the fast path, not the guarantee.
     */
    const already = client_message_id
      ? await findByClientId(query, user_id, device_id, client_message_id)
      : undefined;
    if (already) {
      const fingerprint = payloadFingerprint({
        conversationId: String(conversation_id ?? ''), contentType: content_type,
        mediaUrl: media_url, mediaMime: media_mime, ciphertext,
        fanout: Array.isArray(messages) ? messages : undefined,
      });
      if (!samePayload(already, fingerprint)) {
        // SAME KEY, DIFFERENT BYTES. Refused rather than absorbed: silently storing nothing
        // and reporting success would be a worse and quieter failure than the duplicate this
        // mechanism prevents.
        //
        // But it is NOT necessarily an error, and the client needs to be able to tell. A
        // client mints one id per logical message and never reuses it, and it re-encrypts
        // when it retries — Olm advances its ratchet, so the ciphertext differs even though
        // the message does not. That legitimate retry lands here. So the conflict carries the
        // message the key already produced, which is what the client is actually asking for:
        // "did my send land?" A client that gets this marks the message sent against
        // `message_id`. A client that reuses ids for genuinely different content gets a
        // conflict instead of a silent swallow, which is the case worth being loud about.
        return { status: 409, body: {
          error: 'client_message_id already used for a different payload',
          code: 'idempotency_key_reuse',
          message_id: already.id,
          created_at: already.created_at,
          delivered_devices: already.delivered_devices,
        } };
      }
      return { status: 200, body: {
        message_id: already.id, created_at: already.created_at,
        delivered_devices: already.delivered_devices, duplicate: true,
      } };
    }

    // ── Fan-out path: one opaque ciphertext per target device ──────────────────
    // PRESENCE, not non-emptiness. A single-device NOTE TO SELF legitimately produces an
    // EMPTY bundle — encryptFanout returns [] by design, because there is genuinely no other
    // device to encrypt to. Gating on length sent that legitimate case down the legacy
    // single-ciphertext path, which then 400s for want of a top-level `ciphertext` field. Only
    // the text path short-circuits on an empty bundle, so media, reactions, replies, forwards,
    // delete-for-everyone and location all failed — and on iOS a 400 is not retryable, so the
    // user got a red failed bubble.
    //
    // The body below is already correct for an empty array: the metadata insert writes
    // ciphertext = null unconditionally, the per-device loop is a no-op, no Redis publish
    // fires, and the wake push is guarded by deviceIds.length. It returns delivered_devices: 0,
    // which is the honest answer.
    if (Array.isArray(messages)) {
      if (!conversation_id) {
        return { status: 400, body: { error: 'conversation_id required' } };
      }
      // See isConversationMember above. 403 without saying whether the conversation exists —
      // distinguishing "no such conversation" from "not your conversation" turns this endpoint
      // into an oracle for probing which conversation ids are real.
      if (!(await isConversationMember(conversation_id, user_id, query))) {
        return { status: 403, body: { error: 'not a member of this conversation' } };
      }
      // An ANNOUNCEMENT channel is readable by every member and writable only by the owner and
      // admins. Enforced here rather than only in the client, because a client-side restriction
      // is not a restriction — the guard was written but nothing called it, so until now any
      // member could post to an announcement channel with curl.
      const announceDenied = await announcementPostDeniedReason(conversation_id, user_id);
      if (announceDenied) return { status: 403, body: { error: announceDenied } };
      // Blocking (043). See blockGuardForSend: the blocker is told, the blocked is not.
      const fanBlocked = await blockGuardForSend(conversation_id, user_id);
      if (fanBlocked) return fanBlocked;
      for (const entry of messages) {
        if (typeof entry?.recipient_device_id !== 'string' || !UUID_RE.test(entry.recipient_device_id) || typeof entry?.ciphertext !== 'string' || !entry.ciphertext) {
          return { status: 400, body: { error: 'each messages[] entry requires recipient_device_id and ciphertext' } };
        }
        // Per-entry golden-rule check: no plaintext-ish fields alongside the ciphertext.
        try { assertOpaque(entry); } catch (e) {
          return { status: 400, body: { error: (e as Error).message } };
        }
      }
      const requestedIds = [...new Set<string>(messages.map((entry: any) => entry.recipient_device_id.toLowerCase()))].sort();
      if (requestedIds.length) {
        const targets = await query<{ id: string }>(
          `select d.id from devices d
             join conversation_members cm on cm.user_id = d.user_id
            where d.id = any($1::uuid[]) and d.revoked_at is null
              and cm.conversation_id = $2 and cm.left_at is null
            order by d.id for share of d, cm`,
          [requestedIds, conversation_id],
        );
        if (targets.length !== requestedIds.length) return { status: 403, body: { error: 'forbidden' } };
      }

      // ONE canonical metadata row; ciphertext is NULL (the per-device blobs live below).
      //
      // The unique index on (sender, device, client_message_id) is what makes two retries
      // arriving at once safe: one wins the insert, the other raises and is answered with the
      // winner below. The probe above only saves the losing retry from doing the work twice.
      let message: { id: string; created_at: string };
      try {
        const rows = await query<{ id: string; created_at: string }>(
          `insert into messages (conversation_id, sender_id, sender_device_id, ciphertext,
                                 content_type, media_url, media_mime,
                                 client_message_id, payload_fingerprint)
             values ($1, $2, $3, null, coalesce($4,'text'), $5, $6, $7, $8)
             returning id, created_at`,
          [conversation_id, user_id, device_id, content_type, media_url, media_mime,
           client_message_id ?? null,
           client_message_id
             ? payloadFingerprint({ conversationId: conversation_id, contentType: content_type,
                                    mediaUrl: media_url, mediaMime: media_mime, fanout: messages })
             : null]
        );
        message = rows[0];
      } catch (e) {
        if ((e as { code?: string }).code !== PG_UNIQUE_VIOLATION || !client_message_id) throw e;
        // Lost the race to a concurrent retry of the same send. The transaction is now
        // aborted, so the winner cannot be read here — rethrow a marker the caller retries
        // outside this transaction.
        throw Object.assign(new Error('idempotent retry raced'), { voiidIdempotentRace: true });
      }

      // One opaque ciphertext per target device, inserted in ONE statement.
      //
      // This was a loop doing one round trip per device. A 1000-member group where everyone
      // has two devices is 2000 sequential inserts for a single message — the send latency
      // becomes 2000 × RTT, and it is the dominant cost of the whole path at that size.
      // unnest sends the same rows as three arrays and lets Postgres do the expansion.
      //
      // `do nothing` still guards a client that repeats a device in its bundle (the PK is
      // (message_id, recipient_device_id)).
      const seen = new Set<string>();
      const targetIds: string[] = [];
      const blobs: Buffer[] = [];
      for (const entry of messages) {
        // A Set rather than array.includes(): the old membership test was O(n) per entry, so
        // building the list was itself quadratic — 2 million comparisons at the size above,
        // before a single row was written.
        if (seen.has(entry.recipient_device_id.toLowerCase())) continue;
        seen.add(entry.recipient_device_id.toLowerCase());
        // b64 returns null for a null input. The per-entry validation above already rejects
        // a missing ciphertext, so this cannot be null in practice — but skipping rather than
        // pushing null keeps a future validation change from silently writing an empty row.
        const blob = b64(entry.ciphertext);
        if (!blob) continue;
        targetIds.push(entry.recipient_device_id.toLowerCase());
        blobs.push(blob);
      }
      const deviceIds = targetIds;

      if (targetIds.length) {
        await query(
          `insert into message_ciphertexts (message_id, recipient_device_id, ciphertext)
           select $1, t.device_id, t.ciphertext
             from unnest($2::uuid[], $3::bytea[]) as t(device_id, ciphertext)
           on conflict (message_id, recipient_device_id) do nothing`,
          [message.id, targetIds, blobs]
        );
      }

      // Relay: signal-and-fetch on the EXISTING per-user channel (see note below). Resolve each
      // target device to its owning user and wake that user's live sockets once; every connected
      // device then calls GET /messages/pending to pull ITS OWN ciphertext. We never place a
      // device's ciphertext on the shared user channel — only a routing signal (message_id +
      // the device ids targeted for that user, which are non-secret metadata).
      //
      // Blocking (043): a device whose owner has a block with the sender is dropped here, so
      // it is neither relayed to nor (via the same exclusion in scheduleWakePush) pushed to.
      //
      // The RECIPIENT LIST COMES FROM THE CLIENT — it is whoever the sender's app chose to
      // encrypt to — so this is the server's own check rather than trust in a well-behaved
      // client. A modified client that fans out to someone who blocked them still gets its
      // ciphertext stored (there is nothing secret in that; the row is opaque and the reader
      // must already hold the key), but no device is ever told it is there.
      const owners = await query<{ id: string; user_id: string }>(
        `select id, user_id from devices
          where id = any($1::uuid[]) and revoked_at is null
            and not exists (
              select 1 from user_blocks b
               where (b.blocker_user_id = devices.user_id and b.blocked_user_id = $2)
                  or (b.blocked_user_id = devices.user_id and b.blocker_user_id = $2)
            )`,
        [deviceIds, user_id]
      );
      const byUser = new Map<string, string[]>();
      for (const o of owners) {
        const list = byUser.get(o.user_id) ?? [];
        list.push(o.id);
        byUser.set(o.user_id, list);
      }
      // The announcement is written down before it is attempted. A publish that fails after
      // this transaction commits leaves a row the sweep will keep, instead of a stored message
      // nobody was ever told about.
      const entries: OutboxEntry[] = [...byUser].map(([uid, devIds]) => ({
        channel: `channel:user:${uid}`,
        payload: {
          type: 'message',
          message_id: message.id,
          conversation_id,
          recipient_device_ids: devIds,
        },
      }));
      const ids = await enqueueOutbox(query, message.id, entries);
      owed = entries.map((entry, i) => ({ id: ids[i], ...entry }));

      // Wake offline/backgrounded TARGET devices (content-free push + non-secret routing).
      if (deviceIds.length) {
        postCommit.push(() => scheduleWakePush('id = any($1::uuid[])', [deviceIds], {
          message_id: message.id,
          conversation_id,
          silent: isControlContentType(content_type),
        }, user_id));
      }

      return { status: 200, body: { message_id: message.id, delivered_devices: deviceIds.length } };
    }

    // ── Legacy path: single ciphertext stored on the message row, relayed per-user ──
    if (!conversation_id || !ciphertext) {
      return { status: 400, body: { error: 'conversation_id and ciphertext required' } };
    }
    if (!(await isConversationMember(conversation_id, user_id, query))) {
      return { status: 403, body: { error: 'not a member of this conversation' } };
    }
    // Same announcement-channel restriction as the fan-out path above. Guarding only one path
    // leaves the other as a way in.
    const legacyAnnounceDenied = await announcementPostDeniedReason(conversation_id, user_id);
    if (legacyAnnounceDenied) return { status: 403, body: { error: legacyAnnounceDenied } };
    // Blocking (043) — same guard as the fan-out path, for the same reason as the line above.
    const legacyBlocked = await blockGuardForSend(conversation_id, user_id);
    if (legacyBlocked) return legacyBlocked;
    let message: { id: string; created_at: string };
    try {
      const rows = await query<{ id: string; created_at: string }>(
        `insert into messages (conversation_id, sender_id, sender_device_id, ciphertext,
                               content_type, media_url, media_mime,
                               client_message_id, payload_fingerprint)
           values ($1, $2, $3, $4, coalesce($5,'text'), $6, $7, $8, $9)
           returning id, created_at`,
        [conversation_id, user_id, device_id, b64(ciphertext), content_type, media_url, media_mime,
         client_message_id ?? null,
         client_message_id
           ? payloadFingerprint({ conversationId: conversation_id, contentType: content_type,
                                  mediaUrl: media_url, mediaMime: media_mime, ciphertext })
           : null]
      );
      message = rows[0];
    } catch (e) {
      if ((e as { code?: string }).code !== PG_UNIQUE_VIOLATION || !client_message_id) throw e;
      throw Object.assign(new Error('idempotent retry raced'), { voiidIdempotentRace: true });
    }

    // Route to each active member's user channel; WS instance with the live socket delivers it.
    //
    // Blocking (043) is filtered in the SQL rather than after the fact, so the same list
    // drives both the live relay below and the wake push further down. A group send is
    // deliberately never rejected for one blocked pair — that would let one member silence a
    // room — so suppression happens per RECIPIENT here instead.
    const members = await query<{ user_id: string }>(
      `select cm.user_id from conversation_members cm
         where cm.conversation_id = $1 and cm.left_at is null and cm.user_id <> $2
           and not exists (
             select 1 from user_blocks b
              where (b.blocker_user_id = cm.user_id and b.blocked_user_id = $2)
                 or (b.blocked_user_id = cm.user_id and b.blocker_user_id = $2)
           )`,
      [conversation_id, user_id]
    );
    const legacyEntries: OutboxEntry[] = members.map((m) => ({
      channel: `channel:user:${m.user_id}`,
      payload: { type: 'message', message_id: message.id, conversation_id },
    }));
    const legacyIds = await enqueueOutbox(query, message.id, legacyEntries);
    owed = legacyEntries.map((entry, i) => ({ id: legacyIds[i], ...entry }));

    // Wake offline/backgrounded recipient devices with a CONTENT-FREE push. The Redis
    // relay above only reaches devices holding a live socket; a silent, data-only "wake"
    // push nudges the rest to fetch pending messages + decrypt locally (no ciphertext or
    // content ever leaves in the push — Section 4.14).
    if (members.length) {
      postCommit.push(() => scheduleWakePush('user_id = any($1::uuid[])', [members.map((m) => m.user_id)], {
        message_id: message.id,
        conversation_id,
        silent: isControlContentType(content_type),
      }, user_id));
    }

    return { status: 200, body: { message_id: message.id, created_at: message.created_at } };
  });
  let result: { status: number; body: any };
  try {
    result = await send();
  } catch (e) {
    // Two retries of the same send reached the insert together. The loser's transaction is
    // aborted, so the winner could not be read from inside it; read it now that the winner has
    // committed and answer with the same message, which is what the client is asking for.
    if (!(e as { voiidIdempotentRace?: boolean }).voiidIdempotentRace || !client_message_id) throw e;
    const device_id = await resolveActiveDevice(req, user_id,
      async (sql, params) => ({ rows: await query(sql, params) }), sender_device_id ?? bodyDeviceId);
    const winner = device_id === undefined
      ? undefined
      : await findByClientId(query, user_id, device_id, client_message_id);
    if (!winner) throw e;
    result = { status: 200, body: {
      message_id: winner.id, created_at: winner.created_at,
      delivered_devices: winner.delivered_devices, duplicate: true,
    } };
  }

  // AFTER COMMIT, and never fatal: the message is stored and its announcements are durable, so
  // a Redis outage here must not turn a successful send into a 500 the client would retry.
  await publishOutbox(query, owed);
  for (const notify of postCommit) await notify();
  res.status(result.status).json(result.body);
}));

// GET /messages/conversation/:id?before=&limit=&device_id= — paginated history (ciphertext; client decrypts)
router.get('/conversation/:id', requireAuth, asyncHandler(async (req, res) => {
  const result = await withTransaction<{ status: number; body: any }>(async (query) => {
    const { user_id } = (req as any).auth;
    // MEMBERSHIP, before anything else reads a row. This endpoint used to filter only
    // on conversation_id, so ANY authenticated caller holding a conversation UUID —
    // and ids travel: they appear in group rosters and shared links — could read the
    // whole timeline: senders, timestamps, content types, media references, receipt
    // aggregates, and legacy-path ciphertext. POST /send has required membership since
    // it shipped (see isConversationMember above); the read path simply never got the
    // same guard. 403 without saying whether the conversation exists, mirroring :187.
    if (!(await isConversationMember(req.params.id, user_id, query))) {
      return { status: 403, body: { error: 'not found' } };
    }
    const limit = Math.min(Number(req.query.limit) || 50, 100);
    const before = req.query.before as string | undefined;
    const deviceId = await resolveActiveDevice(req, user_id,
      async (sql, params) => ({ rows: await query(sql, params) }), req.query.device_id, true);
    if (deviceId === undefined) return { status: 403, body: { error: 'forbidden' } };
    // Per message, return THIS device's ciphertext (fan-out) or the legacy row ciphertext.
    // The LEFT JOIN is keyed to the caller's device so no other device's blob is ever returned.
    const rows = await query<{ id: string }>(
      `select m.id, m.sender_id, m.sender_device_id,
              translate(encode(coalesce(mc.ciphertext, m.ciphertext),'base64'), E'\n', '') as ciphertext,
              m.content_type, m.media_url, m.media_mime, m.created_at,
              -- Receipt state for the SENDER's ticks, so they advance Sent→Delivered→Seen on
              -- poll even when the live WS receipt push was missed (mirrors Signal's receipt
              -- sync). Two rules this MUST get right, both of which it used to get wrong:
              --
              --  1. ONLY OTHER PEOPLE'S RECEIPTS COUNT. The join used to be unfiltered, so a
              --     receipt written by the sender's OWN linked device (fan-out marks inbound
              --     copies delivered) satisfied bool_or and reported Delivered/Seen for a
              --     message no recipient had touched. Worst in Note to Self, where every
              --     receipt is your own. iOS happens to filter !isMine client-side, but the
              --     server must not depend on a client behaving — Android or a replayed
              --     request would still forge the tick.
              --
              --  2. 'read' MEANS EVERY ACTIVE RECIPIENT READ IT. bool_or turned the tick blue
              --     as soon as ONE group member read, which is not what a blue tick promises
              --     and not what WhatsApp/Signal do. We now compare the count of distinct
              --     recipients who reached 'read' against the number of active members other
              --     than the sender. 'delivered' stays ANY-recipient: it answers "did this
              --     leave the building", which is true as soon as one device has it.
              --
              -- Direct chats fall out of the same expression — one other member means
              -- all-read and any-read coincide.
              case
                when count(distinct r.user_id) filter (where r.status = 'read') > 0
                 and count(distinct r.user_id) filter (where r.status = 'read')
                     >= (select count(*) from conversation_members cm
                          where cm.conversation_id = m.conversation_id
                            and cm.left_at is null
                            and cm.user_id <> m.sender_id)
                  then 'read'
                when count(distinct r.user_id) filter (where r.status in ('delivered','read')) > 0
                  then 'delivered'
                else null
              end as receipt_status
         from messages m
         left join message_ciphertexts mc on mc.message_id = m.id and mc.recipient_device_id = $3::uuid
         -- Sender's own receipts excluded here rather than in the aggregate, so they never
         -- reach any of the counts above.
         left join message_read_receipts r
                on r.message_id = m.id and r.user_id <> m.sender_id
         where m.conversation_id = $1 ${before ? 'and m.created_at < $4' : ''}
         group by m.id, m.conversation_id, m.sender_id, mc.ciphertext
         order by m.created_at desc limit $2`,
      before ? [req.params.id, limit, deviceId, before] : [req.params.id, limit, deviceId]
    );

    // NOTHING IS MARKED DELIVERED HERE (M02). This used to stamp `delivered_at` for every
    // row it served, so scrolling back through a conversation silently acknowledged messages
    // the device had not stored — and a history fetch that never arrived acknowledged them
    // anyway. Delivery is reported by POST /messages/ack, by the device, after it has the
    // ciphertext on its own disk.
    return { status: 200, body: { messages: rows } };
  });
  res.status(result.status).json(result.body);
}));

// GET /messages/pending/:user_id?device_id= — offline fetch on reconnect.
// Returns ONLY the caller device's ciphertext for fan-out messages, plus legacy pending
// (single-ciphertext) rows for the user's conversations. Marks fan-out rows delivered.
router.get('/pending/:user_id', requireAuth, asyncHandler(async (req, res) => {
  const result = await withTransaction<{ status: number; body: any }>(async (query) => {
    // IDENTITY, before anything reads or mutates a row. The path parameter used to flow
    // straight into both queries below with no comparison to the authenticated caller,
    // so any signed-in user could harvest another user's undelivered queue — and the
    // legacy branch marks nothing delivered, so the harvest was repeatable forever.
    const callerId: string = (req as any).auth.user_id;
    if (req.params.user_id !== callerId) {
      return { status: 403, body: { error: 'forbidden' } };
    }
    const deviceId = await resolveActiveDevice(req, callerId,
      async (sql, params) => ({ rows: await query(sql, params) }), req.query.device_id, true);
    if (deviceId === undefined) return { status: 403, body: { error: 'forbidden' } };

    // Keep active membership stable until this fetch's delivery mutations commit.
    await query(`select conversation_id from conversation_members
      where user_id = $1 and left_at is null order by conversation_id for share`, [callerId]);

    // A READ, not an update (M02). This was an `update ... returning`, so the act of
    // serving the ciphertext marked it delivered and the transaction committed before the
    // response left the process. A dropped socket, a killed app or a failed disk write then
    // lost the message permanently: the next fetch skipped it and nothing anywhere knew.
    // The device now acknowledges what it has actually stored, via POST /messages/ack.
    const perDevice = deviceId
      ? await query(
          `select m.id, m.conversation_id, m.sender_id, m.sender_device_id,
                  translate(encode(mc.ciphertext,'base64'), E'\n', '') as ciphertext,
                  m.content_type, m.media_url, m.media_mime, m.created_at
             from message_ciphertexts mc
             join messages m on mc.message_id = m.id
             join devices d on d.id = mc.recipient_device_id
             join conversation_members cm
               on cm.conversation_id = m.conversation_id and cm.user_id = $2::uuid
            where d.id = $1::uuid and d.user_id = $2::uuid and d.revoked_at is null
              and cm.left_at is null
              and not exists (select 1 from user_blocks b
                where (b.blocker_user_id = m.sender_id and b.blocked_user_id = $2)
                   or (b.blocked_user_id = m.sender_id and b.blocker_user_id = $2))
              and mc.delivered_at is null`,
          [deviceId, req.params.user_id]
        )
      : [];

    // Legacy: single-ciphertext rows still living on the message. `m.ciphertext is not null`
    // excludes fan-out rows (whose canonical ciphertext is NULL) so they aren't leaked here.
    const legacy = await query(
      `select m.id, m.conversation_id, m.sender_id, m.sender_device_id,
              translate(encode(m.ciphertext,'base64'), E'\n', '') as ciphertext,
              m.content_type, m.media_url, m.media_mime, m.created_at
         from messages m
         join conversation_members cm on cm.conversation_id = m.conversation_id
         where cm.user_id = $1 and cm.left_at is null
           and m.is_pending = true and m.ciphertext is not null
           and not exists (select 1 from user_blocks b
             where (b.blocker_user_id = m.sender_id and b.blocked_user_id = $1)
                or (b.blocked_user_id = m.sender_id and b.blocker_user_id = $1))
           -- What THIS device has already acknowledged storing (M02). The old test was a
           -- READ receipt, which is a different fact — and is_pending above is one shared
           -- bit for every recipient, so one device clearing it emptied every queue.
           and not exists (
             select 1 from message_deliveries dl
              where dl.message_id = m.id and dl.user_id = $1
                and coalesce(dl.device_id, '00000000-0000-0000-0000-000000000000'::uuid)
                    = coalesce($2::uuid, '00000000-0000-0000-0000-000000000000'::uuid)
           )
         order by m.created_at asc`,
      [req.params.user_id, deviceId]
    );

    const merged = [...perDevice, ...legacy].sort(
      (a: any, b: any) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime()
    );
    return { status: 200, body: { messages: merged } };
  });
  res.status(result.status).json(result.body);
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /messages/ack  { device_id?, message_ids: [uuid, ...] }
//
// THE OTHER HALF OF DELIVERY (M02). Fetching used to mark a message delivered, which meant
// the server was asserting something it could not know: that bytes it had written to a socket
// reached a device AND were written to that device's disk. Everything between those points —
// a dropped connection, an app killed on the walk to the platform, a failed write — silently
// destroyed the message, because the next fetch skipped it and nothing raised an error.
//
// A device sends this only after the ciphertext is durably stored. Until then, every fetch
// keeps returning it. That is the correct trade: a duplicate the client dedupes by id costs
// nothing, and a lost message cannot be recovered by anyone.
//
// IDEMPOTENT, because it is retried. `delivered_at is null` and `on conflict do nothing` mean
// a replayed batch is a no-op rather than a moved timestamp.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/ack', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { message_ids, device_id: bodyDeviceId } = req.body ?? {};

  // The whole batch is validated before anything is written: a partly-applied
  // acknowledgement would leave the client believing it had settled messages it had not.
  if (!Array.isArray(message_ids) || message_ids.length === 0 || message_ids.length > ACK_MAX_BATCH) {
    return res.status(400).json({ error: `message_ids must be 1..${ACK_MAX_BATCH} ids` });
  }
  if (!message_ids.every((id: unknown) => typeof id === 'string' && UUID_RE.test(id))) {
    return res.status(400).json({ error: 'message_ids must all be uuids' });
  }
  const ids = [...new Set<string>(message_ids.map((id: string) => id.toLowerCase()))];

  // A body that names a DIFFERENT device than the token is refused rather than quietly
  // resolved to the token's. The signed claim would win either way, so nothing unsafe could
  // happen — but the caller would be told "acknowledged" for a device it did not name, and a
  // client that believes it settled its tablet's queue from its phone will stop retrying.
  const claimedDevice = (req as any).auth?.device_id;
  if (typeof bodyDeviceId === 'string' && typeof claimedDevice === 'string' &&
      bodyDeviceId.toLowerCase() !== claimedDevice.toLowerCase()) {
    return res.status(403).json({ error: 'a device can only acknowledge its own messages' });
  }

  const result = await withTransaction<{ status: number; body: any }>(async (query) => {
    // The acknowledging device is resolved the same way every other write path resolves it:
    // a signed claim beats the body, and either way it must be a live device this account
    // owns. Acknowledging on behalf of another device would let one device empty another
    // device's queue — the shared-bit bug, re-created through the front door.
    const deviceId = await resolveActiveDevice(req, user_id,
      async (sql, params) => ({ rows: await query(sql, params) }), bodyDeviceId, true);
    if (deviceId === undefined) return { status: 403, body: { error: 'forbidden' } };

    // Fan-out: this device's own envelope, and only if it is still owed.
    const fanout = deviceId
      ? await query<{ message_id: string }>(
          `update message_ciphertexts mc set delivered_at = now()
             from devices d
            where mc.recipient_device_id = d.id
              and d.id = $1::uuid and d.user_id = $2::uuid and d.revoked_at is null
              and mc.message_id = any($3::uuid[])
              and mc.delivered_at is null
            returning mc.message_id`,
          [deviceId, user_id, ids]
        )
      : [];

    // Legacy: one shared ciphertext, so delivery is recorded per (message, user, device).
    // Membership is checked in the statement — an id the caller was never sent simply
    // matches nothing rather than being reported as an error, because a client replaying a
    // batch after being removed from a group is ordinary, not hostile.
    const legacy = await query<{ message_id: string }>(
      `insert into message_deliveries (message_id, user_id, device_id)
       select m.id, $2::uuid, $1::uuid
         from messages m
         join conversation_members cm
           on cm.conversation_id = m.conversation_id and cm.user_id = $2::uuid and cm.left_at is null
        where m.id = any($3::uuid[]) and m.ciphertext is not null
       on conflict do nothing
       returning message_id`,
      [deviceId, user_id, ids]
    );

    return { status: 200, body: {
      acknowledged: new Set([...fanout, ...legacy].map((r) => r.message_id)).size,
    } };
  });
  res.status(result.status).json(result.body);
}));

export default router;
