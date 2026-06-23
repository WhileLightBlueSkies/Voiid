// Prekey server (Section 3.2): storage + distribution of PUBLIC bundles. GET consumes one one-time prekey.
import { Router } from 'express';
import { pool, query } from '../db';
import { requireAuth } from '../auth';
import { b64, asyncHandler } from '../util';

const router = Router();

// POST /prekeys/upload  { device_id, one_time_prekeys:[{key_id,public_key(b64)}], signed_prekey?:{key_id,public_key,signature} }
// signed_prekey is OPTIONAL — e2e-core (vodozemac) bundles don't include a
// separate signed prekey; a session needs only identity_key + one one-time key.
router.post('/upload', requireAuth, asyncHandler(async (req, res) => {
  const { device_id, signed_prekey, one_time_prekeys } = req.body ?? {};
  if (!device_id) return res.status(400).json({ error: 'device_id required' });

  if (signed_prekey) {
    await query(
      `insert into signed_prekeys (device_id, key_id, public_key, signature)
         values ($1, $2, $3, $4)
         on conflict (device_id, key_id) do nothing`,
      [device_id, signed_prekey.key_id, b64(signed_prekey.public_key), b64(signed_prekey.signature)]
    );
  }

  for (const otp of (one_time_prekeys ?? [])) {
    await query(
      `insert into one_time_prekeys (device_id, key_id, public_key)
         values ($1, $2, $3) on conflict (device_id, key_id) do nothing`,
      [device_id, otp.key_id, b64(otp.public_key)]
    );
  }
  res.json({ uploaded: true });
}));

// GET /prekeys/count — how many UNCONSUMED one-time prekeys the caller has left
// across their own active devices. The client polls this to decide when to
// replenish (one-time keys are consumed as peers start sessions with us).
// Registered BEFORE /:user_id so it isn't swallowed by the user-id route.
router.get('/count', requireAuth, async (req, res) => {
  const { user_id } = (req as any).auth;
  const rows = await query<{ count: string }>(
    `select count(*)::int as count from one_time_prekeys otp
       join devices d on d.id = otp.device_id
      where d.user_id = $1 and d.revoked_at is null and otp.consumed_at is null`,
    [user_id]
  );
  res.json({ available: Number(rows[0]?.count ?? 0) });
});

// GET /prekeys/:user_id — returns a bundle per active device, consuming one one-time prekey transactionally.
router.get('/:user_id', requireAuth, async (req, res) => {
  // Freshest device first: a reinstall can leave a stale device row around, and
  // the client takes the first bundle — so hand out the most recently active.
  const devices = await query<{ id: string; registration_id: number; identity_public_key: Buffer }>(
    `select id, registration_id, identity_public_key from devices
       where user_id = $1 and revoked_at is null
       order by last_seen_at desc nulls last, created_at desc`,
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
  const { device_id, one_time_prekeys } = req.body ?? {};
  if (!device_id) return res.status(400).json({ error: 'device_id required' });
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
