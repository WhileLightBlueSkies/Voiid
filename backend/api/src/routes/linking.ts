// Device linking (Section 4.3) — QR-based linking for the WEB COMPANION device (WhatsApp-Web style).
// Web is a linked companion (messaging only; no calls). Linking requires explicit approval from an
// existing trusted device. The new device's private keys are generated on-device and never sent here.
//
// Flow:
//   1. New web device calls POST /linking/request  -> gets { link_token } (encode in a QR).
//   2. A logged-in device scans the QR and calls POST /linking/approve { link_token } (authed).
//      The server registers the new device under THAT user and mints its session, atomically.
//   3. The web device polls GET /linking/poll/:link_token until it receives its { token, ... }.
//
// ── WHY THE STATE IS IN POSTGRES AND NOT REDIS (S06) ─────────────────────────────
//
// It used to be one JSON blob in Redis, and every transition was read-modify-write across
// three round trips. Neither approve nor poll was atomic, and both are reachable concurrently
// by design — the QR is on a screen, and the approving phone and the waiting browser are
// different clients:
//
//   * Two accounts approving at once both read "pending" and both registered a device. One
//     ended up holding a device row nobody would ever use, and which account the browser was
//     handed came down to whichever write landed last.
//   * Two polls both read "approved" before either deleted the key, and the session credential
//     was handed out twice.
//   * A crash between the device insert and the cache write left a registered device and a
//     token stuck on "pending" — the browser polled forever.
//   * A Redis restart lost every link in flight.
//
// A row and `for update` fixes all four in one move, and collapses the pending -> approving ->
// approved -> consumed machine into two states: the transaction that approves does the device,
// the session and the state change together, so there is no half-way to be stuck in.
import { Router } from 'express';
import { randomBytes, createHash, timingSafeEqual } from 'crypto';
import { redis } from '../redis';
import { rateLimit } from '../security';
import { query, withTransaction } from '../db';
import { requireAuth, createDeviceSession } from '../auth';
import { b64, asyncHandler } from '../util';

const router = Router();
router.use((_req, res, next) => { res.setHeader('Cache-Control', 'no-store'); res.setHeader('Referrer-Policy', 'no-referrer'); next(); });
const proofHash = (secret: string) => createHash('sha256').update(secret).digest();
// Roll out the migration and both services before admitting any companion sessions.
router.use((req, res, next) => {
  if (req.path !== '/socket-ticket' && process.env.VOIID_WEB_LINKING_ENABLED !== '1') {
    return res.status(503).json({ error: 'Browser linking is not enabled yet.', code: 'web_linking_unavailable' });
  }
  next();
});


const LINK_TTL_SECONDS = 5 * 60; // QR valid for 5 minutes

// POST /linking/request — { platform:'web', registration_id, identity_public_key(b64), device_name? }
// Unauthenticated: the new device has no session yet. Returns a link_token to render as a QR.
router.post('/request', rateLimit({ max: 10, windowSeconds: 300, bucket: 'web-link-request', outage: 'closed' }), asyncHandler(async (req, res) => {
  const { platform = 'web', registration_id, identity_public_key, device_name } = req.body ?? {};
  if (platform !== 'web' || !Number.isInteger(registration_id) || registration_id < 1 || registration_id > 2147483647 ||
      typeof identity_public_key !== 'string' || !/^[A-Za-z0-9+/]{43}=?$/.test(identity_public_key) || Buffer.from(identity_public_key, 'base64').length !== 32 ||
      (device_name != null && (typeof device_name !== 'string' || device_name.length > 80 || /[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]/.test(device_name)))) {
    return res.status(400).json({ error: 'registration_id and identity_public_key required' });
  }
  const link_token = randomBytes(24).toString('base64url');
  const poll_secret = randomBytes(32).toString('base64url');
  await query(
    `insert into device_link_requests
       (token, platform, registration_id, identity_public_key, device_name, expires_at, poll_secret_hash)
     values ($1, $2, $3, $4, $5, now() + make_interval(secs => $6), $7)`,
    [link_token, platform, registration_id, b64(identity_public_key), device_name ?? 'Web', LINK_TTL_SECONDS, proofHash(poll_secret)]
  );
  res.json({ link_token, poll_secret, expires_in: LINK_TTL_SECONDS });
}));

// Preview never grants access. Only the signed-in phone may inspect the request.
router.post('/preview', requireAuth, rateLimit({ max: 30, windowSeconds: 300, bucket: 'web-link-preview', outage: 'closed' }), asyncHandler(async (req, res) => {
  const { user_id, device_id } = (req as any).auth;
  const trusted = await query(`select id from devices where id = $1 and user_id = $2 and platform in ('ios', 'android') and revoked_at is null`, [device_id ?? null, user_id]);
  if (!trusted.length) return res.status(403).json({ error: 'approve from a trusted phone' });
  const { link_token } = req.body ?? {};
  if (typeof link_token !== 'string' || !/^[A-Za-z0-9_-]{32}$/.test(link_token)) return res.status(400).json({ error: 'invalid link code' });
  const [pending] = await query<{ device_name: string; identity_public_key: Buffer; expires_at: Date }>(
    `select device_name, identity_public_key, expires_at from device_link_requests
      where token = $1 and status = 'pending' and platform = 'web' and expires_at > now() and poll_secret_hash is not null`, [link_token]);
  if (!pending) return res.status(404).json({ error: 'link token expired or invalid' });
  const code = createHash('sha256').update(pending.identity_public_key).digest('hex').slice(0, 12).toUpperCase();
  res.json({ device_name: pending.device_name || 'Web browser', platform: 'web',
    identity_public_key: pending.identity_public_key.toString('base64'), verification_code: code.match(/.{4}/g)!.join(' '), expires_at: pending.expires_at });
}));

