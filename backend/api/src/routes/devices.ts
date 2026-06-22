// Device routes (Section 4.3). Server stores PUBLIC identity key only; private keys never leave device.
import { Router } from 'express';
import { query } from '../db';
import { requireAuth } from '../auth';

const router = Router();

// POST /devices/register  { platform, registration_id, identity_public_key(base64), device_name?, push_token?, push_provider? }
router.post('/register', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const { platform, registration_id, identity_public_key, device_name, push_token, push_provider } = req.body ?? {};
  if (!platform || registration_id == null || !identity_public_key) {
    return res.status(400).json({ error: 'platform, registration_id, identity_public_key required' });
  }
  const rows = await query<{ id: string }>(
    `insert into devices (user_id, platform, registration_id, identity_public_key, device_name, push_token, push_provider)
       values ($1, $2, $3, decode($4,'base64'), $5, $6, $7)
       on conflict (user_id, registration_id)
       do update set identity_public_key = excluded.identity_public_key,
                     push_token = excluded.push_token, revoked_at = null, updated_at = now()
       returning id`,
    [user_id, platform, registration_id, identity_public_key, device_name, push_token, push_provider]
  );
  const deviceId = rows[0].id;

  // Single active device per (user, platform): a reinstall regenerates the
  // registration_id, so the upsert above creates a NEW row and the OLD device
  // lingers as "active" with a stale identity key + exhausted one-time prekeys.
  // Peers fetch one bundle (firstOrNull) and could land on that dead device →
  // "peer has no available prekeys". Revoke the superseded same-platform devices
  // and drop their now-useless one-time prekeys so resolution is unambiguous.
  const stale = await query<{ id: string }>(
    `update devices set revoked_at = now()
       where user_id = $1 and platform = $2 and id <> $3 and revoked_at is null
       returning id`,
    [user_id, platform, deviceId]
  );
  if (stale.length) {
    await query(
      `delete from one_time_prekeys where device_id = any($1::uuid[])`,
      [stale.map((d) => d.id)]
    );
  }

  res.json({ device_id: deviceId });
});

// GET /devices/:user_id — active devices (public info only).
// identity_public_key (base64) is PUBLIC and required by peers to acceptSession
// on an inbound PreKey message — without it the receive path can't decrypt.
router.get('/:user_id', requireAuth, async (req, res) => {
  const rows = await query<{ id: string; identity_public_key: Buffer }>(
    `select id, platform, device_name, registration_id, last_seen_at, identity_public_key
       from devices where user_id = $1 and revoked_at is null
       order by last_seen_at desc nulls last, created_at desc`,
    [req.params.user_id]
  );
  const devices = rows.map((d: any) => ({
    ...d,
    identity_public_key: d.identity_public_key ? d.identity_public_key.toString('base64') : null,
  }));
  res.json({ devices });
});

// DELETE /devices/:device_id — revocation: invalidate immediately (Section 4.3)
router.delete('/:device_id', requireAuth, async (req, res) => {
  await query(`update devices set revoked_at = now() where id = $1`, [req.params.device_id]);
  // prekeys cascade-cleaned by removing the device's keys
  await query(`delete from one_time_prekeys where device_id = $1`, [req.params.device_id]);
  res.json({ revoked: true });
});

export default router;
