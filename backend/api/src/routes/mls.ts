// MLS (RFC 9420) group-messaging plumbing (Phase 3). The server only stores/relays
// OPAQUE MLS bytes — public KeyPackages, and Welcome/Commit control messages. Group
// application ciphertext rides the existing /messages relay. No group keys here.
//
// ── WHY EVERY PATH BELOW IS ONE STATEMENT, NOT A LOOP (repair item 3.20) ─────────
//
// MLS fan-out is O(members) per membership change: adding one person to a 512-member channel
// produces one Welcome plus a Commit for every existing member, and mls_group_events takes
// ONE ROW PER RECIPIENT. Written as a per-recipient `await` loop — which is what this file
// did — that is 512 sequential round trips holding a connection from the pool, plus 512
// separate Redis publishes, for a single tap on a Join button. Communities make that the
// common case rather than the rare one (030_communities.sql caps a channel at 512 members
// precisely because of this file), so each loop here is now a single multi-row statement and
// one pipelined Redis batch.
//
// The row COUNT is unchanged — the protocol needs a row per recipient — but the number of
// round trips is not, and that was the part that melted.
import { Router } from 'express';
import { query } from '../db';
import { publisher } from '../redis';
import { requireAuth } from '../auth';
import { b64, asyncHandler } from '../util';

const router = Router();

// Bounds on a single request, so one client cannot hand us an unbounded parameter list.
// Postgres accepts at most 65535 bind parameters per statement; both ceilings sit far below
// that, and MAX_EVENTS_PER_REQUEST is deliberately the same 1024 as the hard member ceiling
// in 030_communities.sql — a Commit fanned to the largest channel the schema permits is
// exactly one legitimate request, and anything past it is a bug or an attack.
const MAX_KEY_PACKAGES_PER_REQUEST = 200;
const MAX_EVENTS_PER_REQUEST = 1024;

// POST /mls/keypackages  { device_id, key_packages: [base64, ...] }
// Publish a batch of one-time KeyPackages so peers can add this device to groups.
router.post('/keypackages', requireAuth, asyncHandler(async (req, res) => {
  const { device_id, key_packages } = req.body ?? {};
  const { user_id } = (req as any).auth;
  if (!device_id || !Array.isArray(key_packages) || key_packages.length === 0) {
    return res.status(400).json({ error: 'device_id and key_packages[] required' });
  }
  if (key_packages.length > MAX_KEY_PACKAGES_PER_REQUEST) {
    return res.status(400).json({ error: `at most ${MAX_KEY_PACKAGES_PER_REQUEST} key packages per request` });
  }

  // Decode first, insert once. An entry that is not a string, or decodes to nothing, is
  // dropped here rather than sent to Postgres — key_package is `bytea not null`, and an
  // empty buffer satisfies NOT NULL while being useless to every peer that consumes it.
  const blobs = (key_packages as unknown[])
    .filter((kp): kp is string => typeof kp === 'string' && kp.length > 0)
    .map((kp) => b64(kp))
    .filter((buf): buf is Buffer => buf != null && buf.length > 0);
  if (blobs.length === 0) return res.status(400).json({ error: 'no usable key packages' });

  // ONE multi-row INSERT. The placeholders are generated, never the values — the buffers are
  // still bound parameters, so this is not string interpolation of user data.
  const tuples = blobs.map((_, i) => `($1, $2, $${i + 3})`).join(', ');
  await query(
    `insert into mls_key_packages (user_id, device_id, key_package) values ${tuples}`,
    [user_id, device_id, ...blobs]
  );
  res.json({ uploaded: blobs.length });
}));

// GET /mls/keypackages/:user_id — consume one KeyPackage per active device of the
// target user (so the caller can add them to a group). One-time: marked consumed.
//
// ONE STATEMENT for every device, where it used to be an UPDATE per device. The lateral
// subquery picks the oldest unconsumed package for each device and takes a row lock with
// SKIP LOCKED, so two people adding the same user to two different groups at the same moment
// get DIFFERENT packages instead of blocking on each other or — worse — both consuming the
// same one. That property is the whole reason this is not a plain UPDATE ... WHERE IN.
router.get('/keypackages/:user_id', requireAuth, asyncHandler(async (req, res) => {
  const rows = await query<{ device_id: string; key_package: Buffer }>(
    `with picked as (
       select p.id
         from devices d
         cross join lateral (
           select kp.id
             from mls_key_packages kp
            where kp.device_id = d.id and kp.consumed_at is null
            order by kp.created_at
            limit 1
            for update skip locked
         ) p
        where d.user_id = $1 and d.revoked_at is null
     )
     update mls_key_packages k
        set consumed_at = now()
       from picked
      where k.id = picked.id
     returning k.device_id, k.key_package`,
    [req.params.user_id]
  );
  // base64 in JS, not Postgres' encode(): encode(...,'base64') wraps at 76 columns, and a
  // newline in the middle of a KeyPackage is a decode failure on the client.
  const packages = rows.map((r) => ({
    device_id: r.device_id,
    key_package: r.key_package.toString('base64'),
  }));
  if (packages.length === 0) return res.status(409).json({ error: 'no key packages available for user' });
  res.json({ key_packages: packages });
}));

