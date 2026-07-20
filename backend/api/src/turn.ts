// ICE/TURN credential issuance — extracted from routes/calls.ts so the byte-exact
// coturn HMAC scheme and the provider-precedence/fallback rules are unit-testable
// without standing up express, Postgres or a real TURN server.
//
// All env is read at CALL time (not module load) so a deployment can rotate the
// TURN secret without a restart — and so tests can exercise every configuration
// branch in one process.

import crypto from 'crypto';

/** TURN credential TTL (coturn REST scheme + Cloudflare). Default 1 hour. */
export function turnTtlSeconds(): number {
  return Number(process.env.VOIID_TURN_TTL_SECONDS) || 3600;
}

export function splitEnvList(value: string | undefined): string[] {
  return (value ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

/** STUN is safe to expose unconditionally (public reflexive-address discovery). */
export function stunUrls(): string[] {
  const raw = process.env.VOIID_STUN_URLS?.trim();
  return raw ? splitEnvList(raw) : ['stun:stun.l.google.com:19302'];
}

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

export interface IceConfig {
  ice_servers: IceServer[];
  ttl_seconds: number;
  turn_configured: boolean;
}

// --- coturn REST ephemeral-credential scheme (use-auth-secret) ---------------------
// username = "<unixExpiry>:<userId>", credential = base64(HMAC_SHA1(secret, username)).
// Works with self-hosted coturn configured with `use-auth-secret` + `static-auth-secret`.
// Per-user and time-limited: a leaked credential expires within TTL and is scoped to
// the requesting user (the userId is bound into the HMAC'd username).
export function coturnCredentials(
  userId: string,
  opts?: { secret?: string; ttlSeconds?: number; nowMs?: number }
): { username: string; credential: string; expiry: number } {
  const ttl = opts?.ttlSeconds ?? turnTtlSeconds();
  const expiry = Math.floor((opts?.nowMs ?? Date.now()) / 1000) + ttl;
  const username = `${expiry}:${userId}`;
  const secret = opts?.secret ?? (process.env.VOIID_TURN_STATIC_AUTH_SECRET as string);
  const credential = crypto.createHmac('sha1', secret).update(username).digest('base64');
  return { username, credential, expiry };
}

// --- Cloudflare TURN (managed) -----------------------------------------------------
// If configured, Cloudflare mints the credentials for us. We prefer this over the
// self-hosted coturn scheme when its env is present. Returns null on ANY failure
// (unconfigured, non-2xx, malformed body, network error) so the caller falls back
// instead of 500ing.
export async function cloudflareIceServers(): Promise<IceServer[] | null> {
  const keyId = process.env.VOIID_TURN_CLOUDFLARE_KEY_ID;
  const token = process.env.VOIID_TURN_CLOUDFLARE_API_TOKEN;
  if (!keyId || !token) return null;
  try {
    const resp = await fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate`,
      {
        method: 'POST',
        headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify({ ttl: turnTtlSeconds() }),
      }
    );
    if (!resp.ok) {
      console.warn(`[calls] cloudflare TURN generate failed: ${resp.status}`);
      return null;
    }
    // CF returns { iceServers: { urls: string[]|string, username, credential } }.
    const body = (await resp.json()) as {
      iceServers?: { urls?: string[] | string; username?: string; credential?: string };
    };
    const ice = body?.iceServers;
    if (!ice?.urls) return null;
    const urls = Array.isArray(ice.urls) ? ice.urls : [ice.urls];
    return [{ urls, username: ice.username, credential: ice.credential }];
  } catch (e) {
    console.warn('[calls] cloudflare TURN request error:', (e as Error).message);
    return null;
  }
}

/**
 * Resolve the ICE server list for a user.
 *
 * Precedence: Cloudflare (if configured) -> coturn HMAC (if urls + secret set) ->
 * STUN-only. NEVER throws just because TURN is unconfigured: an unprovisioned dev
 * box returns STUN-only with `turn_configured: false` so the client can still
 * attempt (P2P-only) calls rather than seeing a 500.
 */
export async function resolveIceServers(userId: string): Promise<IceConfig> {
  const ttl_seconds = turnTtlSeconds();
  const ice_servers: IceServer[] = [{ urls: stunUrls() }];

  // 1) Cloudflare managed TURN (preferred when configured).
  const cf = await cloudflareIceServers();
  if (cf) {
    ice_servers.push(...cf);
    return { ice_servers, ttl_seconds, turn_configured: true };
  }

  // 2) Self-hosted coturn REST scheme (HMAC over static-auth-secret).
  const turnUrls = splitEnvList(process.env.VOIID_TURN_URLS);
  if (turnUrls.length && process.env.VOIID_TURN_STATIC_AUTH_SECRET) {
    const { username, credential } = coturnCredentials(userId, { ttlSeconds: ttl_seconds });
    ice_servers.push({ urls: turnUrls, username, credential });
    return { ice_servers, ttl_seconds, turn_configured: true };
  }

  // 3) STUN-only fallback (dev / TURN not provisioned). Not an error.
  return { ice_servers, ttl_seconds, turn_configured: false };
}
