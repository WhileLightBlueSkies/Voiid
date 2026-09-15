import { recordUsage } from './usageAnalytics';
// OUR auth layer (Section 2.2 boundary): Firebase only sends OTP; identity + JWT are ours.
import jwt from 'jsonwebtoken';
import type { Request, Response, NextFunction } from 'express';
import { query } from './db';
import { redis } from './redis';
import { companionAllows } from './webCompanion';

const JWT_SECRET = process.env.JWT_SECRET ?? 'dev-only-change-me';
const JWT_EXPIRY = process.env.JWT_EXPIRY ?? '30d';

/**
 * A bootstrap credential exists to do ONE thing: register a device and trade itself for a
 * session. It is minted by OTP alone and is not bound to any device, so it is the weakest
 * credential we issue — hours, not the 30 days a device-bound session gets.
 */
const JWT_BOOTSTRAP_EXPIRY = process.env.JWT_BOOTSTRAP_EXPIRY ?? '1h';

/**
 * 'bootstrap' — proved a phone number, owns no device yet.
 * 'session'   — bound to a `device_sessions` row (`sid`) and its device.
 * absent      — a token minted before S03: user-only, unbound, unrevocable. Accepted until
 *               the cutoff below and never after.
 */
export type TokenScope = 'bootstrap' | 'session';

export interface AuthClaims {
  client?: 'web';
  user_id: string;
  device_id?: string;
  /** device_sessions.id — the row a revoke can invalidate. Session tokens only. */
  sid?: string;
  scope?: TokenScope;
}

export function issueToken(claims: AuthClaims): string {
  return jwt.sign(claims, JWT_SECRET, { expiresIn: JWT_EXPIRY } as jwt.SignOptions);
}

/** OTP succeeded; no device is registered yet. Only the registration routes accept this. */
export function issueBootstrapToken(user_id: string): string {
  return jwt.sign({ user_id, scope: 'bootstrap' }, JWT_SECRET, {
    expiresIn: JWT_BOOTSTRAP_EXPIRY,
  } as jwt.SignOptions);
}

/**
 * THE MIGRATION LEVER, and the one knob that closes S03's compatibility hole.
 *
 * Every install in the field holds a user-only JWT valid for up to 30 days, and a client
 * that re-runs OTP after this ships holds a bootstrap token it does not yet know to trade
 * in. Refusing both on day one signs out the entire user base. So a credential with no
 * session keeps working until this timestamp and is refused from then on — after which the
 * only accepted credential on the messaging surface is one bound to a live device session.
 *
 * Unset means the window is open (the deploy default). Set it to an ISO-8601 instant at
 * least one JWT_EXPIRY after the release that ships the session-aware clients, so every
 * install has had a full token lifetime to re-register before its credential stops working.
 */
function sessionCutoffPassed(): boolean {
  const cutoff = process.env.VOIID_SESSION_CUTOFF;
  if (!cutoff) return false;
  const at = Date.parse(cutoff);
  // An unparseable cutoff must not silently mean "no cutoff" — that would turn a typo in
  // the deploy env into a permanently open compatibility window nobody notices.
  if (Number.isNaN(at)) {
    console.error(`[auth] VOIID_SESSION_CUTOFF is not a valid date: ${cutoff} — refusing unbound credentials`);
    return true;
  }
  return Date.now() >= at;
}

export function verifyToken(token: string): AuthClaims {
  return jwt.verify(token, JWT_SECRET) as AuthClaims;
}

/**
 * Short — the window a just-deleted account keeps working, traded against a DB round-trip
 * on every authenticated request. Seconds, not minutes: `DELETE /users/me` clears the key
 * outright, so this only bounds the case where the delete happened on another process.
 */
const ACCOUNT_STATE_TTL_SECONDS = 10;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Is this user id still a live account?
 *
 * A JWT proves only that we minted it. With a 30-day expiry and no server-side session,
 * signature-checking alone means a deleted user keeps full API access — posting clips,
 * relaying ciphertext — for up to a month, against a row every read path already filters
 * out. So identity is re-checked here, cached in Redis to keep it off the hot path.
 *
 * Fails CLOSED on a deleted user and OPEN on a Redis outage: losing the cache must not
 * lock every user out of the app, and the DB remains the authority either way.
 */
async function accountIsActive(user_id: string): Promise<boolean> {
  const key = `auth:active:${user_id}`;
  try {
    const cached = await redis.get(key);
    if (cached != null) return cached === '1';
  } catch { /* cache miss by another name — fall through to the DB */ }

  const rows = await query<{ ok: boolean }>(
    `select (deleted_at is null) as ok from users where id = $1`,
    [user_id]
  );
  // No row: the erasure job has purged the account, or the token names a user that never
  // existed. Either way it is not a live identity.
  const active = rows[0]?.ok === true;
  try { await redis.set(key, active ? '1' : '0', 'EX', ACCOUNT_STATE_TTL_SECONDS); } catch { /* best effort */ }
  return active;
}

