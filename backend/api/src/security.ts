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
  | 'device_link' | 'suspicious_session' | 'anomalous_traffic';

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

/**
 * Sliding-window rate-limit middleware keyed by client IP (Section 4.6/4.9).
 * Per-phone OTP limiting lives in the auth route; this guards general API abuse.
 */
export function rateLimit(opts: { max: number; windowSeconds: number; bucket: string }) {
  return async (req: Request, res: Response, next: NextFunction) => {
    // req.ip, not a hand-parsed x-forwarded-for: Express resolves it against the app's
    // `trust proxy` setting (index.ts), so a client that reaches the port directly cannot
    // hand itself a fresh bucket — or push someone else's address over the limit.
    const ip = clientIp(req) ?? 'unknown';
    const key = `ratelimit:${opts.bucket}:${ip}`;
    try {
      const count = await redis.incr(key);
      if (count === 1) await redis.expire(key, opts.windowSeconds);
      if (count > opts.max) {
        await logSecurityEvent('api_abuse', { ip_address: ip, metadata: { bucket: opts.bucket, count } });
        return res.status(429).json({ error: 'rate limit exceeded' });
      }
    } catch { /* if Redis is down, fail open rather than block all traffic */ }
    next();
  };
}

/**
 * The counting core of the pair limit, callable outside middleware chains.
 * Returns false when the call should be rejected (limit exceeded).
 */
export async function checkPairRateLimit(opts: {
  max: number;
  windowSeconds: number;
  bucket: string;
  callerId: string;
  targetId: string;
}): Promise<boolean> {
  const key = `ratelimit:${opts.bucket}:${opts.callerId}:${opts.targetId}`;
  try {
    const count = await redis.incr(key);
    if (count === 1) await redis.expire(key, opts.windowSeconds);
    if (count > opts.max) {
      await logSecurityEvent('api_abuse', {
        user_id: opts.callerId,
        metadata: { bucket: opts.bucket, target: opts.targetId, count },
      });
      return false;
    }
  } catch { /* fail open, same policy as rateLimit above */ }
  return true;
}

/**
 * Sliding-window rate limit keyed by a (caller, target) PAIR rather than an IP.
 *
 * Why this exists: GET /prekeys/:user_id and GET /mls/keypackages/:user_id
 * CONSUME one-time material on every call, so the abuse is not "one IP hammers
 * the API" (the global limiter already caps that) but "one authenticated caller
 * drains one specific victim's supply" — trivially spread across IPs. The
 * bucket has to be the pair.
 */
export function pairRateLimit(opts: {
  max: number;
  windowSeconds: number;
  bucket: string;
  callerId: string;
  targetId: string;
}) {
  return async (_req: Request, res: Response, next: NextFunction) => {
    if (!(await checkPairRateLimit(opts))) {
      return res.status(429).json({ error: 'rate limit exceeded' });
    }
    next();
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
