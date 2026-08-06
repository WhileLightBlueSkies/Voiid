// Device routes (Section 4.3). Server stores PUBLIC identity key only; private keys never leave device.
import { Router } from 'express';
import { query } from '../db';
import { requireAuth } from '../auth';
import { b64, asyncHandler } from '../util';

const router = Router();

// POST /devices/register  { platform, registration_id, identity_public_key(base64), device_name?, push_token?, push_provider? }
router.post('/register', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { platform, registration_id, identity_public_key, device_name, push_token, push_provider } = req.body ?? {};
  if (!platform || registration_id == null || !identity_public_key) {
    return res.status(400).json({ error: 'platform, registration_id, identity_public_key required' });
  }
  const rows = await query<{ id: string }>(
    `insert into devices (user_id, platform, registration_id, identity_public_key, device_name, push_token, push_provider)
       values ($1, $2, $3, $4, $5, $6, $7)
       on conflict (user_id, registration_id)
       do update set identity_public_key = excluded.identity_public_key,
                     push_token = excluded.push_token,
                     -- Every push query requires BOTH token and provider to be non-null.
                     -- A row first registered before its push token existed has a null
                     -- provider forever if this only ever runs on insert, so the device
                     -- stays unreachable no matter how often it re-registers. Coalesced
                     -- so a later token-less register cannot blank a live provider.
                     push_provider = coalesce(excluded.push_provider, devices.push_provider),
                     revoked_at = null, updated_at = now()
       returning id`,
    [user_id, platform, registration_id, b64(identity_public_key), device_name, push_token, push_provider]
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
}));

// POST /devices/voip-token  { device_id, voip_token }
//
// iOS PushKit registration. The PushKit token is a DIFFERENT value from the APNs
// alert token registered above (`push_token`): iOS mints it from PKPushRegistry and
// it is addressed on the `<bundle-id>.voip` topic. Only a VoIP push can resume a
// killed app fast enough to ring via CallKit, so calls prefer this token on iOS.
//
// Registered separately (rather than at /register) because PushKit hands the token
// to the app asynchronously, often well after device registration has completed.
// Passing `voip_token: null` unregisters — used on logout / CallKit teardown.
router.post('/voip-token', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { device_id, voip_token } = req.body ?? {};

  if (typeof device_id !== 'string' || !device_id) {
    return res.status(400).json({ error: 'device_id required' });
  }
  if (voip_token != null && (typeof voip_token !== 'string' || !voip_token.trim())) {
    return res.status(400).json({ error: 'voip_token must be a non-empty string or null' });
  }

  // Scope the write to the CALLER's own devices: a token bound to someone else's
  // device row would redirect their call rings to an attacker-controlled handset.
  const rows = await query<{ id: string }>(
    `update devices set voip_token = $3, updated_at = now()
       where id = $1 and user_id = $2 and revoked_at is null
       returning id`,
    [device_id, user_id, voip_token ?? null]
  );
  if (!rows[0]) return res.status(404).json({ error: 'device not found' });

  res.json({ device_id: rows[0].id, voip_registered: voip_token != null });
}));

// GET /devices/:user_id — active devices (public info only).
// identity_public_key (base64) is PUBLIC and required by peers to acceptSession
// on an inbound PreKey message — without it the receive path can't decrypt.
router.get('/:user_id', requireAuth, asyncHandler(async (req, res) => {
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
}));

// DELETE /devices/:device_id — revocation: invalidate immediately (Section 4.3)
//
// Scoped to the CALLER's own devices. Device ids are not secret — GET /devices/:user_id
// hands them to any authenticated caller — so an unscoped revoke would let anyone knock
// out anyone else's device and delete its one-time prekeys, denying the victim inbound
// sessions. The only legitimate caller is the user's own linked-devices screen.
router.delete('/:device_id', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query<{ id: string }>(
    `update devices set revoked_at = now()
       where id = $1 and user_id = $2
       returning id`,
    [req.params.device_id, user_id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'device not found' });
  // prekeys cascade-cleaned by removing the device's keys — only once the revoke matched,
  // so a miss never touches another user's prekeys.
  await query(`delete from one_time_prekeys where device_id = $1`, [req.params.device_id]);
  res.json({ revoked: true });
}));

export default router;
