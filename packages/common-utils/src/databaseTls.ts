// How every service decides whether — and how — to verify the database server (S05).
//
// ── WHAT THIS REPLACES ───────────────────────────────────────────────────────────
//
// Four copies of two lines:
//
//     const isLocal = url.includes('localhost') || url.includes('127.0.0.1');
//     ssl: isLocal ? undefined : { rejectUnauthorized: false }
//
// Both halves were wrong.
//
// `rejectUnauthorized: false` turns on encryption and turns OFF the check of who is being
// encrypted to. That is not a weaker guarantee than verified TLS, it is a different one: it
// stops a passive listener and does nothing at all against anyone positioned to answer. A
// machine able to sit between the box and Supabase could present any certificate and read or
// rewrite the whole database — every ciphertext envelope, every device row, every session.
//
// And the local exemption was a substring search over the WHOLE connection string, so a
// password containing "localhost", a database named "localhost", or a host an attacker can
// register such as `localhost.attacker.example` silently disabled verification for a remote
// database. The hostname is parsed here instead.
//
// ── ROLLOUT ──────────────────────────────────────────────────────────────────────
//
// Verification is the default, which means a deployment whose trust store does not already
// contain the database's CA will fail to connect after this ships. That is deliberate and it
// is the only ordering that ends with verification actually on. The staged path is:
//
//   1. set VOIID_DB_TLS_INSECURE=1 in the environment (this is today's behaviour, made
//      explicit and loud rather than implicit and silent),
//   2. provision the CA — VOIID_DB_CA_CERT (PEM contents) or VOIID_DB_CA_CERT_PATH,
//   3. remove VOIID_DB_TLS_INSECURE and redeploy.
//
// Step 3 is the fix. Steps 1 and 2 exist so that shipping it is not an outage.
import { readFileSync } from 'fs';

export type DatabaseSsl = undefined | { rejectUnauthorized: boolean; ca?: string };

/** Only these are the machine this process is running on. Nothing else is "local". */
const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '[::1]', '0.0.0.0']);

/**
 * `sslmode` values that would weaken the policy if node-postgres honoured them from the URL.
 *
 * node-postgres does read `sslmode` out of a connection string, so a URL saying `disable` or
 * `no-verify` could quietly undo what the caller asked for — the connection string is
 * configuration too, and it is the piece most likely to be pasted in from somewhere else.
 * Refusing loudly is better than two settings disagreeing in silence.
 */
const WEAKENING_SSLMODES = new Set(['disable', 'allow', 'prefer', 'no-verify']);

function hostnameOf(url: string): string | null {
  try {
    // The scheme is postgres:// or postgresql://, which WHATWG URL parses as an opaque-host
    // scheme; swapping in http:// gives the same authority parsing with a real hostname.
    return new URL(url.replace(/^postgres(ql)?:\/\//, 'http://')).hostname.toLowerCase();
  } catch {
    return null;
  }
}

/**
 * The SSL option for a `pg` Pool/Client.
 *
 * `undefined` means "no TLS", and is returned ONLY for a loopback host or an unset URL.
 * Everything else is verified, with an optional explicit CA.
 */
export function resolveDatabaseSsl(
  url: string,
  env: Record<string, string | undefined> = process.env
): DatabaseSsl {
  // Nothing configured yet. Expressing no opinion keeps the "unset DATABASE_URL" case
  // behaving exactly as it did — the connection fails on use, not at import.
  if (!url) return undefined;

  const hostname = hostnameOf(url);
  // An unparseable URL is NOT local. Failing closed here matters more than being clever:
  // the alternative is a malformed string silently opting out of verification.
  const isLoopback = hostname != null && LOOPBACK_HOSTS.has(hostname);

  const sslmode = (url.match(/[?&]sslmode=([^&]+)/i)?.[1] ?? '').toLowerCase();
  const sslParam = (url.match(/[?&]ssl=([^&]+)/i)?.[1] ?? '').toLowerCase();
  if (!isLoopback) {
    if (sslmode && WEAKENING_SSLMODES.has(sslmode)) {
      throw new Error(
        `DATABASE_URL sets sslmode=${sslmode} for a remote host, which would disable certificate ` +
          `verification. Remove it, or use VOIID_DB_TLS_INSECURE=1 if this is a deliberate, ` +
          `temporary step in the CA rollout.`
      );
    }
    if (sslParam === 'false' || sslParam === '0') {
      throw new Error(
        'DATABASE_URL sets the ssl option to false for a remote host, which would disable ' +
          'certificate verification. Remove it, or use VOIID_DB_TLS_INSECURE=1 ' +
          'if this is a deliberate, temporary step in the CA rollout.'
      );
    }
  }

  if (isLoopback) return undefined;

  // EXACTLY '1'. A stray 'false' or 'no' in a deploy environment must not read as consent to
  // stop checking certificates — the failure would be invisible and permanent.
  if (env.VOIID_DB_TLS_INSECURE === '1') {
    return { rejectUnauthorized: false };
  }

  const ca = env.VOIID_DB_CA_CERT?.trim()
    ? env.VOIID_DB_CA_CERT
    : env.VOIID_DB_CA_CERT_PATH?.trim()
      ? readFileSync(env.VOIID_DB_CA_CERT_PATH, 'utf8')
      : undefined;

  return ca ? { rejectUnauthorized: true, ca } : { rejectUnauthorized: true };
}

/** One line for the boot log, so the policy in force is visible without reading the env. */
export function describeDatabaseTls(ssl: DatabaseSsl): string {
  if (!ssl) return 'database TLS: off (loopback)';
  if (!ssl.rejectUnauthorized) {
    return 'database TLS: ENCRYPTED BUT UNVERIFIED — VOIID_DB_TLS_INSECURE=1 is set. ' +
      'This is a staged-rollout setting; provision VOIID_DB_CA_CERT and remove it.';
  }
  return `database TLS: verified${ssl.ca ? ' (explicit CA)' : ' (system roots)'}`;
}
