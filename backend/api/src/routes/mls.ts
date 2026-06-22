// MLS (RFC 9420) group-messaging plumbing (Phase 3). The server only stores/relays
// OPAQUE MLS bytes — public KeyPackages, and Welcome/Commit control messages. Group
// application ciphertext rides the existing /messages relay. No group keys here.
import { Router } from 'express';
import { query } from '../db';
import { publisher } from '../redis';
import { requireAuth } from '../auth';

const router = Router();

// POST /mls/keypackages  { device_id, key_packages: [base64, ...] }
// Publish a batch of one-time KeyPackages so peers can add this device to groups.
router.post('/keypackages', requireAuth, async (req, res) => {
  const { device_id, key_packages } = req.body ?? {};
  const { user_id } = (req as any).auth;
  if (!device_id || !Array.isArray(key_packages) || key_packages.length === 0) {
    return res.status(400).json({ error: 'device_id and key_packages[] required' });
  }
  for (const kp of key_packages) {
    if (typeof kp !== 'string') continue;
    await query(
      `insert into mls_key_packages (user_id, device_id, key_package)
         values ($1, $2, decode($3,'base64'))`,
      [user_id, device_id, kp]
    );
  }
  res.json({ uploaded: key_packages.length });
});

// GET /mls/keypackages/:user_id — consume one KeyPackage per active device of the
// target user (so the caller can add them to a group). One-time: marked consumed.
router.get('/keypackages/:user_id', requireAuth, async (req, res) => {
  const devices = await query<{ id: string }>(
    `select id from devices where user_id = $1 and revoked_at is null`,
    [req.params.user_id]
  );
  const packages: { device_id: string; key_package: string }[] = [];
  for (const d of devices) {
    const row = (await query<{ key_package: Buffer }>(
      `update mls_key_packages set consumed_at = now()
         where id = (select id from mls_key_packages
                       where device_id = $1 and consumed_at is null
                       order by created_at limit 1 for update skip locked)
         returning key_package`,
      [d.id]
    ))[0];
    if (row) packages.push({ device_id: d.id, key_package: row.key_package.toString('base64') });
  }
  if (packages.length === 0) return res.status(409).json({ error: 'no key packages available for user' });
  res.json({ key_packages: packages });
});

// POST /mls/group-events  { conversation_id, events: [{ recipient_user_id, kind, payload(b64), ratchet_tree?(b64) }] }
// Store + push Welcome/Commit control messages to recipients (caller must be a member).
router.post('/group-events', requireAuth, async (req, res) => {
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

  let stored = 0;
  for (const e of events) {
    if (!e?.recipient_user_id || !['welcome', 'commit'].includes(e?.kind) || typeof e?.payload !== 'string') continue;
    await query(
      `insert into mls_group_events (conversation_id, sender_user_id, recipient_user_id, kind, payload, ratchet_tree)
         values ($1,$2,$3,$4, decode($5,'base64'), $6)`,
      [conversation_id, user_id, e.recipient_user_id, e.kind, e.payload,
       e.ratchet_tree ? Buffer.from(e.ratchet_tree, 'base64') : null]
    );
    stored++;
    await publisher.publish(`channel:user:${e.recipient_user_id}`, JSON.stringify({
      type: 'mls_event', conversation_id, kind: e.kind,
    }));
  }
  res.json({ stored });
});

// GET /mls/group-events — undelivered Welcome/Commit events for the caller; marks delivered.
router.get('/group-events', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query(
    `select id, conversation_id, sender_user_id, kind,
            encode(payload,'base64') as payload,
            encode(ratchet_tree,'base64') as ratchet_tree, created_at
       from mls_group_events
      where recipient_user_id = $1 and delivered_at is null
      order by created_at asc`,
    [user_id]
  );
  if (rows.length) {
    await query(
      `update mls_group_events set delivered_at = now()
         where recipient_user_id = $1 and delivered_at is null`,
      [user_id]
    );
  }
  res.json({ events: rows });
});

export default router;
