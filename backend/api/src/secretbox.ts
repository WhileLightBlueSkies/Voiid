// SECRETBOX — reversible encryption at rest for server-held secrets.
//
// This is for the narrow class of secrets the server must be able to READ BACK and show to
// their owner. Almost nothing qualifies: a password must never be readable, so it is hashed.
// The contact PIN is the exception, because it is a shareable token — you tell people your
// PIN the way you tell them your number, and a token you cannot look up again is one you
// have to write down or destroy.
//
// WHAT THIS IS NOT
// ----------------
// This is NOT end-to-end encryption and must never be described as such to a user. The
// server holds the key, so the server can read the value. It defends exactly one scenario:
// a stolen database dump. A `select * from users` — a leaked backup, a misconfigured
// replica, a SQL injection — yields ciphertext, and the attacker still needs VOIID_SECRETBOX_KEY
// from the process environment to turn it into PINs. That is a real and common failure mode,
// and it is worth defending even though it is not the strongest possible guarantee.
//
// Messages, calls, and media are E2E encrypted and the server genuinely cannot read them.
// Nothing here touches that. See packages/e2e-core.
//
// AES-256-GCM, one fresh random nonce per encryption. Nonce reuse under the same key is the
// catastrophic failure mode for GCM — it leaks the XOR of two plaintexts AND allows forgery —
// so the nonce is generated inside `seal` and never accepted from a caller.
import { createCipheriv, createDecipheriv, randomBytes } from 'crypto';

const ALGO = 'aes-256-gcm';
const NONCE_BYTES = 12; // 96 bits, the GCM standard — what the NIST construction is defined for.
const TAG_BYTES = 16;

/** Marks the format so a future rotation to a different scheme is distinguishable on sight. */
const PREFIX = 'v1';

let cachedKey: Buffer | null | undefined;

/**
 * The 32-byte key from `VOIID_SECRETBOX_KEY` (base64), or null when unset.
 *
 * UNSET IS A SUPPORTED STATE, not a crash: a dev checkout with no key should still boot and
 * serve every other route. Callers handle null by degrading the one feature that needs it —
 * see `reachability.ts`, which falls back to show-once behaviour rather than failing.
 *
 * Cached because this is on the request path and reading + decoding env on every call is
 * pointless work. `undefined` means "not yet read"; `null` means "read, and absent".
 */
export function secretboxKey(): Buffer | null {
  if (cachedKey !== undefined) return cachedKey;

  const raw = process.env.VOIID_SECRETBOX_KEY?.trim();
  if (!raw) {
    cachedKey = null;
    return null;
  }

  const key = Buffer.from(raw, 'base64');
  if (key.length !== 32) {
    // Loud, and at startup rather than at first use. A key of the wrong length is a
    // deployment mistake — silently treating it as "no key" would quietly downgrade a
    // security control that the operator believes is switched on.
    throw new Error(
      `VOIID_SECRETBOX_KEY must be 32 bytes base64-encoded (got ${key.length}). ` +
        `Generate one with: openssl rand -base64 32`
    );
  }

  cachedKey = key;
  return key;
}

/**
 * Drop the memoised key so the next call re-reads the environment.
 *
 * FOR TESTS. Nothing in the running server should change its key mid-process — that would
 * strand every value sealed under the old one. It exists because the alternative in the test
 * suite is re-importing the module to defeat the cache, which Node's loader makes unreliable
 * enough that a test can pass for the wrong reason.
 */
export function resetSecretboxKeyForTests(): void {
  cachedKey = undefined;
}

/** Whether reversible storage is available. Features gate on this rather than assuming. */
export function secretboxAvailable(): boolean {
  return secretboxKey() !== null;
}

/**
 * Encrypt a short string for storage. Returns `v1.<nonce>.<ciphertext+tag>`, all base64url.
 *
 * Throws when no key is configured — a caller that reaches here without checking
 * `secretboxAvailable()` has a logic bug, and storing plaintext as a "fallback" would be a
 * silent, invisible downgrade of exactly the thing this module exists to prevent.
 */
export function seal(plaintext: string): string {
  const key = secretboxKey();
  if (!key) throw new Error('seal() called with no VOIID_SECRETBOX_KEY configured');

  // Fresh per call, never derived from the plaintext or a counter. See the GCM note above.
  const nonce = randomBytes(NONCE_BYTES);
  const cipher = createCipheriv(ALGO, key, nonce);
  const body = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();

  return [
    PREFIX,
    nonce.toString('base64url'),
    Buffer.concat([body, tag]).toString('base64url'),
  ].join('.');
}

/**
 * Reverse `seal`. Returns null for anything that does not decrypt cleanly — wrong key,
 * truncated value, tampered ciphertext, or a legacy value stored under a different scheme.
 *
 * NULL RATHER THAN THROW is deliberate. Every caller sits on a read path where the honest
 * response to "this value is unreadable" is to behave as though it is absent, and a throw
 * would turn one bad row into a 500 on a settings screen.
 */
export function open(sealed: string | null | undefined): string | null {
  if (!sealed) return null;
  const key = secretboxKey();
  if (!key) return null;

  const parts = sealed.split('.');
  if (parts.length !== 3 || parts[0] !== PREFIX) return null;

  try {
    const nonce = Buffer.from(parts[1], 'base64url');
    const blob = Buffer.from(parts[2], 'base64url');
    if (nonce.length !== NONCE_BYTES || blob.length <= TAG_BYTES) return null;

    const body = blob.subarray(0, blob.length - TAG_BYTES);
    const tag = blob.subarray(blob.length - TAG_BYTES);

    const decipher = createDecipheriv(ALGO, key, nonce);
    // GCM authenticates: a wrong key or a flipped bit makes `final()` throw rather than
    // returning garbage. That is the property that makes returning null here safe.
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(body), decipher.final()]).toString('utf8');
  } catch {
    return null;
  }
}