/** Drop the cached verdict so a deletion takes effect on the next request, not in 10s. */
export async function invalidateAccountState(user_id: string): Promise<void> {
  try { await redis.del(`auth:active:${user_id}`); } catch { /* TTL will expire it anyway */ }
}

/**
 * How long a revocation tombstone outlives the account. Sized to the JWT ceiling: the token
 * a deleted user is holding cannot outlive its own expiry, so a marker that lasts as long as
 * the longest possible token covers every token that could still be presented.
 */
const REVOCATION_TTL_SECONDS = 30 * 24 * 60 * 60;

/**
 * Mark an account revoked for every service, not just this one.
 *
 * THE WEBSOCKET RELAY IS THE REASON THIS EXISTS. It carries the messages, calls and
 * locations, and it holds no database connection by design — it is stateless fan-out over
 * Redis. So it cannot run `accountIsActive` itself, and a deleted user's token kept opening
 * sockets on the service that actually moves the traffic.
 *
 * A tombstone rather than reusing `auth:active:<id>`: that key has a 10-SECOND TTL, so
 * ABSENT is its normal state and a relay that denied on absence would lock out every user
 * within ten seconds. Presence of THIS key is unambiguous — it is written only by deletion —
 * so the relay can fail closed on it and open on everything else.
 */
export async function revokeAccountSessions(user_id: string): Promise<void> {
  // Close the durable side first. The tombstone below is a cache and can be lost; these rows
  // cannot, so a Redis flush during an account deletion cannot hand the sessions back.
  try {
    await query(
      `update device_sessions set revoked_at = now(), revoked_reason = 'account_deleted'
        where user_id = $1 and revoked_at is null`,
      [user_id]
    );
  } catch { /* the account row itself is already gone, and accountIsActive fails closed on it */ }
  try {
    await redis.set(`auth:revoked:${user_id}`, '1', 'EX', REVOCATION_TTL_SECONDS);
    // Live sockets are not covered by a connect-time check. The relay listens on each user's
    // channel and closes on this frame, so a deletion also ends sessions already open.
    await redis.publish(`channel:user:${user_id}`, JSON.stringify({ type: 'force_signout', reason: 'account_deleted' }));
  } catch { /* best effort: the connect-time check still applies to any new socket */ }
}

/**
 * Same shape and reasoning as `accountIsActive`, one level finer: is this SESSION still
 * good? Cached briefly, authoritative in Postgres.
 *
 * The cache key carries the user and device as well as the session id, because the verdict
 * is about the triple. A key on `sid` alone would let a token that reuses a known session
 * id under a different subject read a '1' written for the real owner.
 */
const SESSION_STATE_TTL_SECONDS = 10;
const sessionKey = (sid: string, userId: string, deviceId: string) =>
  `auth:session:${sid}:${userId}:${deviceId}`;

async function sessionIsActive(sid: string, userId: string, deviceId: string): Promise<boolean> {
  const key = sessionKey(sid, userId, deviceId);
  try {
    const cached = await redis.get(key);
    if (cached != null) return cached === '1';
  } catch { /* cache miss by another name — the database is the authority */ }

  // The device is joined in rather than checked separately so that revoking the DEVICE
  // (linked-devices screen, superseded by a reinstall) ends its sessions without having to
  // find and rewrite every session row first.
  const rows = await query<{ one: number }>(
    `select 1 as one from device_sessions s
       join devices d on d.id = s.device_id
      where s.id = $1 and s.user_id = $2 and s.device_id = $3
        and s.revoked_at is null and d.revoked_at is null
      limit 1`,
    [sid, userId, deviceId]
  );
  const active = rows.length > 0;
  try { await redis.set(key, active ? '1' : '0', 'EX', SESSION_STATE_TTL_SECONDS); } catch { /* best effort */ }
  return active;
}

/**
 * Mint a session for a freshly registered device and return the token that names it.
 *
 * Takes an executor so the caller can create the session inside the same transaction as the
 * device row: a session pointing at a device that rolled back would authorize nothing, and
 * a device with no session would leave the client holding a token it cannot use.
 */
export async function createDeviceSession(
  user_id: string,
  device_id: string,
  execute: typeof query = query,
  client?: 'web'
): Promise<{ sid: string; token: string }> {
  const rows = await execute<{ id: string }>(
    `insert into device_sessions (user_id, device_id) values ($1, $2) returning id`,
    [user_id, device_id]
  );
  const sid = rows[0].id;
  return { sid, token: issueToken({ user_id, device_id, sid, scope: 'session', ...(client ? { client } : {}) }) };
}

