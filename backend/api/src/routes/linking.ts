// Device linking (Section 4.3) — QR-based linking for the WEB COMPANION device (WhatsApp-Web style).
// Web is a linked companion (messaging only; no calls). Linking requires explicit approval from an
// existing trusted device. The new device's private keys are generated on-device and never sent here.
//
// Flow:
//   1. New web device calls POST /linking/request  -> gets { link_token } (encode in a QR).
//   2. A logged-in device scans the QR and calls POST /linking/approve { link_token, ... } (authed).
//      The server registers the new device under THAT user and stashes a JWT for the link_token.
//   3. The web device polls GET /linking/poll/:link_token until it receives its { token, user_id, device_id }.
//
// link_token state lives in Redis with a short TTL (Section 4.3: linking is time-bounded).
import { Router } from 'express';
import { randomBytes } from 'crypto';
import { redis } from '../redis';
import { query } from '../db';
import { requireAuth, issueToken } from '../auth';
import { b64, asyncHandler } from '../util';

const router = Router();

const LINK_TTL_SECONDS = 5 * 60; // QR valid for 5 minutes
const key = (t: string) => `linking:${t}`;

// POST /linking/request — { platform:'web', registration_id, identity_public_key(b64), device_name? }
// Unauthenticated: the new device has no session yet. Returns a link_token to render as a QR.
router.post('/request', async (req, res) => {
  const { platform = 'web', registration_id, identity_public_key, device_name } = req.body ?? {};
  if (registration_id == null || !identity_public_key) {
    return res.status(400).json({ error: 'registration_id and identity_public_key required' });
  }
  const link_token = randomBytes(24).toString('base64url');
  await redis.set(
    key(link_token),
    JSON.stringify({ status: 'pending', platform, registration_id, identity_public_key, device_name: device_name ?? 'Web' }),
    'EX', LINK_TTL_SECONDS
  );
  res.json({ link_token, expires_in: LINK_TTL_SECONDS });
});

// POST /linking/approve — { link_token }  (authed by an existing trusted device)
// Registers the pending device under the approving user and mints its session JWT.
router.post('/approve', requireAuth, asyncHandler(async (req, res) => {
  const { user_id } = (req as any).auth;
  const { link_token } = req.body ?? {};
  if (!link_token) return res.status(400).json({ error: 'link_token required' });

  const raw = await redis.get(key(link_token));
  if (!raw) return res.status(404).json({ error: 'link token expired or invalid' });
  const pending = JSON.parse(raw);
  if (pending.status !== 'pending') return res.status(409).json({ error: 'link already used' });

  // Register the companion device under the approving user (public key only).
  const rows = await query<{ id: string }>(
    `insert into devices (user_id, platform, registration_id, identity_public_key, device_name)
       values ($1, $2, $3, $4, $5)
       on conflict (user_id, registration_id)
       do update set identity_public_key = excluded.identity_public_key, revoked_at = null, updated_at = now()
       returning id`,
    [user_id, pending.platform, pending.registration_id, b64(pending.identity_public_key), pending.device_name]
  );
  const device_id = rows[0].id;
  const token = issueToken({ user_id, device_id });

  await redis.set(key(link_token), JSON.stringify({ status: 'approved', user_id, device_id, token }), 'EX', LINK_TTL_SECONDS);

  // Audit: device-linking is a tracked security event (Section 4.9).
  await query(
    `insert into security_events (event_type, user_id, device_id, metadata)
       values ('device_link', $1, $2, $3)`,
    [user_id, device_id, JSON.stringify({ platform: pending.platform })]
  );

  res.json({ approved: true, device_id });
}));

// GET /linking/poll/:link_token — the web device polls until approved, then receives its JWT.
router.get('/poll/:link_token', async (req, res) => {
  const raw = await redis.get(key(req.params.link_token));
  if (!raw) return res.status(404).json({ error: 'link token expired or invalid' });
  const state = JSON.parse(raw);
  if (state.status === 'approved') {
    await redis.del(key(req.params.link_token)); // one-time consumption
    return res.json({ status: 'approved', token: state.token, user_id: state.user_id, device_id: state.device_id });
  }
  res.json({ status: 'pending' });
});

export default router;
