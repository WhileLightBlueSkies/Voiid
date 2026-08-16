// User blocking — the shared predicate every enforcement point calls.
//
// One module rather than an inline query per route, because blocking is only as strong as
// its WEAKEST check: nine call sites each writing their own SQL is nine chances to get the
// direction wrong or forget the pair is symmetric. Routes ask a question here; they never
// write the query themselves.
//
// THE PAIR RULE
// -------------
// A block is stored directionally (blocker -> blocked, see 039_user_blocks.sql) but
// ENFORCED symmetrically: if a block exists in EITHER direction, the two users cannot
// reach each other. This is deliberate. If enforcement were one-way, blocking someone
// would become a way to talk AT them while they had no way to answer — a harassment tool
// built out of an anti-harassment feature.
//
// SILENCE, NOT REJECTION
// ----------------------
// A blocked sender must not be able to tell "blocked" from "offline" or "phone is dead".
// That means enforcement generally returns a SUCCESS-SHAPED response and quietly drops the
// effect, rather than a distinctive 403 the client could probe with. Where a route must
// return something, prefer the same answer a stranger would get.
//
// The exception is the BLOCKER's own actions: when the person who pressed Block tries to
// message the user they blocked, telling them plainly is correct — they know the block
// exists, they created it, and silently dropping their message would look like a bug.

import { query } from './db';

/**
 * Is there a block in EITHER direction between these two users?
 *
 * This is the question almost every enforcement point wants. Returns false for a user
 * paired with themselves — Note to Self must never be blockable, and 039's check
 * constraint already makes a self-block unstorable.
 */
export async function isBlockedEitherWay(userA: string, userB: string): Promise<boolean> {
  if (!userA || !userB || userA === userB) return false;
  const rows = await query<{ one: number }>(
    `select 1 as one from user_blocks
      where (blocker_user_id = $1 and blocked_user_id = $2)
         or (blocker_user_id = $2 and blocked_user_id = $1)
      limit 1`,
    [userA, userB]
  );
  return rows.length > 0;
}

/**
 * Did `blockerId` specifically block `blockedId`?
 *
 * Use ONLY where the direction genuinely matters — chiefly to decide whether to tell the
 * caller plainly (they blocked this person) or stay silent (this person blocked them).
 * For "may these two interact", use `isBlockedEitherWay`.
 */
export async function hasBlocked(blockerId: string, blockedId: string): Promise<boolean> {
  if (!blockerId || !blockedId || blockerId === blockedId) return false;
  const rows = await query<{ one: number }>(
    `select 1 as one from user_blocks
      where blocker_user_id = $1 and blocked_user_id = $2 limit 1`,
    [blockerId, blockedId]
  );
  return rows.length > 0;
}

/**
 * Every user id `userId` has a block with, in either direction.
 *
 * For fan-out paths that must filter a LIST of recipients — group message delivery, push
 * targeting, story audiences. One query for the whole set rather than one per member,
 * which on a large group is the difference between a single index scan and hundreds.
 */
export async function blockedUserIds(userId: string): Promise<Set<string>> {
  if (!userId) return new Set();
  const rows = await query<{ other_id: string }>(
    `select blocked_user_id as other_id from user_blocks where blocker_user_id = $1
     union
     select blocker_user_id as other_id from user_blocks where blocked_user_id = $1`,
    [userId]
  );
  return new Set(rows.map((r) => r.other_id));
}

/**
 * The subset of `candidateIds` that `userId` can still reach.
 *
 * Order is preserved and duplicates are left as-is, so a caller can zip the result against
 * a parallel array (device rows, for instance) without re-keying.
 */
export async function filterReachable(
  userId: string,
  candidateIds: string[]
): Promise<string[]> {
  if (!candidateIds.length) return [];
  const blocked = await blockedUserIds(userId);
  return candidateIds.filter((id) => !blocked.has(id));
}

/**
 * The OTHER participants of a conversation — everyone active except `userId`.
 *
 * Blocking is a property of a user PAIR, but most enforcement happens where the code only
 * has a conversation id. This resolves one to the other.
 */
export async function otherMemberIds(
  conversationId: string,
  userId: string
): Promise<string[]> {
  const rows = await query<{ user_id: string }>(
    `select user_id from conversation_members
      where conversation_id = $1 and user_id <> $2 and left_at is null`,
    [conversationId, userId]
  );
  return rows.map((r) => r.user_id);
}

/**
 * May `userId` send into this conversation?
 *
 * Returns the blocking counterpart when the answer is no, so the caller can decide between
 * telling the blocker plainly and staying silent for the blocked.
 *
 * DIRECT CHATS ONLY BLOCK THE PAIR. In a GROUP, one blocked member must not silence the
 * whole room — the block governs what those two people see of each other, not whether
 * everyone else can talk. So a group send is always allowed here; per-recipient filtering
 * happens at delivery instead (see `filterReachable`).
 */
export async function blockedCounterpartForSend(
  conversationId: string,
  userId: string
): Promise<string | null> {
  const rows = await query<{ user_id: string; type: string }>(
    `select cm.user_id, c.type
       from conversation_members cm
       join conversations c on c.id = cm.conversation_id
      where cm.conversation_id = $1 and cm.user_id <> $2 and cm.left_at is null`,
    [conversationId, userId]
  );
  if (!rows.length) return null;
  // Groups: never gate the whole send on one blocked pair.
  if (rows[0].type === 'group') return null;

  const blocked = await blockedUserIds(userId);
  const hit = rows.find((r) => blocked.has(r.user_id));
  return hit ? hit.user_id : null;
}
