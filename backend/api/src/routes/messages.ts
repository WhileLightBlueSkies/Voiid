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
import { query } from '../db';
import { publisher } from '../redis';
import { requireAuth } from '../auth';
import { b64, asyncHandler } from '../util';
import { sendWakePush, PushMeta } from '../push';

const router = Router();

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

function scheduleWakePush(whereSql: string, params: unknown[], meta?: PushMeta): void {
  query<{ push_token: string; push_provider: string }>(
    `select push_token, push_provider from devices
       where ${whereSql} and revoked_at is null
         and push_token is not null and push_provider is not null`,
    params
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
router.post('/send', requireAuth, asyncHandler(async (req, res) => {
  const { user_id, device_id: authDeviceId } = (req as any).auth;
  const {
    conversation_id, ciphertext, content_type, media_url, media_mime,
    messages, sender_device_id, device_id: bodyDeviceId,
  } = req.body ?? {};

  // Golden rule (Section 4.14): the server only ever relays opaque ciphertext — reject plaintext-ish payloads.
  try { assertOpaque(req.body ?? {}); } catch (e) {
    return res.status(400).json({ error: (e as Error).message });
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
      return res.status(400).json({ error: 'conversation_id required' });
    }
    for (const entry of messages) {
      if (!entry?.recipient_device_id || !entry?.ciphertext) {
        return res.status(400).json({ error: 'each messages[] entry requires recipient_device_id and ciphertext' });
      }
      // Per-entry golden-rule check: no plaintext-ish fields alongside the ciphertext.
      try { assertOpaque(entry); } catch (e) {
        return res.status(400).json({ error: (e as Error).message });
      }
    }
    // Which of OUR devices encrypted this — so a multi-device recipient resolves the
    // correct sender identity key on acceptSession (else decrypt fails).
    const device_id = sender_device_id ?? bodyDeviceId ?? authDeviceId ?? null;

    // ONE canonical metadata row; ciphertext is NULL (the per-device blobs live below).
    const rows = await query<{ id: string; created_at: string }>(
      `insert into messages (conversation_id, sender_id, sender_device_id, ciphertext, content_type, media_url, media_mime)
         values ($1, $2, $3, null, coalesce($4,'text'), $5, $6)
         returning id, created_at`,
      [conversation_id, user_id, device_id, content_type, media_url, media_mime]
    );
    const message = rows[0];

    // One opaque ciphertext per target device. `do nothing` guards a client that
    // repeats a device in the bundle (the PK is (message_id, recipient_device_id)).
    const deviceIds: string[] = [];
    for (const entry of messages) {
      await query(
        `insert into message_ciphertexts (message_id, recipient_device_id, ciphertext)
           values ($1, $2, $3)
           on conflict (message_id, recipient_device_id) do nothing`,
        [message.id, entry.recipient_device_id, b64(entry.ciphertext)]
      );
      if (!deviceIds.includes(entry.recipient_device_id)) deviceIds.push(entry.recipient_device_id);
    }

    // Relay: signal-and-fetch on the EXISTING per-user channel (see note below). Resolve each
    // target device to its owning user and wake that user's live sockets once; every connected
    // device then calls GET /messages/pending to pull ITS OWN ciphertext. We never place a
    // device's ciphertext on the shared user channel — only a routing signal (message_id +
    // the device ids targeted for that user, which are non-secret metadata).
    const owners = await query<{ id: string; user_id: string }>(
      `select id, user_id from devices where id = any($1::uuid[]) and revoked_at is null`,
      [deviceIds]
    );
    const byUser = new Map<string, string[]>();
    for (const o of owners) {
      const list = byUser.get(o.user_id) ?? [];
      list.push(o.id);
      byUser.set(o.user_id, list);
    }
    for (const [uid, devIds] of byUser) {
      await publisher.publish(`channel:user:${uid}`, JSON.stringify({
        type: 'message',
        message_id: message.id,
        conversation_id,
        recipient_device_ids: devIds,
      }));
    }

    // Wake offline/backgrounded TARGET devices (content-free push + non-secret routing).
    if (deviceIds.length) {
      scheduleWakePush('id = any($1::uuid[])', [deviceIds], {
        message_id: message.id,
        conversation_id,
        silent: isControlContentType(content_type),
      });
    }

    return res.json({ message_id: message.id, delivered_devices: deviceIds.length });
  }

  // ── Legacy path: single ciphertext stored on the message row, relayed per-user ──
  if (!conversation_id || !ciphertext) {
    return res.status(400).json({ error: 'conversation_id and ciphertext required' });
  }
  // Which of OUR devices encrypted this — so a multi-device recipient resolves the
  // correct sender identity key on acceptSession (else decrypt fails). The JWT may
  // not carry a device id, so the client sends it in the body.
  const device_id = bodyDeviceId ?? authDeviceId ?? null;

  const rows = await query<{ id: string; created_at: string }>(
    `insert into messages (conversation_id, sender_id, sender_device_id, ciphertext, content_type, media_url, media_mime)
       values ($1, $2, $3, $4, coalesce($5,'text'), $6, $7)
       returning id, created_at`,
    [conversation_id, user_id, device_id, b64(ciphertext), content_type, media_url, media_mime]
  );
  const message = rows[0];

  // Route to each active member's user channel; WS instance with the live socket delivers it.
  const members = await query<{ user_id: string }>(
    `select user_id from conversation_members
       where conversation_id = $1 and left_at is null and user_id <> $2`,
    [conversation_id, user_id]
  );
  for (const m of members) {
    await publisher.publish(`channel:user:${m.user_id}`, JSON.stringify({
      type: 'message',
      message_id: message.id,
      conversation_id,
    }));
  }

  // Wake offline/backgrounded recipient devices with a CONTENT-FREE push. The Redis
  // relay above only reaches devices holding a live socket; a silent, data-only "wake"
  // push nudges the rest to fetch pending messages + decrypt locally (no ciphertext or
  // content ever leaves in the push — Section 4.14).
  if (members.length) {
    scheduleWakePush('user_id = any($1::uuid[])', [members.map((m) => m.user_id)], {
      message_id: message.id,
      conversation_id,
      silent: isControlContentType(content_type),
    });
  }

  res.json({ message_id: message.id, created_at: message.created_at });
}));

// Resolve the caller's device id: JWT claim first, else `?device_id=` (matches prekeys.ts).
function callerDeviceId(req: any): string | null {
  const fromAuth = req.auth?.device_id;
  if (typeof fromAuth === 'string' && fromAuth) return fromAuth;
  const fromQuery = req.query?.device_id;
  return typeof fromQuery === 'string' && fromQuery ? fromQuery : null;
}

// GET /messages/conversation/:id?before=&limit=&device_id= — paginated history (ciphertext; client decrypts)
router.get('/conversation/:id', requireAuth, asyncHandler(async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 50, 100);
  const before = req.query.before as string | undefined;
  const deviceId = callerDeviceId(req);
  // Per message, return THIS device's ciphertext (fan-out) or the legacy row ciphertext.
  // The LEFT JOIN is keyed to the caller's device so no other device's blob is ever returned.
  const rows = await query<{ id: string }>(
    `select m.id, m.sender_id, m.sender_device_id,
            translate(encode(coalesce(mc.ciphertext, m.ciphertext),'base64'), E'\n', '') as ciphertext,
            m.content_type, m.media_url, m.media_mime, m.created_at,
            -- Highest receipt state any recipient has reached for this message, so the
            -- SENDER can advance Sent→Delivered→Seen on poll even if the live WS receipt
            -- push was missed (delivery-independent status, mirrors Signal's receipt sync).
            case when bool_or(r.status = 'read') then 'read'
                 when bool_or(r.status = 'delivered') then 'delivered'
                 else null end as receipt_status
       from messages m
       left join message_ciphertexts mc on mc.message_id = m.id and mc.recipient_device_id = $3::uuid
       left join message_read_receipts r on r.message_id = m.id
       where m.conversation_id = $1 ${before ? 'and m.created_at < $4' : ''}
       group by m.id, mc.ciphertext
       order by m.created_at desc limit $2`,
    before ? [req.params.id, limit, deviceId, before] : [req.params.id, limit, deviceId]
  );

  // Mark this device's fan-out ciphertexts delivered as we serve them.
  if (deviceId && rows.length) {
    await query(
      `update message_ciphertexts set delivered_at = now()
         where recipient_device_id = $1::uuid and delivered_at is null
           and message_id = any($2::uuid[])`,
      [deviceId, rows.map((m) => m.id)]
    );
  }
  res.json({ messages: rows });
}));