/**
 * End every live session on these devices, and tell any socket they hold to go.
 *
 * `reason` is recorded on the session row and relayed in the sign-out frame so a client can
 * tell "you revoked this device" from "another install replaced it" and show the right
 * screen. Device-row revocation stays with the caller (each writer already owns that
 * statement); this closes the credential side.
 *
 * Cache invalidation is bounded twice over: the tombstone is written straight over the
 * cached verdict here, and every cached '1' expires within SESSION_STATE_TTL_SECONDS
 * anyway, so a revoke issued on another process still lands within that window.
 */
export async function revokeDeviceSessions(
  device_ids: string[],
  reason: string,
  execute: typeof query = query
): Promise<void> {
  if (!device_ids.length) return;
  const revoked = await execute<{ id: string; user_id: string; device_id: string }>(
    `update device_sessions set revoked_at = now(), revoked_reason = $2
      where device_id = any($1::uuid[]) and revoked_at is null
      returning id, user_id, device_id`,
    [device_ids, reason]
  );
  for (const session of revoked) {
    try {
      await redis.set(
        sessionKey(session.id, session.user_id, session.device_id),
        '0', 'EX', REVOCATION_TTL_SECONDS
      );
      // The relay closes only the sockets belonging to THIS device — a second linked
      // device must not be signed out by its sibling's revocation.
      await redis.publish(
        `channel:user:${session.user_id}`,
        JSON.stringify({ type: 'force_signout', reason, device_id: session.device_id })
      );
    } catch { /* best effort: the database record already refuses the next request */ }
  }
}

// Express middleware — rejects unauthenticated requests (Section 4.6: no unprotected endpoints).
//
// `allowUnbound` is for the registration routes ONLY. They are the sole way to obtain a
// session, so requiring one there would strand every client on the wrong side of the
// cutoff below with no route back.
function authenticate(allowUnbound: boolean) {
  return async function requireAuthMiddleware(req: Request, res: Response, next: NextFunction) {
    const header = req.headers.authorization;
    if (!header?.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'missing bearer token' });
    }
    let claims: AuthClaims;
    try {
      claims = verifyToken(header.slice(7));
    } catch {
      return res.status(401).json({ error: 'invalid token' });
    }

    // A signed token whose subject is not a uuid can never match a row, and feeding it to
    // Postgres would raise a cast error that the catch below would report as an outage.
    if (!UUID_RE.test(claims.user_id ?? '')) {
      return res.status(401).json({ error: 'invalid token' });
    }
    if (claims.sid != null && (!UUID_RE.test(claims.sid) || !UUID_RE.test(claims.device_id ?? ''))) {
      return res.status(401).json({ error: 'invalid token' });
    }

    try {
      if (!(await accountIsActive(claims.user_id))) {
        return res.status(401).json({ error: 'account deleted' });
      }

      if (claims.sid) {
        // A device-bound credential is checked against its row on every request, cutoff or
        // not. This is the whole point of S03: revocation has somewhere to be written down.
        if (!(await sessionIsActive(claims.sid, claims.user_id, claims.device_id!))) {
          return res.status(401).json({ error: 'session revoked', code: 'session_revoked' });
        }
      } else if (!allowUnbound && sessionCutoffPassed()) {
        // No session: either a pre-S03 user-only token or a bootstrap credential that was
        // never traded in. Distinguished only so the client knows what to do about it —
        // finish registering, or run the OTP flow again.
        return claims.scope === 'bootstrap'
          ? res.status(401).json({ error: 'device session required', code: 'device_session_required' })
          : res.status(401).json({ error: 'reauthentication required', code: 'reauthentication_required' });
      }
    } catch {
      // The DB is unreachable. Every route behind this middleware needs it too, so a 503 is
      // the honest answer — and guessing "active" here would reopen the hole this closes.
      return res.status(503).json({ error: 'service unavailable' });
    }

    if (claims.client === 'web') {
      const routePath = req.originalUrl.split('?')[0].replace(/^\/v1(?=\/)/, '').replace(/\/$/, '');
      if (!claims.sid || !claims.device_id || !companionAllows(req.method, routePath, claims.device_id, req.body)) {
        return res.status(403).json({ error: 'operation unavailable to a web companion', code: 'companion_scope' });
      }
    }

    if (!allowUnbound && claims.sid && claims.device_id) void recordUsage(claims.user_id, claims.device_id);
    (req as any).auth = claims;
    next();
  };
}

export const requireAuth = authenticate(false);

/** Registration routes: accept a bootstrap credential, since that is what they exist to spend. */
export const requireAuthForRegistration = authenticate(true);
