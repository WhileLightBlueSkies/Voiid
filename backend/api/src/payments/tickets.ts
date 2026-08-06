// The ticket QR code: what the phone shows, and what the door checks.
//
// ── THE THREAT MODEL, WHICH IS NOT THE USUAL ONE ─────────────────────────────────
//
// A door scanner is offline-ish, in a hurry, and operated by a volunteer. The attacks that
// matter are not sophisticated:
//
//   * SOMEONE MAKES UP A TICKET. Defeated by the signature: the code carries an HMAC over
//     server-held key material, so a code the server did not mint does not verify. This is why
//     the QR is not just the ticket's uuid — a uuid in a QR is a bearer token with no integrity
//     at all, and anyone who saw one printed on a poster could probe for others.
//   * SOMEONE FORWARDS THEIR TICKET TO TEN FRIENDS. Defeated in two layers. The code EXPIRES
//     (minutes, not days), so a screenshot goes stale; and the ticket's stored `qr_nonce` is
//     part of the signed payload, so regenerating the nonce invalidates every code minted
//     before it. Without a stored nonce the only revocation available would be rotating the
//     server key for every ticket at once.
//   * ONE TICKET WALKS IN TWICE. Not defeated here at all — that is the conditional UPDATE on
//     `checked_in_at` in the scan route, and it has to be there because two scanners at two
//     doors is a database race, not a cryptographic problem.
//
// ── WHAT THIS IS NOT ─────────────────────────────────────────────────────────────
//
// Not end-to-end encryption, and it must never be described as one. The server mints these and
// the server can verify them, which is the entire point: somebody at a door has to be told yes
// or no about a person they have never met. 032_events_tickets.sql states the scoped exception
// this belongs to. Messages, calls, locations and moments are unaffected.
import { createHmac, randomBytes, timingSafeEqual } from 'crypto';
import { secretboxKey } from '../secretbox';

/** Format marker, so a future scheme change is distinguishable on sight rather than by guessing. */
const PREFIX = 't1';

/**
 * How long a displayed code stays valid.
 *
 * Short, because the phone can always mint another one and a stale code is a re-fetch rather
 * than a failure. Long enough that a queue moving slowly, or a phone that lost signal after the
 * screenshot, still gets in. Ten minutes is the compromise; it is the one number here that is a
 * product decision rather than a security one.
 */
const CODE_TTL_SECONDS = 10 * 60;

/** Small skew allowance so a scanner whose clock is a little behind does not reject good codes. */
const CLOCK_SKEW_SECONDS = 60;

let cachedKey: Buffer | null | undefined;

/**
 * The key codes are signed with.
 *
 * `VOIID_TICKET_SIGNING_KEY` if set. Otherwise DERIVED from VOIID_SECRETBOX_KEY with a
 * domain-separation label — HMAC is a sound KDF, and the label means a ticket code can never be
 * confused with, or used to attack, anything else sealed under that key. The derivation exists
 * so a deployment that already has a secretbox key gets working tickets without a second
 * secret to distribute; setting the dedicated variable is still the better posture, because it
 * lets the two be rotated independently.
 *
 * Null when neither is configured. Callers degrade the one feature that needs it rather than
 * inventing an unsigned code, which would be a bearer uuid wearing a costume.
 */
function signingKey(): Buffer | null {
  if (cachedKey !== undefined) return cachedKey;

  const raw = process.env.VOIID_TICKET_SIGNING_KEY?.trim();
  if (raw) {
    const key = Buffer.from(raw, 'base64');
    if (key.length < 32) {
      // Loud and at first use rather than silently weak: an operator who set this variable
      // believes signing is switched on properly.
      throw new Error(
        'VOIID_TICKET_SIGNING_KEY must be at least 32 bytes base64-encoded. ' +
          'Generate one with: openssl rand -base64 32'
      );
    }
    cachedKey = key;
    return key;
  }

  const base = secretboxKey();
  cachedKey = base ? createHmac('sha256', base).update('voiid-ticket-qr-v1').digest() : null;
  return cachedKey;
}