// POST /mls/group-events  { conversation_id, events: [{ recipient_user_id, kind, payload(b64), ratchet_tree?(b64) }] }
// Store + push Welcome/Commit control messages to recipients (caller must be a member).
router.post('/group-events', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { conversation_id, events } = req.body ?? {};
  if (!conversation_id || !Array.isArray(events)) {
    return res.status(400).json({ error: 'conversation_id and events[] required' });
  }
  const member = await query(
    `select 1 from conversation_members where conversation_id = $1 and user_id = $2 and left_at is null`,
    [conversation_id, user_id]
  );
  if (!member[0]) return res.status(403).json({ error: 'not a member of this conversation' });

  if (events.length > MAX_EVENTS_PER_REQUEST) {
    return res.status(400).json({ error: `at most ${MAX_EVENTS_PER_REQUEST} events per request` });
  }

  // Malformed entries are skipped, exactly as before — a client that sends one bad row in a
  // Commit fan-out must not lose the other 511.
  const valid = (events as any[]).filter(
    (e) => e?.recipient_user_id && ['welcome', 'commit'].includes(e?.kind) && typeof e?.payload === 'string'
  );
  if (valid.length === 0) return res.json({ stored: 0 });

  // ── ONE INSERT for the whole fan-out ────────────────────────────────────────
  // conversation_id and sender are shared across every row ($1, $2); the four per-event
  // values start at $3. Generated placeholders, bound values — no interpolation of client
  // data.
  const tuples = valid
    .map((_, i) => `($1, $2, $${i * 4 + 3}, $${i * 4 + 4}, $${i * 4 + 5}, $${i * 4 + 6})`)
    .join(', ');
  const params: unknown[] = [conversation_id, user_id];
  for (const e of valid) params.push(e.recipient_user_id, e.kind, b64(e.payload), b64(e.ratchet_tree));
  const inserted = await query<{ id: string; recipient_user_id: string }>(
    `insert into mls_group_events (conversation_id, sender_user_id, recipient_user_id, kind, payload, ratchet_tree)
          values ${tuples}
       returning id, recipient_user_id`,
    params
  );

  // ── DELIVERY IS TRACKED PER DEVICE, NOT PER USER ────────────────────────────
  //
  // The old scheme marked every undelivered row for a USER delivered on the first fetch,
  // so on a two-device account whichever device polled first consumed the commits and the
  // other never saw them. That is unrecoverable: max_past_epochs = 0, so a member who
  // misses one commit cannot decrypt anything afterwards and cannot catch up.
  //
  // One row per (event, device). Written with unnest rather than a loop because a commit in
  // a large group fans out to every member's every device, and a per-row insert there is
  // thousands of sequential round trips.
  if (inserted.length) {
    await query(
      `insert into mls_event_deliveries (event_id, device_id, recipient_user_id)
       select e.id, d.id, e.uid
         from unnest($1::uuid[], $2::uuid[]) as e(id, uid)
         join devices d on d.user_id = e.uid and d.revoked_at is null
       on conflict do nothing`,
      [inserted.map((r) => r.id), inserted.map((r) => r.recipient_user_id)]
    );
  }

  // ── ONE PIPELINE for the wake-ups ───────────────────────────────────────────
  // Deduplicated by recipient: a fan-out that sends a Welcome and a Commit to the same person
  // needs one nudge, not two — the notice carries no payload, it only says "there is
  // something on /mls/group-events for you". `kind` is reported as the first kind seen for
  // that recipient and is a hint, not a contract; the client fetches whatever is actually
  // pending. Pipelined so 512 recipients cost one round trip instead of 512.
  const firstKindByUser = new Map<string, string>();
  for (const e of valid) if (!firstKindByUser.has(e.recipient_user_id)) firstKindByUser.set(e.recipient_user_id, e.kind);
  try {
    const pipe = publisher.pipeline();
    for (const [uid, kind] of firstKindByUser) {
      pipe.publish(`channel:user:${uid}`, JSON.stringify({ type: 'mls_event', conversation_id, kind }));
    }
    await pipe.exec();
  } catch (e) {
    // The rows are committed; the notice is a latency optimisation. Every client also polls
    // GET /mls/group-events on reconnect, so a failed publish delays a Welcome, it does not
    // lose one — and failing the request here would make the caller resend events that are
    // already stored.
    console.warn('[mls] group-event notify failed:', (e as Error).message);
  }

  res.json({ stored: valid.length });
}));

// GET /mls/group-events — undelivered Welcome/Commit events for the caller; marks delivered.
router.get('/group-events', requireAuth, async (req, res) => {
  const { user_id, device_id: authDeviceId } = (req as any).auth;
  // The device asks for its OWN backlog. Taken from the query string when the JWT does not
  // carry one (older tokens predate device-scoped claims), and validated against the caller
  // — otherwise a client could drain another device's queue and destroy that device's group.
  const claimed = typeof req.query.device_id === 'string' ? req.query.device_id : null;
  const deviceId = authDeviceId ?? claimed;
  if (!deviceId) {
    return res.status(400).json({ error: 'device_id required' });
  }
  if (claimed && authDeviceId && claimed !== authDeviceId) {
    return res.status(403).json({ error: 'device_id does not match this session' });
  }
  const owns = await query<{ one: number }>(
    `select 1 as one from devices where id = $1 and user_id = $2 and revoked_at is null limit 1`,
    [deviceId, user_id]
  );
  if (!owns.length) return res.status(403).json({ error: 'unknown device' });

  const rows = await query(
    `select e.id, e.conversation_id, e.sender_user_id, e.kind,
            encode(e.payload,'base64') as payload,
            encode(e.ratchet_tree,'base64') as ratchet_tree, e.created_at
       from mls_event_deliveries d
       join mls_group_events e on e.id = d.event_id
      where d.device_id = $1 and d.delivered_at is null
      order by e.created_at asc`,
    [deviceId]
  );
  if (rows.length) {
    // Marks only THIS device's rows. Another device of the same account still has its own
    // copy of the queue and is unaffected — which is the entire point of the change.
    await query(
      `update mls_event_deliveries set delivered_at = now()
        where device_id = $1 and delivered_at is null`,
      [deviceId]
    );
  }
  res.json({ events: rows });
});

export default router;
