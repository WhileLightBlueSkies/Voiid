// Profile-key routes — ENCRYPTED PROFILE PHOTOS (see 021_profile_keys.sql).
//
// Avatars were the one media surface stored in the CLEAR: a raw JPEG on R2 that anyone with
// bucket access, including us, could open. Chat media and Moments have always been encrypted
// on-device; this closes the gap.
//
// WHY A SEPARATE MECHANISM. A chat photo has ONE known audience, so a fresh per-attachment key
// rides the ratchet with the message. An avatar has no fixed audience — it is shown to anyone
// who might contact you, including someone who found your @username and has never had a
// session with you — so there is no single message to attach a key to. The key is therefore
// per-USER and long-lived, wrapped once per recipient DEVICE over that device's ratchet
// (Signal's "profile key" model).
//
// THE SERVER NEVER SEES A PROFILE KEY. Every route here moves opaque per-device ciphertext,
// exactly as stories.ts does. If any endpoint in this file ever gains a plaintext key
// parameter, that is a bug, not a feature.
import { Router } from 'express';
import { query } from '../db';
import { publisher } from '../redis';
import { requireAuth } from '../auth';
import { b64, asyncHandler } from '../util';
import { sendWakePush } from '../push';

const router = Router();

/** Wake devices that just received a wrapped key, so an avatar resolves without a cold open. */
function scheduleWakePush(deviceIds: string[]): void {
  if (!deviceIds.length) return;
  query<{ push_token: string; push_provider: string }>(
    `select push_token, push_provider from devices
      where id = any($1::uuid[])
        and push_token is not null and push_provider is not null`,
    [deviceIds]
  )
    .then((targets) => {
      // SILENT: a profile key arriving is not an event a user should be notified about. It is
      // pure plumbing, and a banner for it would be indistinguishable from spam.
      if (targets.length) void sendWakePush(targets, { type: 'wake', silent: true });
    })
    .catch((e) => console.warn('[profile-keys] wake lookup failed:', (e as Error).message));
}

// ─────────────────────────────────────────────────────────────────────────────────
// POST /profile-keys/publish
//   { key_version, entries: [{ recipient_device_id, ciphertext }] }
//
// Called after minting or rotating a profile key: one wrapped copy per recipient device.
// Idempotent per (owner, device) so a partially-delivered fan-out is safe to retry.
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/publish', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const keyVersion = Number(req.body?.key_version);
  const entries = req.body?.entries;

  if (!Number.isInteger(keyVersion) || keyVersion < 1) {
    return res.status(400).json({ error: 'key_version must be a positive integer' });
  }
  if (!Array.isArray(entries) || entries.length === 0) {
    return res.status(400).json({ error: 'entries required' });
  }
  if (entries.length > 2000) {
    return res.status(400).json({ error: 'too many entries' });
  }

  // Only live devices. An unknown or revoked id is SKIPPED rather than failing the whole
  // batch: a client's device list is always slightly stale, and one departed device must not
  // block a rotation from reaching everyone else.
  const requested = [...new Set(entries.map((e: any) => e.recipient_device_id))];
  const owners = await query<{ id: string; user_id: string }>(
    `select id, user_id from devices where id = any($1::uuid[]) and revoked_at is null`,
    [requested]
  );
  const live = new Map(owners.map((o) => [o.id, o.user_id]));

  const stored: string[] = [];
  for (const e of entries) {
    if (!e?.recipient_device_id || typeof e.ciphertext !== 'string') continue;
    if (!live.has(e.recipient_device_id)) continue;
    // ON CONFLICT UPDATE, not DO NOTHING (which is what stories uses): a story key is written
    // once and never changes, but a profile key is REPLACED on every rotation. Doing nothing
    // here would leave every existing contact holding the superseded key forever — i.e.
    // rotation would silently not work, which is the one thing it must do.
    await query(
      `insert into profile_keys (owner_user_id, recipient_device_id, ciphertext, key_version)
         values ($1, $2, $3, $4)
       on conflict (owner_user_id, recipient_device_id) do update
         set ciphertext = excluded.ciphertext,
             key_version = excluded.key_version,
             created_at = now(),
             delivered_at = null`,
      [user_id, e.recipient_device_id, b64(e.ciphertext), keyVersion]
    );
    if (!stored.includes(e.recipient_device_id)) stored.push(e.recipient_device_id);
  }

  if (stored.length) {
    // Record the version we just published. Clients compare against this to detect a rotation
    // without having to fail a decrypt first.
    await query(
      `update users set profile_key_version = $2 where id = $1 and profile_key_version < $2`,
      [user_id, keyVersion]
    );

    const byUser = new Map<string, string[]>();
    for (const deviceId of stored) {
      const uid = live.get(deviceId)!;
      byUser.set(uid, [...(byUser.get(uid) ?? []), deviceId]);
    }
    for (const [uid, devIds] of byUser) {
      await publisher.publish(
        `channel:user:${uid}`,
        JSON.stringify({ type: 'profile_key', owner_id: user_id, recipient_device_ids: devIds })
      );
    }
    scheduleWakePush(stored);
  }

  res.json({ delivered_devices: stored.length });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /profile-keys/pending?device_id=…
