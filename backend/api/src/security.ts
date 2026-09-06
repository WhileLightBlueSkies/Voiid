// Security monitoring + abuse protection (Section 4.9).
import type { Request, Response, NextFunction } from 'express';
import { query } from './db';
import { redis } from './redis';

/**
 * The caller's address, as resolved by Express against `trust proxy` (set in index.ts).
 *
 * Never parse x-forwarded-for by hand: the header is client-supplied and Express is the
 * only thing here that knows which hops are ours. Returns null rather than a placeholder
 * so an unknown address is stored as SQL NULL instead of a string that looks like data.
 */
export function clientIp(req: Request): string | null {
  return req.ip || req.socket?.remoteAddress || null;
}

type SecurityEventType =
  | 'failed_login' | 'otp_abuse' | 'api_abuse'
  | 'device_link' | 'suspicious_session' | 'anomalous_traffic'
  // Who signed a device out, and how — the counterpart to 'device_link'. Without it a
  // revocation leaves no trail, so "why did my other phone stop working" is unanswerable.
  | 'device_revoked';

/** Record a security event (stored separately from app data, Section 4.9). Best-effort: never throws. */
export async function logSecurityEvent(
  event_type: SecurityEventType,
  data: { user_id?: string; device_id?: string; phone_number?: string; ip_address?: string; metadata?: unknown } = {}
): Promise<void> {
  try {
    await query(
      `insert into security_events (event_type, user_id, device_id, phone_number, ip_address, metadata)
         values ($1, $2, $3, $4, $5, $6)`,
      [event_type, data.user_id ?? null, data.device_id ?? null, data.phone_number ?? null,
       data.ip_address ?? null, data.metadata ? JSON.stringify(data.metadata) : null]
    );
  } catch { /* monitoring must never break the request path */ }
}

/** Atomic fixed window, starting at the first request. Repair a legacy key without TTL. */
export const RATE_LIMIT_SCRIPT = `
local count = redis.call('INCR', KEYS[1])
local ttl = redis.call('PTTL', KEYS[1])
if ttl < 0 then
  redis.call('PEXPIRE', KEYS[1], ARGV[1])
  ttl = tonumber(ARGV[1])
end
return {count, ttl}
`;

// Only configured bucket names appear here; never account IDs, addresses or targets.
export const rateLimitMetrics = { rejected: 0, unavailable: 0 };
type LimitOptions = { max: number; windowSeconds: number; bucket: string; outage?: 'open' | 'closed' };
const sensitiveBuckets = new Set(['auth', 'admin-login', 'recovery', 'reachability', 'keyfetch']);

async function countWindow(key: string, windowSeconds: number): Promise<{ count: number; retryAfter: number }> {
  const result = await redis.eval(RATE_LIMIT_SCRIPT, 1, key, windowSeconds * 1000) as [number, number];
  if (!Array.isArray(result) || !Number.isFinite(Number(result[0])) || !Number.isFinite(Number(result[1]))) {
    throw new Error('invalid limiter response');
  }
  return { count: Number(result[0]), retryAfter: Math.max(1, Math.ceil(Number(result[1]) / 1000)) };
}

/** General traffic fails open on cache outage; credential and key-depletion guards fail closed.
 * Redis command deadlines and its disabled offline queue bound either outcome (redis.ts).
 * Rejections update counters only: a flood must not become a database-write flood.
 */
export function rateLimit(opts: LimitOptions) {
  return async (req: Request, res: Response, next: NextFunction) => {
    const userId = (req as any).auth?.user_id as string | undefined;
    const subject = userId ? `u:${userId}` : `ip:${clientIp(req) ?? 'unknown'}`;
    try {
      const { count, retryAfter } = await countWindow(`ratelimit:${opts.bucket}:${subject}`, opts.windowSeconds);
      if (count > opts.max) {
        rateLimitMetrics.rejected++;
        res.setHeader('Retry-After', String(retryAfter));
        return res.status(429).json({ error: 'rate limit exceeded', code: 'rate_limited' });
      }
    } catch {
      rateLimitMetrics.unavailable++;
      if (opts.outage === 'closed' || (opts.outage !== 'open' && sensitiveBuckets.has(opts.bucket))) {
        res.setHeader('Retry-After', '2');
        return res.status(503).json({ error: 'temporarily unavailable', code: 'rate_limit_unavailable' });
      }
    }
    next();
  };
}

