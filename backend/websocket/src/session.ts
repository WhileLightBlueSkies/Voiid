// Connect-time authorization for the relay (S03).
//
// WHY THE RELAY NOW HOLDS A DATABASE HANDLE, HAVING DELIBERATELY NOT HELD ONE.
//
// This process was stateless fan-out over Redis on purpose, and it checked exactly one
// thing at connect: an `auth:revoked:<user>` tombstone the API writes on account deletion.
// That was the right shape for the question it answered, and the wrong shape for this one.
//
// A tombstone is a DENY-LIST held in a cache. Absence means "allowed", so losing the cache —
// a restart, an eviction, a failover — silently re-opens every revoked credential. For
// account deletion that was a narrow, bounded risk. For device revocation it is the whole
// feature: S03 requires that restart or cache loss cannot resurrect a revoked session, and
// no amount of care with a cache-only deny-list can provide that. The authority has to be
// the durable record, which lives in Postgres.
//
// So the cost is paid deliberately and kept small: the pool is created lazily on the first
// socket, capped at a couple of connections, and read ONLY here — one indexed primary-key
// lookup per connect, never per frame. Redis stays in front as a 10-second cache, so the
// steady state is unchanged and the database is consulted on cache misses and revocations.
// Connection budget matters because staging and production are Supabase; two is a rounding
// error against its pooler, and the queries are simple enough for transaction-mode pooling.
import { Pool } from 'pg';
import { resolveDatabaseSsl, describeDatabaseTls } from '@voiid/common-utils';
import jwt from 'jsonwebtoken';

/** Close codes. 4401/4403 mean stop; 4503 means the answer is unknown — retry. */
export const WS_CLOSE_UNAUTHORIZED = 4401;
export const WS_CLOSE_REVOKED = 4403;
export const WS_CLOSE_UNAVAILABLE = 4503;

export type Authorization =
  | { ok: true; userId: string; deviceId?: string; sid?: string; expiresAt: number }
  | { ok: false; code: number; reason: string };

let pool: Pool | null = null;

/**
 * Lazily built, so importing this module never opens a connection — the relay must still
 * boot and serve its health check when the database is unreachable.
 */
export function sessionPool(): Pool {
  if (pool) return pool;
  const url = process.env.DATABASE_URL ?? '';
  // S05: the same verified-TLS policy every other service uses. This pool was added in S03 and
  // copied the unverified form along with everything else.
  const ssl = resolveDatabaseSsl(url);
  console.log(`[voiid:ws] ${describeDatabaseTls(ssl)}`);
  pool = new Pool({
    connectionString: url,
    ssl,
    // Deliberately tiny: this pool answers one question at connect time and nothing else.
    max: Number(process.env.WS_DB_POOL_MAX) || 2,
    idleTimeoutMillis: 30_000,
    // A socket must not hang on a saturated pool. Failing fast surfaces as 4503, which the
    // client retries — far better than a connection that never resolves either way.
    connectionTimeoutMillis: Number(process.env.WS_DB_CONNECT_TIMEOUT_MS) || 5_000,
  });
  // A pool error with no listener is an unhandled 'error' event, which takes the whole
  // relay down — every live socket with it — over a dropped idle connection.
  pool.on('error', (error) => console.error('[voiid:ws] session pool error:', error.message));
  return pool;
}

interface SessionCache {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, mode: 'EX', ttl: number): Promise<unknown>;
}
let cache: SessionCache | null = null;

/** The relay passes its existing Redis connection rather than opening a fourth one. */
export function useSessionCache(client: SessionCache): void {
  cache = client;
}

// Same TTL and same reasoning as the API's session cache: short enough that a revoke on
// another process lands quickly, long enough that the database stays off the hot path.
const SESSION_STATE_TTL_SECONDS = 10;

