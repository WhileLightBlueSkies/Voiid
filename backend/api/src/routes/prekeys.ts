// Prekey server (Section 3.2): storage + distribution of PUBLIC bundles. GET consumes one one-time prekey.
import { Router } from 'express';
import { pool, query } from '../db';
import { requireAuth } from '../auth';
import { b64, asyncHandler } from '../util';

const router = Router();

// POST /prekeys/upload  { device_id, one_time_prekeys:[{key_id,public_key(b64)}], signed_prekey?:{key_id,public_key,signature} }
// signed_prekey is OPTIONAL — e2e-core (vodozemac) bundles don't include a
// separate signed prekey; a session needs only identity_key + one one-time key.
/**
 * A device is only ever writable by the account that owns it.
 *
 * /upload and /refresh took `device_id` straight from the request BODY and never read the
 * authenticated caller, so any signed-in user could write prekey material against ANY
 * device id — and device ids are not secret (GET /devices/:user_id returns them to any
 * authenticated caller). The identity key is still TOFU-pinned per device, so this is not
 * by itself a session takeover; but planting one-time prekeys on someone else's device
 * lets a sender consume an attacker-supplied key the victim cannot match, which breaks
 * inbound sessions for that device — denial of service against a person's ability to
 * receive messages at all.
 *
 * Same flaw class as the ownership check just added to DELETE /devices/:device_id; this is
 * the one file over where it survived.
 */
async function ownsDevice(deviceId: string, userId: string): Promise<boolean> {
  // NOT filtered on `revoked_at is null`, deliberately.
  //
  // Registering a device revokes its same-platform siblings (routes/devices.ts). A device
  // whose prekey upload was still in flight when a sibling registered would then fail this
  // check, 404, and never land its keys — leaving it listed but unreachable, so every send
  // to it parked at 409 "peer has no available prekeys" forever.
  //
  // Ownership is the question this function actually answers, and revocation does not
  // change who owns a device. The caller proved possession of the account via requireAuth;
  // uploading keys for one's own device is exactly how a superseded device recovers.
  const rows = await query<{ one: number }>(
    `select 1 as one from devices
      where id = $1 and user_id = $2
      limit 1`,
    [deviceId, userId]
  );
  return rows.length > 0;
}

router.post('/upload', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { device_id, signed_prekey, one_time_prekeys } = req.body ?? {};
  if (!device_id) return res.status(400).json({ error: 'device_id required' });
  // 404, not 403: a caller must not learn whether a device id they do not own exists.
  if (!(await ownsDevice(device_id, user_id))) {
    return res.status(404).json({ error: 'device not found' });
  }

  if (signed_prekey) {
    // `signature` is nullable as of 044: a vodozemac FALLBACK key is not separately
    // signed, and its authenticity rests on the TOFU-pinned device identity key plus the
    // Olm prekey handshake. `b64(undefined)` returns null, so a client that sends no
    // signature stores null rather than failing the insert.
    await query(
      `insert into signed_prekeys (device_id, key_id, public_key, signature)
         values ($1, $2, $3, $4)
         on conflict (device_id, key_id) do nothing`,
      [device_id, signed_prekey.key_id, b64(signed_prekey.public_key), b64(signed_prekey.signature)]
    );
    // PRUNE SUPERSEDED KEYS, keeping the two most recent — the same pair vodozemac itself
    // retains (current + previous), so a first message already in flight against the
    // just-replaced key still opens.
    //
    // This is not housekeeping. `forget_previous_fallback_key()` on the device drops the
    // PRIVATE half one rotation after replacement, so a row older than that is a public key
    // whose private half is gone. Serving it would hand a sender a key that can never open a
    // session, and the sender would have no way to tell that from the recipient being
    // offline. Pruning here rather than in a worker keeps the invariant next to the only
    // write that can break it.
    await query(
      `delete from signed_prekeys
        where device_id = $1
          and id not in (
            select id from signed_prekeys
             where device_id = $1
             order by created_at desc
             limit 2
          )`,
      [device_id]
    );
  }

  for (const otp of (one_time_prekeys ?? [])) {
    await query(
      `insert into one_time_prekeys (device_id, key_id, public_key)
         values ($1, $2, $3) on conflict (device_id, key_id) do nothing`,
      [device_id, otp.key_id, b64(otp.public_key)]
    );
  }

  // A device that just published key material is demonstrably live, so un-revoke it —
  // otherwise a device superseded by a sibling's registration stays hidden from
  // GET /devices/:user_id and never receives again, despite holding usable keys.
  // Scoped to the caller's own device (ownership was checked above).
  await query(
    `update devices set revoked_at = null, updated_at = now()
      where id = $1 and user_id = $2 and revoked_at is not null`,
    [device_id, user_id]
  );

  res.json({ uploaded: true });
}));

