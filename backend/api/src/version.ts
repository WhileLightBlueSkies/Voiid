// API versioning & client-compatibility (Section: versioning architecture).
//
//  - Path versioning: routes are served under /v1 (and, during migration, also at
//    the legacy root). /v1 is a STABLE contract — only ADDITIVE changes within it
//    (add optional fields; never remove/rename). New breaking shapes ship as /v2.
//  - Remote config: clients call GET /config on launch to learn which API version
//    to use, feature flags, and the minimum supported app version.
//  - Force-update gating: every request may carry the client's platform + app
//    version (headers below). If it's below the per-platform minimum, the gate
//    returns a structured 426 so the app can show a forced-update prompt.
//
// Client headers (sent by both apps):
//   X-Voiid-Platform     ios | android
//   X-Voiid-App-Version  semver, e.g. 1.4.2
//   X-Voiid-Api-Version  e.g. v1
import type { Request, Response, NextFunction } from 'express';

export const CURRENT_API_VERSION = 'v1';
export const SUPPORTED_API_VERSIONS = ['v1'];

// Minimum app version we still serve, per platform. Bump to force-update users
// below it. Overridable via env (MIN_APP_IOS / MIN_APP_ANDROID) without a deploy.
export const minSupportedApp = () => ({
  ios: process.env.MIN_APP_IOS || '1.0.0',
  android: process.env.MIN_APP_ANDROID || '1.0.0',
});

// Optional hard cutoff: after this ISO date, clients that report NO version are
// also blocked (pre-versioning builds). Empty = never. (env FORCE_CUTOFF)
export const forceCutoff = () => process.env.FORCE_CUTOFF || '';

export const APP_STORE_URL = process.env.IOS_STORE_URL || 'https://apps.apple.com/app/voiid';
export const PLAY_STORE_URL = process.env.ANDROID_STORE_URL || 'https://play.google.com/store/apps/details?id=com.voiid.app';

/** Compare two semver-ish strings. -1 if a<b, 0 if equal, 1 if a>b. */
export function cmpVersion(a: string, b: string): number {
  const pa = a.split('.').map((n) => parseInt(n, 10) || 0);
  const pb = b.split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i++) {
    const x = pa[i] ?? 0, y = pb[i] ?? 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

export interface ClientInfo { platform: 'ios' | 'android' | 'unknown'; appVersion: string | null; apiVersion: string | null; }

export function readClient(req: Request): ClientInfo {
  const p = String(req.header('X-Voiid-Platform') || '').toLowerCase();
  return {
    platform: p === 'ios' || p === 'android' ? p : 'unknown',
    appVersion: req.header('X-Voiid-App-Version') || null,
    apiVersion: req.header('X-Voiid-Api-Version') || null,
  };
}

/** True if this client is below the minimum supported app version (must update). */
export function isUpdateRequired(c: ClientInfo): boolean {
  const mins = minSupportedApp();
  if (c.platform === 'ios' || c.platform === 'android') {
    if (!c.appVersion) {
      // Reports platform but no version → only block past the hard cutoff.
      const cutoff = forceCutoff();
      return cutoff ? new Date() >= new Date(cutoff) : false;
    }
    return cmpVersion(c.appVersion, mins[c.platform]) < 0;
  }
  return false; // unknown/non-app caller (scripts, health checks) — never gated
}

export function updateRequiredBody(c: ClientInfo) {
  return {
    error: 'update_required',
    message: 'A newer version of VOIID is required to continue.',
    min_supported_app: minSupportedApp(),
    update_url: c.platform === 'android' ? PLAY_STORE_URL : APP_STORE_URL,
  };
}

/** Express middleware: 426 the request if the client is below minimum. */
export function forceUpdateGate(req: Request, res: Response, next: NextFunction) {
  const c = readClient(req);
  if (isUpdateRequired(c)) {
    return res.status(426).json(updateRequiredBody(c));
  }
  next();
}
