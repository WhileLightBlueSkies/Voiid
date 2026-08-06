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