/** FOR TESTS. Nothing in a running server should change its key mid-process. */
export function resetTicketKeyForTests(): void {
  cachedKey = undefined;
}

export function ticketSigningAvailable(): boolean {
  return signingKey() !== null;
}

/** A fresh nonce for a new or rotated ticket. 32 base64url chars, inside 032's 16-64 range. */
export function newTicketNonce(): string {
  return randomBytes(24).toString('base64url');
}

interface TicketClaims {
  /** ticket id */ t: string;
  /** event id */  e: string;
  /** nonce */     n: string;
  /** expiry, unix seconds */ x: number;
}

/**
 * Mint the string the phone renders as a QR: `t1.<claims>.<mac>`.
 *
 * The claims are readable by anyone holding the code, and that is fine — they are two uuids and
 * a timestamp the holder already knows. Confidentiality is not the property being bought here;
 * integrity is.
 */
export function signTicketCode(ticketId: string, eventId: string, nonce: string): {
  code: string;
  expiresAt: number;
} | null {
  const key = signingKey();
  if (!key) return null;

  const exp = Math.floor(Date.now() / 1000) + CODE_TTL_SECONDS;
  const claims: TicketClaims = { t: ticketId, e: eventId, n: nonce, x: exp };
  const body = Buffer.from(JSON.stringify(claims), 'utf8').toString('base64url');
  const mac = createHmac('sha256', key).update(`${PREFIX}.${body}`).digest('base64url');
  return { code: `${PREFIX}.${body}.${mac}`, expiresAt: exp * 1000 };
}

export type TicketCheck =
  | { ok: true; ticketId: string; eventId: string; nonce: string }
  | { ok: false; reason: 'unsigned' | 'malformed' | 'bad_signature' | 'expired' };

/**
 * Verify a scanned code. Returns the claims it carries — NOT a decision about admission.
 *
 * The caller still has to check that the ticket exists, is valid, belongs to the event being
 * scanned, its order is paid, and it has not already been used. Every one of those is a
 * database fact and none of them is in the code, deliberately: a signed code says "the server
 * minted this", not "let this person in", and collapsing the two is how a revoked ticket ends
 * up being honoured by a scanner that only checked the signature.
 */
export function verifyTicketCode(code: unknown): TicketCheck {
  const key = signingKey();
  if (!key) return { ok: false, reason: 'unsigned' };
  if (typeof code !== 'string' || code.length > 1024) return { ok: false, reason: 'malformed' };

  const parts = code.split('.');
  if (parts.length !== 3 || parts[0] !== PREFIX) return { ok: false, reason: 'malformed' };

  const expected = createHmac('sha256', key).update(`${PREFIX}.${parts[1]}`).digest('base64url');
  const given = Buffer.from(parts[2], 'utf8');
  const want = Buffer.from(expected, 'utf8');
  // Length check first: timingSafeEqual THROWS on a length mismatch, and a throw here would be
  // a 500 on a scan rather than a rejection. Comparing constant-time matters because the door
  // endpoint is an oracle an attacker can call as often as they like.
  if (given.length !== want.length || !timingSafeEqual(given, want)) {
    return { ok: false, reason: 'bad_signature' };
  }

  let claims: TicketClaims;
  try {
    claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
  } catch {
    return { ok: false, reason: 'malformed' };
  }
  if (
    typeof claims?.t !== 'string' ||
    typeof claims?.e !== 'string' ||
    typeof claims?.n !== 'string' ||
    typeof claims?.x !== 'number'
  ) {
    return { ok: false, reason: 'malformed' };
  }

  const now = Math.floor(Date.now() / 1000);
  if (claims.x + CLOCK_SKEW_SECONDS < now) return { ok: false, reason: 'expired' };

  return { ok: true, ticketId: claims.t, eventId: claims.e, nonce: claims.n };
}