// POST /linking/approve — { link_token }  (authed by an existing trusted device)
//
// ONE TRANSACTION. The row is locked first, so a second approval — from this account or any
// other — waits and then finds the request already approved. The device, its session and the
// state change commit together, so a failure anywhere leaves the request approvable rather
// than leaving a registered device attached to nothing.
router.post('/approve', requireAuth, asyncHandler(async (req, res) => {
  const { user_id, device_id: approverDeviceId } = (req as any).auth;
  const { link_token, identity_public_key } = req.body ?? {};
  if (typeof link_token !== 'string' || !link_token) {
    return res.status(400).json({ error: 'link_token required' });
  }

  const result = await withTransaction<{ status: number; body: any }>(async (execute) => {
    // Hold the phone row through approval so revocation cannot race the trust check.
    const trusted = await execute(`select id from devices where id = $1 and user_id = $2 and platform in ('ios', 'android') and revoked_at is null for share`, [approverDeviceId ?? null, user_id]);
    if (!trusted.length) return { status: 403, body: { error: 'approve from a trusted phone' } };
    const pending = (
      await execute<{
        status: string; platform: string; registration_id: number;
        identity_public_key: Buffer; device_name: string | null;
      }>(
        `select status, platform, registration_id, identity_public_key, device_name
           from device_link_requests
          where token = $1 and expires_at > now() and poll_secret_hash is not null
          for update`,
        [link_token]
      )
    )[0];

    // 404 for expired and unknown alike: whether a token ever existed is not something an
    // unauthenticated guesser should be able to learn.
    if (!pending) return { status: 404, body: { error: 'link token expired or invalid' } };
    if (pending.status !== 'pending') return { status: 409, body: { error: 'link already used' } };

    if (pending.platform !== 'web' || typeof identity_public_key !== 'string' ||
        identity_public_key !== pending.identity_public_key.toString('base64')) {
      return { status: 409, body: { error: 'preview this browser before approving it' } };
    }

    // Register the companion device under the approving user (public key only).
    const rows = await execute<{ id: string }>(
      `insert into devices (user_id, platform, registration_id, identity_public_key, device_name)
         values ($1, $2, $3, $4, $5)
         on conflict (user_id, registration_id) do nothing
         returning id`,
      [user_id, pending.platform, pending.registration_id, pending.identity_public_key, pending.device_name]
    );
    if (!rows.length) return { status: 409, body: { error: 'registration collision; create a new link' } };
    const device_id = rows[0].id;

    // A linked companion gets a real session row like any other device, so the
    // linked-devices screen can revoke it and have that mean something.
    const { token } = await createDeviceSession(user_id, device_id, execute, 'web');

    await execute(
      `update device_link_requests
          set status = 'approved', approved_by = $2, device_id = $3, session_token = $4
        where token = $1`,
      [link_token, user_id, device_id, token]
    );

    // Audit: device-linking is a tracked security event (Section 4.9). Inside the transaction
    // deliberately — an audit line for a link that rolled back is worse than none.
    await execute(
      `insert into security_events (event_type, user_id, device_id, metadata)
         values ('device_link', $1, $2, $3)`,
      [user_id, device_id, JSON.stringify({ platform: pending.platform })]
    );

    return { status: 200, body: { approved: true, device_id } };
  });

  res.status(result.status).json(result.body);
}));

// GET /linking/poll/:link_token — the web device polls until approved, then receives its JWT.
//
// The row is locked and DELETED in the same transaction that reads the credential out of it,
// so exactly one poll can ever collect it. Read-check-delete over three round trips could hand
// the same session to two callers — a duplicate tab, a retry, or anyone who learned the token.
router.get('/poll/:link_token', asyncHandler(async (req, res) => {
  const secret = req.get('X-Link-Proof');
  if (!secret || !/^[A-Za-z0-9_-]{43}$/.test(secret)) return res.status(404).json({ error: 'link token expired or invalid' });
  const result = await withTransaction<{ status: number; body: any }>(async (execute) => {
    const row = (
      await execute<{ status: string; approved_by: string; device_id: string; session_token: string; poll_secret_hash: Buffer | null }>(
        `select status, approved_by, device_id, session_token, poll_secret_hash
           from device_link_requests
          where token = $1 and expires_at > now()
          for update`,
        [req.params.link_token]
      )
    )[0];

    if (!row || !row.poll_secret_hash || !timingSafeEqual(row.poll_secret_hash, proofHash(secret))) return { status: 404, body: { error: 'link token expired or invalid' } };
    if (row.status !== 'approved') return { status: 200, body: { status: 'pending' } };

    // One-time consumption. Deleting rather than marking consumed also takes the credential
    // out of the database the moment it is no longer needed.
    await execute(`delete from device_link_requests where token = $1`, [req.params.link_token]);
    return {
      status: 200,
      body: {
        status: 'approved',
        token: row.session_token,
        user_id: row.approved_by,
        device_id: row.device_id,
      },
    };
  });

  res.status(result.status).json(result.body);
}));

router.post('/socket-ticket', requireAuth, asyncHandler(async (req, res) => {
  const claims = (req as any).auth;
  if (claims.client !== 'web' || !claims.sid) return res.status(403).json({ error: 'web session required' });
  const ticket = randomBytes(32).toString('base64url');
  await redis.set(`web:socket-ticket:${ticket}`, req.get('Authorization')!.slice(7), 'EX', 20);
  res.json({ ticket, expires_in: 20 });
}));

export default router;
