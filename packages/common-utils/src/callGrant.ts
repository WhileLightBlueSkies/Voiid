export interface CallGrant {
  /** Original 1:1 caller — legacy pair field, still honoured by the current relay. */
  a: string;
  /** Original 1:1 callee — legacy pair field. Equals `a` only in the degenerate case. */
  b: string;
  /** Every user allowed to signal on this call right now. The authoritative field. */
  p: string[];
  /** Format version. 1 = implicit (pair only, no `p`); 2 = this shape. */
  v: number;
}

export const CALL_GRANT_VERSION = 2;

/** Format version is not call mode: both 1:1 and conference grants use v2. */
export function encodeOneToOneCallGrant(caller: string, callee: string): string {
  return JSON.stringify({ ...JSON.parse(encodeCallGrant([caller, callee], [caller, callee])), mode: 'one-to-one' });
}

/** Unmarked v2 grants retain conference behavior during a rolling deployment. */
export function callGrantNeedsDeviceClaim(grant: { v?: number; mode?: string }): boolean {
  return grant.mode === 'one-to-one' || grant.v == null || grant.v === 1;
}

/**
 * How long a CONFERENCE grant lives.
 *
 * The 1:1 ring grant is 120s — sized to outlive a ring, not a call. That is fine for a
 * ring because the pair is re-derivable, but a conference grant is the ONLY record the
 * relay has of who is in the room, and the room outlives the ring by however long people
 * talk. Matched to the LiveKit token lifetime so "your token is valid" and "your frames
 * relay" expire together instead of leaving a participant half-connected.
 *
 * It is still a lease, not a permanent right: every escalate/join/leave rewrites it from
 * the live `call_participants` roster, so a participant who leaves stops being able to
 * signal on the next membership change rather than at TTL expiry.
 */
export const CONFERENCE_GRANT_TTL_SECONDS = 6 * 3600;

/**
 * Build the Redis grant value for a call.
 *
 * @param participants every user id currently permitted to signal (state <> 'left').
 * @param legacyPair   the ORIGINAL 1:1 pair, preserved in `a`/`b` (see above). Defaults to
 *                     the first two participants when the original pair is unknown.
 */
export function encodeCallGrant(participants: string[], legacyPair?: [string, string]): string {
  // Dedupe while preserving order — join order is the roster order and the first two are
  // the fallback legacy pair.
  const p = participants.filter((id, i) => typeof id === 'string' && !!id && participants.indexOf(id) === i);
  const a = legacyPair?.[0] ?? p[0] ?? '';
  const b = legacyPair?.[1] ?? p[1] ?? p[0] ?? '';
  const grant: CallGrant = { a, b, p, v: CALL_GRANT_VERSION };
  return JSON.stringify(grant);
}

/** Parse a grant written by either format. Returns null on absent/garbage input. */
export function decodeCallGrant(raw: string | null | undefined): CallGrant | null {
  if (!raw) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== 'object') return null;
  const o = parsed as Record<string, unknown>;
  const a = typeof o.a === 'string' ? o.a : '';
  const b = typeof o.b === 'string' ? o.b : '';
  if (!a || !b) return null;
  if (o.v == null || o.v === 1) {
    if ('p' in o) return null;
    return { a, b, p: [a, b], v: 1 };
  }
  if (o.v !== 2 || !Array.isArray(o.p) || o.p.length > 8 ||
      o.p.some(id => typeof id !== 'string' || !id) || new Set(o.p).size !== o.p.length) return null;
  return { a, b, p: o.p, v: 2 };
}

/**
 * May a call frame from `from` to `to` be relayed for this call?
 *
 * Both endpoints must be in the grant. Self-addressed frames are refused: the relay never
 * echoes to the sender, and allowing it would make the grant a way to fan a frame back to
 * your own other devices outside the `call_taken` path built for exactly that.
 *
 * This is the function the WS relay's `callPairAuthorized` must mirror.
 */
export function callGrantAllows(raw: string | null | undefined, from: string, to: string): boolean {
  const grant = decodeCallGrant(raw);
  if (!grant) return false; // fail closed
  if (!from || !to || from === to) return false;
  return grant.p.includes(from) && grant.p.includes(to);
}
