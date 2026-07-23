// Anonymous call-quality metrics: validation, whitelisting and clamping.
//
// This module is deliberately PURE (no db, no express, no env-at-import) so the
// privacy-critical logic — "exactly which fields can ever reach the database" —
// is trivially testable and auditable in one place.
//
// PRIVACY CONTRACT (Section 4.14): the ONLY values that may be persisted are the
// aggregate reliability counters enumerated in `METRIC_KEYS` below. Everything
// else a client sends is DROPPED, not stored, not logged. There is no passthrough
// path: `normalizeCallMetrics` builds a fresh object from a fixed key list rather
// than copying/spreading the request body, so a new client field can never
// silently become a new column's worth of data.

import crypto from 'crypto';

/** The complete set of accepted input keys. Anything else is dropped. */
export const METRIC_KEYS = [
  'call_id',
  'connected',
  'setup_ms',
  'duration_ms',
  'end_reason',
  'relayed',
  'ice_restarts',
  'avg_rtt_ms',
  'avg_packet_loss_pct',
  'jitter_ms',
  'platform',
] as const;

/**
 * Constrained `end_reason` vocabulary. An unconstrained free-text reason is both a
 * storage risk (a client could smuggle identifiers/content through it) and useless
 * for aggregation. Unknown values are coerced to 'unknown' rather than rejected, so
 * a newer client never fails to report.
 */
export const END_REASONS = [
  'hangup', // normal local/remote hangup after a connected call
  'declined', // callee explicitly declined
  'missed', // ring timed out with no answer
  'busy', // callee already on a call
  'failed', // setup failed (never connected)
  'timeout', // ICE/connection establishment timed out
  'network_lost', // was connected, then the transport died
  'unanswered', // caller cancelled while still ringing
  'unknown',
] as const;
export type EndReason = (typeof END_REASONS)[number];

/** end_reasons that count as an abnormal termination of an ALREADY-CONNECTED call. */
export const DROP_REASONS: readonly string[] = ['network_lost', 'timeout', 'failed'];

export const PLATFORMS = ['ios', 'android'] as const;
export type Platform = (typeof PLATFORMS)[number];

// Clamp bounds. A client is untrusted: it can send NaN, Infinity, negatives, or
// absurd magnitudes (accidentally or to skew ops dashboards). Every numeric is
// coerced into a sane range rather than rejected, so one bad field never discards
// an otherwise useful sample.
export const LIMITS = {
  setup_ms: { min: 0, max: 300_000 }, // 5 min is already a pathological setup
  duration_ms: { min: 0, max: 86_400_000 }, // 24h
  ice_restarts: { min: 0, max: 50 },
  avg_rtt_ms: { min: 0, max: 10_000 },
  avg_packet_loss_pct: { min: 0, max: 100 },
  jitter_ms: { min: 0, max: 10_000 },
} as const;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Clamp to an integer inside [min,max]; undefined for absent/non-finite input. */
export function clampInt(v: unknown, min: number, max: number): number | undefined {
  if (v == null) return undefined;
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isFinite(n)) return undefined;
  return Math.min(max, Math.max(min, Math.round(n)));
}

/** Clamp to a 2-decimal float inside [min,max]; undefined for absent/non-finite. */
export function clampNum(v: unknown, min: number, max: number): number | undefined {
  if (v == null) return undefined;
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isFinite(n)) return undefined;
  return Math.round(Math.min(max, Math.max(min, n)) * 100) / 100;
}

/** The exact shape that reaches SQL. No `call_id`, no user id — see `dedupeHash`. */
export interface CallMetrics {
  connected: boolean;
  relayed: boolean;
  platform: Platform;
  end_reason: EndReason;
  setup_ms?: number;
  duration_ms?: number;
  ice_restarts?: number;
  avg_rtt_ms?: number;
  avg_packet_loss_pct?: number;
  jitter_ms?: number;
}

export type NormalizeResult =
  | { ok: true; value: CallMetrics; dropped: string[]; call_id: string }
  | { ok: false; error: string };

/**
 * Validate + whitelist + clamp a client-submitted metrics body.
 *
 * Returns the persistable row (`value`), the raw `call_id` (used ONLY to derive an
 * unlinkable dedupe hash — never persisted, see `dedupeHash`), and the list of
 * unrecognised keys that were dropped (returned to the caller for observability;
 * the KEY NAMES only, never their values).
 */