/** Pair limits protect one-time key material and deliberately fail closed. */
export async function checkPairRateLimit(opts: LimitOptions & { callerId: string; targetId: string }): Promise<boolean> {
  try {
    const { count } = await countWindow(`ratelimit:${opts.bucket}:${opts.callerId}:${opts.targetId}`, opts.windowSeconds);
    if (count > opts.max) { rateLimitMetrics.rejected++; return false; }
    return true;
  } catch { rateLimitMetrics.unavailable++; return false; }
}

export function pairRateLimit(opts: LimitOptions & { callerId: string; targetId: string }) {
  return async (_req: Request, res: Response, next: NextFunction) => {
    try {
      const { count, retryAfter } = await countWindow(`ratelimit:${opts.bucket}:${opts.callerId}:${opts.targetId}`, opts.windowSeconds);
      if (count > opts.max) {
        rateLimitMetrics.rejected++;
        res.setHeader('Retry-After', String(retryAfter));
        return res.status(429).json({ error: 'rate limit exceeded', code: 'rate_limited' });
      }
      next();
    } catch {
      rateLimitMetrics.unavailable++;
      res.setHeader('Retry-After', '2');
      return res.status(503).json({ error: 'temporarily unavailable', code: 'rate_limit_unavailable' });
    }
  };
}

/**
 * True when the TARGET has blocked the CALLER (043 user_blocks).
 *
 * Used by the prekey/KeyPackage fetch endpoints: a blocked caller must not be
 * able to consume the target's one-time material — or even keep establishing
 * sessions to it. Callers of this helper decide the response SHAPE; they should
 * answer with their normal empty result (never a distinct status), so blocking
 * does not become an oracle for "this user exists and rejected you".
 */
export async function blockedBetween(callerId: string, targetId: string): Promise<boolean> {
  const rows = await query<{ one: number }>(
    `select 1 as one from user_blocks
       where blocker_user_id = $1 and blocked_user_id = $2
       limit 1`,
    [targetId, callerId]
  );
  return rows.length > 0;
}

/**
 * Guard for the two one-time-material fetch endpoints — GET /prekeys/:user_id and
 * GET /mls/keypackages/:user_id. Each call CONSUMES the target's supply, so both
 * endpoints share this exact policy:
 *
 *   self        → always allowed (a device replenishing its own view)
 *   blocked     → 'empty': the caller gets the endpoint's normal no-material shape,
 *                 never a distinct status. Blocking must not become an oracle
 *                 (043_user_blocks.sql: "Silence is the point") and a blocked caller
 *                 must not keep burning keys.
 *   everyone    → per-(caller, target) pair throttle. The global limiter caps per-IP
 *                 traffic; it does nothing against a drain loop spread across IPs,
 *                 which is exactly how you exhaust a victim's one-time prekeys or
 *                 KeyPackages and deny all their new inbound sessions and group invites.
 *
 * Returns 'ok' to proceed, 'empty' to answer with the route's empty shape, 'limited'
 * to answer 429. The ROUTE owns its response shape; security.ts only decides which one.
 */
export async function guardKeyMaterialFetch(
  callerId: string,
  targetUserId: string
): Promise<'ok' | 'empty' | 'limited'> {
  if (callerId === targetUserId) return 'ok';
  if (await blockedBetween(callerId, targetUserId)) return 'empty';
  const allowed = await checkPairRateLimit({
    max: 5,
    windowSeconds: 60,
    bucket: 'keyfetch',
    callerId,
    targetId: targetUserId,
  });
  return allowed ? 'ok' : 'limited';
}