// GET /prekeys/count?device_id=… — how many UNCONSUMED one-time prekeys the caller
// has left. The client polls this to decide when to replenish.
//
// IMPORTANT: pass `device_id` so the count is PER-DEVICE. Without it the count is
// per-user across ALL the caller's devices, so a 2nd device (same number on
// iOS+Android, or a web-linked companion) sees the 1st device's keys, thinks it's
// full, uploads 0 of its own — and a peer who lands on that 0-key device gets a
// null one_time_prekey → 409. The join still scopes to the caller's own devices,
// so a foreign device_id simply counts 0. (device_id-less call kept for back-compat.)
// Registered BEFORE /:user_id so it isn't swallowed by the user-id route.
router.get('/count', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const deviceId = typeof req.query.device_id === 'string' ? req.query.device_id : undefined;
  const rows = await query<{ count: string }>(
    `select count(*)::int as count from one_time_prekeys otp
       join devices d on d.id = otp.device_id
      where d.user_id = $1 and d.revoked_at is null and otp.consumed_at is null
        ${deviceId ? 'and otp.device_id = $2' : ''}`,
    deviceId ? [user_id, deviceId] : [user_id]
  );
  res.json({ available: Number(rows[0]?.count ?? 0) });
}));

// GET /prekeys/:user_id — returns a bundle per active device, consuming one one-time prekey transactionally.
router.get('/:user_id', requireAuth, async (req, res) => {
  // Freshest device first: a reinstall can leave a stale device row around, and
  // the client takes the first bundle — so hand out the most recently active.
  const devices = await query<{ id: string; registration_id: number; identity_public_key: Buffer }>(
    `select d.id, d.registration_id, d.identity_public_key from devices d
       where d.user_id = $1
         and d.revoked_at is null
         -- Same reachability rule as GET /devices/:user_id. A device with neither an
         -- unconsumed one-time key nor a fallback key cannot open an Olm session, so a
         -- bundle for it is unusable: the sender fans out to it, gets nothing it can
         -- encrypt with, and parks the message at 409 forever. Excluded here too because
         -- THIS is the endpoint the send path reads to build its targets.
         and (
           exists (select 1 from one_time_prekeys otp
                    where otp.device_id = d.id and otp.consumed_at is null)
           or exists (select 1 from signed_prekeys sp where sp.device_id = d.id)
         )
       order by d.last_seen_at desc nulls last, d.created_at desc`,
    [req.params.user_id]
  );

  const bundles = [];
  for (const d of devices) {
    const client = await pool.connect();
    try {
      await client.query('begin');
      const signed = (await client.query(
        `select key_id, public_key, signature from signed_prekeys
           where device_id = $1 order by created_at desc limit 1`,
        [d.id]
      )).rows[0];
      // consume one available one-time prekey atomically
      const otpRow = (await client.query(
        `update one_time_prekeys set consumed_at = now()
           where id = (select id from one_time_prekeys
                         where device_id = $1 and consumed_at is null
                         order by created_at limit 1 for update skip locked)
           returning key_id, public_key`,
        [d.id]
      )).rows[0];
      await client.query('commit');

      bundles.push({
        device_id: d.id,
        registration_id: d.registration_id,
        identity_public_key: d.identity_public_key.toString('base64'),
        signed_prekey: signed && {
          key_id: signed.key_id,
          public_key: signed.public_key.toString('base64'),
          signature: signed.signature.toString('base64'),
        },
        one_time_prekey: otpRow && {
          key_id: otpRow.key_id,
          public_key: otpRow.public_key.toString('base64'),
        },
      });
    } catch (e) {
      await client.query('rollback');
      throw e;
    } finally {
      client.release();
    }
  }
  res.json({ bundles });
});

// POST /prekeys/refresh — client replenishes one-time prekeys (same shape as upload's one_time_prekeys)
router.post('/refresh', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { device_id, one_time_prekeys } = req.body ?? {};
  if (!device_id) return res.status(400).json({ error: 'device_id required' });
  if (!(await ownsDevice(device_id, user_id))) {
    return res.status(404).json({ error: 'device not found' });
  }
  for (const otp of (one_time_prekeys ?? [])) {
    await query(
      `insert into one_time_prekeys (device_id, key_id, public_key)
         values ($1, $2, $3) on conflict (device_id, key_id) do nothing`,
      [device_id, otp.key_id, b64(otp.public_key)]
    );
  }
  res.json({ refreshed: true });
}));

export default router;