export function normalizeCallMetrics(body: unknown): NormalizeResult {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return { ok: false, error: 'body must be an object' };
  }
  const b = body as Record<string, unknown>;

  // Report (but never persist) anything outside the whitelist.
  const known = new Set<string>(METRIC_KEYS);
  const dropped = Object.keys(b).filter((k) => !known.has(k));

  if (typeof b.call_id !== 'string' || !UUID_RE.test(b.call_id)) {
    return { ok: false, error: 'call_id must be a uuid' };
  }
  if (typeof b.connected !== 'boolean') return { ok: false, error: 'connected (boolean) required' };
  if (typeof b.relayed !== 'boolean') return { ok: false, error: 'relayed (boolean) required' };
  if (typeof b.platform !== 'string' || !(PLATFORMS as readonly string[]).includes(b.platform)) {
    return { ok: false, error: "platform must be 'ios' or 'android'" };
  }
  if (typeof b.end_reason !== 'string') return { ok: false, error: 'end_reason (string) required' };

  const end_reason: EndReason = (END_REASONS as readonly string[]).includes(b.end_reason)
    ? (b.end_reason as EndReason)
    : 'unknown';

  // Built key-by-key from the whitelist — never spread from the request body.
  const value: CallMetrics = {
    connected: b.connected,
    relayed: b.relayed,
    platform: b.platform as Platform,
    end_reason,
  };
  const setup_ms = clampInt(b.setup_ms, LIMITS.setup_ms.min, LIMITS.setup_ms.max);
  if (setup_ms !== undefined) value.setup_ms = setup_ms;
  const duration_ms = clampInt(b.duration_ms, LIMITS.duration_ms.min, LIMITS.duration_ms.max);
  if (duration_ms !== undefined) value.duration_ms = duration_ms;
  const ice_restarts = clampInt(b.ice_restarts, LIMITS.ice_restarts.min, LIMITS.ice_restarts.max);
  if (ice_restarts !== undefined) value.ice_restarts = ice_restarts;
  const avg_rtt_ms = clampNum(b.avg_rtt_ms, LIMITS.avg_rtt_ms.min, LIMITS.avg_rtt_ms.max);
  if (avg_rtt_ms !== undefined) value.avg_rtt_ms = avg_rtt_ms;
  const loss = clampNum(
    b.avg_packet_loss_pct,
    LIMITS.avg_packet_loss_pct.min,
    LIMITS.avg_packet_loss_pct.max
  );
  if (loss !== undefined) value.avg_packet_loss_pct = loss;
  const jitter_ms = clampNum(b.jitter_ms, LIMITS.jitter_ms.min, LIMITS.jitter_ms.max);
  if (jitter_ms !== undefined) value.jitter_ms = jitter_ms;

  return { ok: true, value, dropped, call_id: b.call_id };
}

/**
 * Derive the row's de-duplication key from the call id WITHOUT storing the call id.
 *
 * Why not store `call_id`: it is the primary key of the `calls` table, which holds
 * caller_user_id + conversation_id + timestamps. Persisting it here would make this
 * table joinable back onto "who called whom, when" — exactly the linkage the
 * anonymous metrics table exists to avoid. Instead we store a keyed HMAC: it still
 * makes a retried POST idempotent, but it is not reversible without the server
 * secret, and ROTATING that secret permanently severs the link for existing rows.
 *
 * The key defaults to a random per-process value when unset, which is the safe
 * default (dedupe degrades to per-process; linkage is impossible by construction).
 */
const EPHEMERAL_DEDUPE_KEY = crypto.randomBytes(32).toString('hex');
export function dedupeHash(callId: string, secret?: string): Buffer {
  const key = secret ?? process.env.VOIID_METRICS_DEDUPE_SECRET ?? EPHEMERAL_DEDUPE_KEY;
  return crypto.createHmac('sha256', key).update(callId).digest();
}

/** Summary window in hours: clamp to [1, 720] (30 days) with a 24h default. */
export function clampWindowHours(v: unknown): number {
  return clampInt(v, 1, 720) ?? 24;
}
