// The relay's periodic clocks, and the invariants that tie them to each other.
//
// Extracted from index.ts for the same reason turn.ts was extracted from routes/calls.ts:
// importing index.ts binds a port and opens Redis connections, so a rule that lives there is
// a rule no test can read. These three values are only correct RELATIVE to one another, which
// is exactly the kind of thing that rots silently — cadence.test.ts pins the relationships.
import { SESSION_STATE_TTL_SECONDS } from '@voiid/common-utils';

/**
 * How long a socket's presence lease survives without renewal.
 *
 * Mirrors the TTL handed to PRESENCE_SCRIPT. A socket whose lease expires is treated as gone:
 * it stops receiving fan-out and the user reads as offline while still connected.
 */
export const LEASE_TTL_MS = 60_000;

/**
 * Ping/pong liveness, and the cadence the presence lease is renewed on.
 *
 * Must stay well below LEASE_TTL_MS — renew less often than the lease lives and a perfectly
 * healthy socket goes offline underneath itself. Cheap enough to run at this rate because it
 * is one local ping plus one Redis eval, and nothing else.
 */
export const HEARTBEAT_INTERVAL_MS = 20_000;

/**
 * How often an ALREADY-OPEN socket re-verifies that its session still exists.
 *
 * THIS IS A BACKSTOP, AND SIZING IT LIKE A PRIMARY CHECK IS WHAT WENT WRONG. Revocation
 * reaches a live socket through `force_signout` on the user's channel, published by the same
 * call that writes `revoked_at`; that is the path that actually ends a session and it is
 * immediate. This timer covers only the case where that frame was never delivered — the relay
 * was mid-restart, Redis dropped the publish — so it is allowed to be slow.
 *
 * It used to share the 20s ping timer, which made it the opposite of slow. With the session
 * cache expiring in 10s, every check arrived after the entry was already gone, so the cache
 * had a 100% miss rate and each check reached Postgres: one query per socket per 20 seconds,
 * 250/s at 5k concurrent sockets, through `poolBudget('websocket')` — a pool deliberately
 * sized for "one indexed lookup per socket CONNECT, and nothing else". The surrounding catch
 * terminates the socket, so the first slow moment in that pool would drop the sockets waiting
 * on it and have them all reconnect together.
 *
 * Kept strictly below SESSION_STATE_TTL_SECONDS so the steady state is served from Redis and
 * Postgres sees only genuine misses and revocations.
 */
export const REAUTH_INTERVAL_MS = Number(process.env.VOIID_WS_REAUTH_MS) || 60_000;

/** The session-cache TTL these intervals are sized against, in the same unit as they are. */
export const SESSION_STATE_TTL_MS = SESSION_STATE_TTL_SECONDS * 1_000;
