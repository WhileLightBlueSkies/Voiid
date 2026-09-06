// Who the relay may actually send a frame to (R02).
//
// ── THE THING THIS REPLACES ──────────────────────────────────────────────────────
//
// `typing`, `session_reset`, `loc_update` and `loc_stop` all carried a `recipient_ids` array
// and the relay published to whatever it named. The comments in index.ts were honest about
// why — "the client supplies recipient_ids because this process has no database" — and that
// was true right up until S03 gave it one. It is not true any more, so the list is DERIVED
// here instead of trusted.
//
// What that closes: an outsider could address typing and session_reset into any conversation
// id it could guess, and relay location frames at arbitrary users. The location case had a
// stated defence — the payload is encrypted under a share key the recipient does not hold, so
// a stranger learns nothing — but "the ciphertext is useless to them" is not the same as "the
// frame never arrives", and the buffered-fix write (`hset`) meant a stranger could still put
// entries into another user's location buffer and delete them again with `loc_stop`.
//
// ── FAIL CLOSED, ALWAYS ──────────────────────────────────────────────────────────
//
// Every failure here resolves to the empty list: no members, no share, a malformed id, a
// database that will not answer. A dropped typing indicator is invisible; a typing indicator
// delivered to someone who is not in the conversation is a leak of who is talking to whom.
// The relay carries no content on these paths, so the cost of being wrong in this direction
// is always the smaller one.
import { sessionPool } from './session';

interface RecipientCache {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, mode: 'EX', ttl: number): Promise<unknown>;
}
let cache: RecipientCache | null = null;

/** The relay passes its existing Redis connection rather than opening another one. */
export function useRecipientCache(client: RecipientCache): void {
  cache = client;
}

/**
 * How long a resolved audience is reused.
 *
 * Typing frames are the highest-frequency thing this process handles, so resolving them
 * against Postgres on every keystroke is not an option — hence a cache. Ten seconds is the
 * same window auth.ts uses, and the exposure it buys is small and bounded: for at most ten
 * seconds after leaving a conversation or blocking someone, a typing indicator or a
 * session-reset hint may still arrive. Neither carries content. Every path that moves an
 * actual message goes through the API, which reads the database directly and is not cached.
 */
const AUDIENCE_TTL_SECONDS = 10;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function resolve(key: string, sql: string, params: unknown[], cacheable = true): Promise<string[]> {
  try {
    const cached = cacheable ? await cache?.get(key) : null;
    if (cached != null) return cached ? cached.split(',') : [];
  } catch { /* the database is the authority; a cache outage costs a round-trip */ }

  let ids: string[];
  try {
    const { rows } = await sessionPool().query(sql, params);
    ids = rows.map((r: { id: string }) => r.id);
  } catch (error) {
    // NOT cached: a database blip must not pin an empty audience for the next ten seconds.
    console.error('[voiid:ws] recipient lookup failed:', (error as Error).message);
    return [];
  }

  try { if (cacheable) await cache?.set(key, ids.join(','), 'EX', AUDIENCE_TTL_SECONDS); } catch { /* best effort */ }
  return ids;
}

/**
 * The other active members of a conversation the sender is actually in.
 *
 * One statement, because the three questions are one question: is the SENDER an active
 * member, who else is, and is either end of that pair blocked. The blocking check is
 * two-directional and matches routes/messages.ts — a block hides both ways, so neither side
 * sees the other typing.
 */
export async function conversationRecipients(userId: string, conversationId: unknown): Promise<string[]> {
  if (typeof conversationId !== 'string' || !UUID_RE.test(conversationId)) return [];
  return resolve(
    `relay:conv:${conversationId}:${userId}`,
    `select m.user_id as id
       from conversation_members m
      where m.conversation_id = $1
        and m.left_at is null
        and m.user_id <> $2
        and exists (
              select 1 from conversation_members me
               where me.conversation_id = $1 and me.user_id = $2 and me.left_at is null)
        and not exists (
              select 1 from user_blocks b
               where (b.blocker_user_id = m.user_id and b.blocked_user_id = $2)
                  or (b.blocker_user_id = $2 and b.blocked_user_id = m.user_id))`,
    [conversationId, userId]
  );
}

/**
 * The live targets of a location share, for its OWNER only.
 *
 * A share id is not a capability: ownership is checked in the statement, so relaying under
 * someone else's share id resolves to nobody. Expiry (`expires_at`), the owner's explicit
 * stop (`ended_at`) and per-target revocation (`revoked_at`) are all enforced here rather
 * than only at POST /location/shares — 018's own comment notes expiry is enforced by every
 * read path filtering on it, and this is now one of those read paths.
 */
export async function shareRecipients(userId: string, shareId: unknown): Promise<string[]> {
  if (typeof shareId !== 'string' || !UUID_RE.test(shareId)) return [];
  return resolve(
    `relay:share:${shareId}:${userId}`,
    `select t.target_user_id as id
       from location_share_targets t
       join location_shares s on s.id = t.share_id
      where t.share_id = $1
        and s.owner_user_id = $2
        and t.revoked_at is null
        and s.ended_at is null
        and s.expires_at > now()
        and not exists (
              select 1 from user_blocks b
               where (b.blocker_user_id = t.target_user_id and b.blocked_user_id = $2)
                  or (b.blocker_user_id = $2 and b.blocked_user_id = t.target_user_id))`,
    [shareId, userId], false
  );
}

/**
 * Intersect a client's requested recipients with the audience it is actually entitled to.
 *
 * A client may legitimately want to address a subset — session_reset is meant for one person
 * — so the request is honoured as a NARROWING and never as a widening. With no list (or a
 * malformed one) the full derived audience is used, which is what typing wants. Duplicates
 * collapse, so a frame naming the same id a thousand times costs one publish.
 */
export function narrow(audience: string[], requested: unknown): string[] {
  if (!Array.isArray(requested) || requested.length === 0) return [...new Set(audience)].slice(0, 512);
  const asked = new Set(requested.filter((id): id is string => typeof id === 'string'));
  const kept = audience.filter((id) => asked.has(id));
  // A list that intersects nothing is a client naming only people it may not address. Falling
  // back to the whole audience there would turn a rejected frame into a broadcast.
  return [...new Set(kept)].slice(0, 512);
}