//
// Every wrapped key addressed to this device that it has not yet fetched. Marks them delivered
// atomically, exactly like GET /stories/feed, so two concurrent syncs cannot double-deliver.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/pending', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const deviceId = String(req.query.device_id ?? '');
  if (!deviceId) return res.status(400).json({ error: 'device_id required' });

  // The caller may only read envelopes addressed to a device it owns.
  const owned = await query(
    `select 1 from devices where id = $1::uuid and user_id = $2 and revoked_at is null`,
    [deviceId, user_id]
  );
  if (!owned.length) return res.status(403).json({ error: 'device does not belong to this user' });

  const rows = await query(
    `update profile_keys k set delivered_at = now()
       from users u
      where k.recipient_device_id = $1::uuid
        and k.delivered_at is null
        and u.id = k.owner_user_id
      returning k.owner_user_id, k.key_version,
                translate(encode(k.ciphertext,'base64'), E'\n', '') as ciphertext,
                u.encrypted_photo_url`,
    [deviceId]
  );
  res.json({ keys: rows });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// GET /profile-keys/for/:userId?device_id=…
//
// Re-fetch ONE owner's wrapped key — the recovery path when a client finds it cannot decrypt
// an avatar (stale key after a rotation, or a lost local store). Does not clear delivered_at,
// so it is safe to call repeatedly.
// ─────────────────────────────────────────────────────────────────────────────────
router.get('/for/:userId', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const deviceId = String(req.query.device_id ?? '');
  if (!deviceId) return res.status(400).json({ error: 'device_id required' });

  const owned = await query(
    `select 1 from devices where id = $1::uuid and user_id = $2 and revoked_at is null`,
    [deviceId, user_id]
  );
  if (!owned.length) return res.status(403).json({ error: 'device does not belong to this user' });

  const rows = await query(
    `select k.owner_user_id, k.key_version,
            translate(encode(k.ciphertext,'base64'), E'\n', '') as ciphertext,
            u.encrypted_photo_url
       from profile_keys k
       join users u on u.id = k.owner_user_id
      where k.owner_user_id = $1::uuid and k.recipient_device_id = $2::uuid
      limit 1`,
    [req.params.userId, deviceId]
  );
  if (!rows[0]) return res.status(404).json({ error: 'no profile key for this user' });
  res.json({ key: rows[0] });
}));

// ─────────────────────────────────────────────────────────────────────────────────
// POST /profile-keys/photo  { encrypted_photo_url }
//
// Point the user row at the CIPHERTEXT object after an encrypted avatar upload.
//
// `photo_url` (the old plaintext object) is deliberately left intact: it is the rollback path
// while clients are mixed-version, and it is what makes migration state legible —
// photo_url set + encrypted_photo_url null means "not yet migrated".
// ─────────────────────────────────────────────────────────────────────────────────
router.post('/photo', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const key = req.body?.encrypted_photo_url;
  if (typeof key !== 'string' || !key) {
    return res.status(400).json({ error: 'encrypted_photo_url required' });
  }
  await query(
    `update users set encrypted_photo_url = $2, photo_encrypted_at = now() where id = $1`,
    [user_id, key]
  );
  res.json({ ok: true });
}));

export default router;
