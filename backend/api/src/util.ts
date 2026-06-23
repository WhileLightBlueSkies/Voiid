// Small shared helpers for the API routes.
import type { Request, Response, NextFunction, RequestHandler } from 'express';

/**
 * Decode client-supplied base64 into a Buffer for binding as Postgres `bytea`.
 *
 * Use this INSTEAD of SQL `decode($n,'base64')`. Postgres' decoder requires
 * canonical, padded standard base64 and throws `invalid base64 end sequence`
 * on the UNPADDED standard base64 that our clients (vodozemac) emit — which,
 * because the route handlers don't catch it, left the HTTP request hanging
 * until the client's socket timeout (every device register / prekey upload).
 *
 * Node's Buffer base64 decoder is lenient: it tolerates missing padding, and we
 * additionally normalize the base64url alphabet (`-`/`_`) so either encoding
 * works. Returns null for null/undefined so optional columns stay NULL.
 */
export function b64(value: string | null | undefined): Buffer | null {
  if (value == null) return null;
  const normalized = String(value).replace(/-/g, '+').replace(/_/g, '/');
  return Buffer.from(normalized, 'base64');
}

/**
 * Wrap an async route handler so a rejected promise is forwarded to Express'
 * error middleware (Express 4 does NOT catch async throws on its own). Without
 * this, a throwing handler never sends a response and the client hangs.
 */
export const asyncHandler =
  (fn: (req: Request, res: Response, next: NextFunction) => Promise<unknown>): RequestHandler =>
  (req, res, next) => {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
