// How long a session verdict may be served from Redis (S03).
//
// ── WHY THIS LIVES HERE AND NOT IN EITHER SERVICE ────────────────────────────────
//
// The API and the relay both cache `auth:session:<sid>:<user>:<device>` — the same key, in
// the same Redis. Whichever writes last sets the expiry the other one reads, so two private
// constants that happen to agree is not a design; it is a coincidence one edit away from
// ending. The relay's copy was annotated "Same TTL and same reasoning as the API's session
// cache", which is the comment you write immediately before they drift.
//
// ── WHY THIS IS A BACKSTOP, NOT THE REVOCATION MECHANISM ─────────────────────────
//
// Revocation does not wait for this to expire. `revokeDeviceSessions` writes '0' STRAIGHT
// OVER the cached verdict, for REVOCATION_TTL_SECONDS — longer than any token can live — and
// publishes `force_signout` on the user's channel, which closes sockets that are already
// open. Both land immediately. This TTL covers only the case where that overwrite never
// happened, i.e. Redis was unreachable during the revoke, and it bounds how long a stale '1'
// may outlive it.
//
// ── WHY IT IS NOT 10 SECONDS ─────────────────────────────────────────────────────
//
// It must stay comfortably ABOVE the relay's re-authorization interval
// (VOIID_WS_REAUTH_MS, default 60s). A TTL shorter than that interval does not merely cache
// less well — it guarantees a miss on EVERY check, because the entry is always already gone
// by the time the next one runs. At 10s against a 20s check that made each live socket a
// recurring Postgres client: a few thousand idle sockets became hundreds of queries per
// second through a deliberately tiny pool, with `catch { ws.terminate(); }` on the other
// side, so one slow pool moment would have disconnected the sockets it was serving.
export const SESSION_STATE_TTL_SECONDS = 75;
