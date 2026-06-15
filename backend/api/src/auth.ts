// OUR auth layer (Section 2.2 boundary): Firebase only sends OTP; identity + JWT are ours.
import jwt from 'jsonwebtoken';
import type { Request, Response, NextFunction } from 'express';

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

// Express middleware — rejects unauthenticated requests (Section 4.6: no unprotected endpoints).
export function requireAuth(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'missing bearer token' });
  }
  try {
    (req as any).auth = verifyToken(header.slice(7));
    next();
  } catch {
    return res.status(401).json({ error: 'invalid token' });
  }
}
