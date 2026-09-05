// Device routes (Section 4.3). Server stores PUBLIC identity key only; private keys never leave device.
import { Router } from 'express';
import { query, withTransaction } from '../db';
import { requireAuth, requireAuthForRegistration, createDeviceSession, revokeDeviceSessions } from '../auth';
import { logSecurityEvent } from '../security';
import { b64, asyncHandler } from '../util';

const router = Router();

// POST /devices/register  { platform, registration_id, identity_public_key(base64), device_name?, push_token?, push_provider? }
//
// THE ONE ROUTE A BOOTSTRAP CREDENTIAL CAN SPEND. POST /auth/firebase proves a phone
// number and nothing more; this is where that proof becomes a device-bound session, so it
// must keep accepting an unbound credential even after the cutoff — it is the only way
// across. It also accepts an existing session (a reinstall re-registering itself), in
// which case the caller is handed a fresh token and its old session is ended below.
router.post('/register', requireAuthForRegistration, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { platform, registration_id, identity_public_key, device_name, push_token, push_provider } = req.body ?? {};
  if (!platform || registration_id == null || !identity_public_key) {
    return res.status(400).json({ error: 'platform, registration_id, identity_public_key required' });
  }
  const { deviceId, token, superseded } = await withTransaction(async (execute) => {
    const rows = await execute<{ id: string }>(
      `insert into devices (user_id, platform, registration_id, identity_public_key, device_name, push_token, push_provider)
         values ($1, $2, $3, $4, $5, $6, $7)
         on conflict (user_id, registration_id)
         do update set identity_public_key = excluded.identity_public_key,
                       -- Coalesced for the SAME reason as the provider below, which was
                       -- already guarded while this line was not. A register sent before
                       -- FCM/APNs has issued a token carries push_token = null, and
                       -- assigning that over a live token makes the device ring-deaf until
                       -- something happens to re-register it with a real one.
                       push_token = coalesce(excluded.push_token, devices.push_token),
                       -- Every push query requires BOTH token and provider to be non-null.
                       -- A row first registered before its push token existed has a null
                       -- provider forever if this only ever runs on insert, so the device
                       -- stays unreachable no matter how often it re-registers. Coalesced
                       -- so a later token-less register cannot blank a live provider.
                       push_provider = coalesce(excluded.push_provider, devices.push_provider),
                       -- Re-registering IS the explicit fresh authorization that reinstates a
                       -- device, including one the user revoked: the caller had to present a
                       -- live credential to get here. The reason is cleared with the flag so a
                       -- stale 'user_revoked' cannot keep refusing the device's own uploads.
                       revoked_at = null, revoked_reason = null, updated_at = now()
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
    //
    // 'superseded', not 'user_revoked': the distinction is load-bearing. A superseded row is
    // still reinstatable by its owner's prekey upload (that is how a device whose upload
    // raced this registration recovers), while a device the user revoked on purpose is not.
    const stale = await execute<{ id: string }>(
      `update devices set revoked_at = now(), revoked_reason = 'superseded'
         where user_id = $1 and platform = $2 and id <> $3 and revoked_at is null
         returning id`,
      [user_id, platform, deviceId]
    );
    if (stale.length) {
      await execute(
        `delete from one_time_prekeys where device_id = any($1::uuid[])`,
        [stale.map((d) => d.id)]
      );
    }

    // Minted in the same transaction as the device row: a session pointing at a device
    // that rolled back would authorize nothing, and a device with no session would leave
    // the client holding a token it cannot use.
    const session = await createDeviceSession(user_id, deviceId, execute);
    return { deviceId, token: session.token, superseded: stale.map((d) => d.id) };
  });

  // AFTER COMMIT. The superseded device's credential dies with its row, so recovering that
  // device needs a fresh registration — explicit authorization, not a silent un-revoke.
  // Published outside the transaction so a rollback cannot sign a device out of a
  // registration that never happened.
  if (superseded.length) {
    await revokeDeviceSessions(superseded, 'superseded');
    for (const id of superseded) {
      await logSecurityEvent('device_revoked', { user_id, device_id: id, metadata: { via: 'superseded', by: deviceId } });
    }
  }

  // `token` is the device-bound session. Clients MUST replace the credential they used to
  // call this with the one returned here; the old one stops working at the cutoff.
  res.json({ device_id: deviceId, token });
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
    `select d.id, d.platform, d.device_name, d.registration_id, d.last_seen_at, d.identity_public_key
       from devices d
      where d.user_id = $1
        and d.revoked_at is null
        -- A device with NO usable key material can never open a session: Olm needs
        -- either a one-time prekey or a fallback key to start one. Advertising such a
        -- device makes every sender fan out to it, fail, and retry forever at
        -- 409 "peer has no available prekeys" — the message parks at "sending" with no
        -- error shown, and the user is never told why.
        --
        -- This happens for real: registering a device REVOKES its same-platform siblings
        -- (see the register handler above), and ownsDevice in routes/prekeys.ts rejects
        -- uploads from a revoked device with a 404. A device whose upload raced a sibling
        -- registration therefore stays listed with zero keys, permanently unreachable.
        --
        -- Filtering here rather than at the send path keeps the invariant at the single
        -- point that publishes targets: a device peers cannot reach is not a target.
        -- UNCONSUMED one-time keys only: prekeys/:user_id stamps consumed_at when it
        -- hands one out, so counting every row would keep advertising a device whose
        -- supply is spent — exactly the state this filter exists to exclude.
        and (
          exists (select 1 from one_time_prekeys otp
                   where otp.device_id = d.id and otp.consumed_at is null)
          or exists (select 1 from signed_prekeys sp where sp.device_id = d.id)
        )
      order by d.last_seen_at desc nulls last, d.created_at desc`,
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
    `update devices set revoked_at = now(), revoked_reason = 'user_revoked', updated_at = now()
       where id = $1 and user_id = $2
       returning id`,
    [req.params.device_id, user_id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'device not found' });
  // prekeys cascade-cleaned by removing the device's keys — only once the revoke matched,
  // so a miss never touches another user's prekeys.
  await query(`delete from one_time_prekeys where device_id = $1`, [req.params.device_id]);
  // The row alone never stopped anything: the revoked device still held a valid 30-day JWT
  // and kept sending, fetching and uploading keys. End the credential too, and close the
  // socket it is holding right now.
  await revokeDeviceSessions([rows[0].id], 'user_revoked');
  await logSecurityEvent('device_revoked', { user_id, device_id: rows[0].id, metadata: { via: 'user_request' } });
  res.json({ revoked: true });
}));

export default router;
