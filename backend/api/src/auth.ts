// OUR auth layer (Section 2.2 boundary): Firebase only sends OTP; identity + JWT are ours.
import jwt from 'jsonwebtoken';
import type { Request, Response, NextFunction } from 'express';
import { query } from './db';
import { redis } from './redis';

const JWT_SECRET = process.env.JWT_SECRET ?? 'dev-only-change-me';
const JWT_EXPIRY = process.env.JWT_EXPIRY ?? '30d';

export interface AuthClaims {
  user_id: string;
  device_id?: string;
}

export function issueToken(claims: AuthClaims): string {
  return jwt.sign(claims, JWT_SECRET, { expiresIn: JWT_EXPIRY } as jwt.SignOptions);
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
  try {
    await redis.set(`auth:revoked:${user_id}`, '1', 'EX', REVOCATION_TTL_SECONDS);
    // Live sockets are not covered by a connect-time check. The relay listens on each user's
    // channel and closes on this frame, so a deletion also ends sessions already open.
    await redis.publish(`channel:user:${user_id}`, JSON.stringify({ type: 'force_signout', reason: 'account_deleted' }));
  } catch { /* best effort: the connect-time check still applies to any new socket */ }
}

// Express middleware — rejects unauthenticated requests (Section 4.6: no unprotected endpoints).
export async function requireAuth(req: Request, res: Response, next: NextFunction) {
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

  try {
    if (!(await accountIsActive(claims.user_id))) {
      return res.status(401).json({ error: 'account deleted' });
    }
  } catch {
    // The DB is unreachable. Every route behind this middleware needs it too, so a 503 is
    // the honest answer — and guessing "active" here would reopen the hole this closes.
    return res.status(503).json({ error: 'service unavailable' });
  }

  (req as any).auth = claims;
  next();
}