// GET /messages/pending/:user_id?device_id= — offline fetch on reconnect.
// Returns ONLY the caller device's ciphertext for fan-out messages, plus legacy pending
// (single-ciphertext) rows for the user's conversations. Marks fan-out rows delivered.
router.get('/pending/:user_id', requireAuth, asyncHandler(async (req, res) => {
  const deviceId = callerDeviceId(req);

  // Fan-out: the caller device's undelivered blobs. UPDATE…RETURNING both marks
  // delivered_at and returns exactly the rows that were still pending — atomic, no
  // double-delivery, no race. Scoped to a device that belongs to :user_id.
  const perDevice = deviceId
    ? await query(
        `update message_ciphertexts mc set delivered_at = now()
           from messages m, devices d
          where mc.message_id = m.id
            and mc.recipient_device_id = d.id
            and d.id = $1::uuid and d.user_id = $2::uuid
            and mc.delivered_at is null
          returning m.id, m.conversation_id, m.sender_id, m.sender_device_id,
                    translate(encode(mc.ciphertext,'base64'), E'\n', '') as ciphertext,
                    m.content_type, m.media_url, m.media_mime, m.created_at`,
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
       order by m.created_at asc`,
    [req.params.user_id]
  );

  const merged = [...perDevice, ...legacy].sort(
    (a: any, b: any) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime()
  );
  res.json({ messages: merged });
}));

export default router;