/** Mirrors backend/api/src/auth.ts. Both services must agree on the migration deadline. */
function sessionCutoffPassed(): boolean {
  const cutoff = process.env.VOIID_SESSION_CUTOFF;
  if (!cutoff) return false;
  const at = Date.parse(cutoff);
  if (Number.isNaN(at)) {
    console.error(`[voiid:ws] VOIID_SESSION_CUTOFF is not a valid date: ${cutoff} — refusing unbound credentials`);
    return true;
  }
  return Date.now() >= at;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Is this connection allowed to attach?
 *
 * Throws only on an unreachable database, which the caller turns into 4503. Every other
 * negative answer is a definite refusal.
 */
async function sessionIsActive(sid: string, userId: string, deviceId: string): Promise<boolean> {
  // Keyed on the whole triple, not the session id: a cached '1' must not be readable by a
  // token that reuses a known sid under a different subject.
  const key = `auth:session:${sid}:${userId}:${deviceId}`;
  try {
    const cached = await cache?.get(key);
    if (cached != null) return cached === '1';
  } catch { /* the database is the authority; a cache outage only costs a round-trip */ }

  const { rows } = await sessionPool().query(
    `select 1 from device_sessions s
       join devices d on d.id = s.device_id
       join users u on u.id = s.user_id
      where s.id = $1 and s.user_id = $2 and s.device_id = $3
        and s.revoked_at is null and d.revoked_at is null and u.deleted_at is null
      limit 1`,
    [sid, userId, deviceId]
  );
  const active = rows.length > 0;
  try { await cache?.set(key, active ? '1' : '0', 'EX', SESSION_STATE_TTL_SECONDS); } catch { /* best effort */ }
  return active;
}

/** A credential with no session: allowed only while the migration window is open. */
async function accountIsLive(userId: string): Promise<boolean> {
  // The account tombstone stays the fast path for this case — it is written on deletion and
  // its absence is checked against the database below, so it cannot fail open any more.
  try {
    if (await cache?.get(`auth:revoked:${userId}`)) return false;
  } catch { /* fall through to the authority */ }
  const { rows } = await sessionPool().query(
    `select 1 from users where id = $1 and deleted_at is null limit 1`,
    [userId]
  );
  return rows.length > 0;
}

export async function authorizeConnection(token: string | null | undefined): Promise<Authorization> {
  let claims: { user_id?: string; device_id?: string; sid?: string; scope?: string; exp?: number };
  try {
    claims = jwt.verify(token ?? '', process.env.JWT_SECRET ?? 'dev-only-change-me') as typeof claims;
  } catch {
    return { ok: false, code: WS_CLOSE_UNAUTHORIZED, reason: 'unauthorized' };
  }
  if (!claims || typeof claims !== 'object' || claims.scope && claims.scope !== 'session' || typeof claims.exp !== 'number' || !Number.isFinite(claims.exp)) {
    return { ok: false, code: WS_CLOSE_UNAUTHORIZED, reason: 'unauthorized' };
  }
  const expiresAt = claims.exp * 1000;
  const userId = claims.user_id;
  if (!userId || !UUID_RE.test(userId)) {
    return { ok: false, code: WS_CLOSE_UNAUTHORIZED, reason: 'unauthorized' };
  }
  if (claims.sid != null && (!UUID_RE.test(claims.sid) || !UUID_RE.test(claims.device_id ?? ''))) {
    return { ok: false, code: WS_CLOSE_UNAUTHORIZED, reason: 'unauthorized' };
  }

  try {
    if (claims.sid) {
      if (!(await sessionIsActive(claims.sid, userId, claims.device_id!))) {
        return { ok: false, code: WS_CLOSE_REVOKED, reason: 'session revoked' };
      }
      return { ok: true, userId, deviceId: claims.device_id, sid: claims.sid, expiresAt };
    }

    if (sessionCutoffPassed()) {
      return { ok: false, code: WS_CLOSE_REVOKED, reason: 'reauthentication required' };
    }
    if (!(await accountIsLive(userId))) {
      return { ok: false, code: WS_CLOSE_REVOKED, reason: 'account deleted' };
    }
    // Legacy, unbound, inside the migration window. Its device is unknown, so a
    // device-targeted sign-out cannot single it out — one more reason to close the window.
    return { ok: true, userId, deviceId: claims.device_id, expiresAt };
  } catch (error) {
    // Unknown, not denied. Signing every user out because a database blipped would be a far
    // worse outage than the one that caused it, and the API still fails closed on its side.
    console.error('[voiid:ws] session check failed:', (error as Error).message);
    return { ok: false, code: WS_CLOSE_UNAVAILABLE, reason: 'service unavailable' };
  }
}
