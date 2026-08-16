// Blocking — the decision logic behind every enforcement point.
//
// WHAT THIS EXISTS FOR
// --------------------
// The iOS Block button raised "Blocking isn't available yet" beneath a dialog promising
// "They won't be able to message or call you." 043_user_blocks.sql plus src/blocking.ts
// make that true; this pins the two rules that are easy to get wrong and impossible to
// notice when they are.
//
//   1. ENFORCEMENT IS SYMMETRIC. Storage is directional (blocker -> blocked), but a block
//      stops traffic BOTH ways. If it were one-way, blocking someone would become a way to
//      talk AT them while they could not answer — a harassment tool built out of an
//      anti-harassment feature.
//
//   2. GROUPS ARE NOT GATED ON ONE PAIR. If a blocked pair stopped a group send, any member
//      could silence a whole room by blocking one person in it. The block governs what
//      those two see of each other; everyone else is unaffected.
//
// The predicates are mirrored here rather than imported because src/blocking.ts pulls in
// db at import time, which a unit test has no business booting. If the module changes,
// this must too — the assertions below say what the behaviour has to be.
import { test } from 'node:test';
import assert from 'node:assert/strict';

interface BlockRow {
  blocker_user_id: string;
  blocked_user_id: string;
}

/** Mirrors `isBlockedEitherWay` — the question nearly every enforcement point asks. */
function isBlockedEitherWay(rows: BlockRow[], a: string, b: string): boolean {
  if (!a || !b || a === b) return false;
  return rows.some(
    (r) =>
      (r.blocker_user_id === a && r.blocked_user_id === b) ||
      (r.blocker_user_id === b && r.blocked_user_id === a)
  );
}

/** Mirrors `hasBlocked` — direction matters only for deciding what to TELL the caller. */
function hasBlocked(rows: BlockRow[], blocker: string, blocked: string): boolean {
  if (!blocker || !blocked || blocker === blocked) return false;
  return rows.some((r) => r.blocker_user_id === blocker && r.blocked_user_id === blocked);
}

/** Mirrors `blockedUserIds` — the union used for fan-out filtering. */
function blockedUserIds(rows: BlockRow[], userId: string): Set<string> {
  const out = new Set<string>();
  for (const r of rows) {
    if (r.blocker_user_id === userId) out.add(r.blocked_user_id);
    if (r.blocked_user_id === userId) out.add(r.blocker_user_id);
  }
  return out;
}

/**
 * Mirrors `blockedCounterpartForSend`. `convType` decides whether the pair rule applies at
 * all — see rule 2 in the header.
 */
function blockedCounterpartForSend(
  rows: BlockRow[],
  convType: 'direct' | 'group' | 'self',
  otherMembers: string[],
  senderId: string
): string | null {
  if (!otherMembers.length) return null;
  if (convType === 'group') return null;
  const blocked = blockedUserIds(rows, senderId);
  return otherMembers.find((m) => blocked.has(m)) ?? null;
}

const ALICE = 'alice';
const BOB = 'bob';
const CAROL = 'carol';

/** Alice blocked Bob. Nothing else. */
const ALICE_BLOCKED_BOB: BlockRow[] = [{ blocker_user_id: ALICE, blocked_user_id: BOB }];

// ---------------------------------------------------------------------------
// Rule 1 — symmetry.
// ---------------------------------------------------------------------------

test('the blocker cannot reach the person they blocked', () => {
  assert.equal(isBlockedEitherWay(ALICE_BLOCKED_BOB, ALICE, BOB), true);
});

test('the BLOCKED party cannot reach the blocker either', () => {
  // The direction that is easy to miss, and the one that matters most: Bob has no row of
  // his own, but Alice's row must stop him all the same. Without this, blocking someone
  // would leave you able to message them while they cannot reply.
  assert.equal(isBlockedEitherWay(ALICE_BLOCKED_BOB, BOB, ALICE), true);
});

test('an unrelated pair is unaffected', () => {
  assert.equal(isBlockedEitherWay(ALICE_BLOCKED_BOB, BOB, CAROL), false);
  assert.equal(isBlockedEitherWay(ALICE_BLOCKED_BOB, ALICE, CAROL), false);
});

test('a user is never blocked against themselves', () => {
  // Note to Self must stay reachable. 039's check constraint makes a self-block unstorable,
  // but the predicate guards it too rather than relying on the table alone.
  assert.equal(isBlockedEitherWay(ALICE_BLOCKED_BOB, ALICE, ALICE), false);
  assert.equal(isBlockedEitherWay([], CAROL, CAROL), false);
});

test('empty or missing ids are not treated as a block', () => {
  assert.equal(isBlockedEitherWay(ALICE_BLOCKED_BOB, '', BOB), false);
  assert.equal(isBlockedEitherWay(ALICE_BLOCKED_BOB, ALICE, ''), false);
});

// ---------------------------------------------------------------------------
// Direction — only for deciding what the caller is TOLD.
// ---------------------------------------------------------------------------

test('hasBlocked is directional, so the blocker can be told plainly', () => {
  // Alice gets a 403 she can act on ("unblock to send"); Bob gets silence.
  assert.equal(hasBlocked(ALICE_BLOCKED_BOB, ALICE, BOB), true);
  assert.equal(hasBlocked(ALICE_BLOCKED_BOB, BOB, ALICE), false);
});

// ---------------------------------------------------------------------------
// Rule 2 — groups are never gated on one pair.
// ---------------------------------------------------------------------------

test('a direct send to a blocked counterpart is stopped', () => {
  assert.equal(
    blockedCounterpartForSend(ALICE_BLOCKED_BOB, 'direct', [BOB], ALICE),
    BOB
  );
});

test('a group send is never stopped by one blocked member', () => {
  // Alice blocked Bob; Carol is also in the group. If this returned Bob, Alice could no
  // longer talk to Carol — one block would silence an entire room.
  assert.equal(
    blockedCounterpartForSend(ALICE_BLOCKED_BOB, 'group', [BOB, CAROL], ALICE),
    null
  );
});

test('a direct send between unblocked users is allowed', () => {
  assert.equal(
    blockedCounterpartForSend(ALICE_BLOCKED_BOB, 'direct', [CAROL], ALICE),
    null
  );
});

test('a conversation with no other members is allowed', () => {
  // Note to Self: exactly one member, and it is you.
  assert.equal(blockedCounterpartForSend(ALICE_BLOCKED_BOB, 'self', [], ALICE), null);
});

test('the blocked party is stopped sending to the blocker in a direct chat', () => {
  // Bob has no row of his own; the symmetric union is what catches him.
  assert.equal(
    blockedCounterpartForSend(ALICE_BLOCKED_BOB, 'direct', [ALICE], BOB),
    ALICE
  );
});

// ---------------------------------------------------------------------------
// Fan-out filtering (stories, push, group delivery).
// ---------------------------------------------------------------------------

test('blockedUserIds unions both directions', () => {
  const rows: BlockRow[] = [
    { blocker_user_id: ALICE, blocked_user_id: BOB },   // alice blocked bob
    { blocker_user_id: CAROL, blocked_user_id: ALICE }, // carol blocked alice
  ];
  // Alice cannot reach Bob (she blocked him) or Carol (Carol blocked her).
  assert.deepEqual([...blockedUserIds(rows, ALICE)].sort(), [BOB, CAROL].sort());
  // Bob is only entangled with Alice.
  assert.deepEqual([...blockedUserIds(rows, BOB)], [ALICE]);
});

test('a mutual block yields one entry, not two', () => {
  // Both directions stored. The set must not report the same person twice, or a caller
  // sizing a filtered audience would count wrong.
  const rows: BlockRow[] = [
    { blocker_user_id: ALICE, blocked_user_id: BOB },
    { blocker_user_id: BOB, blocked_user_id: ALICE },
  ];
  assert.equal(blockedUserIds(rows, ALICE).size, 1);
  assert.equal(blockedUserIds(rows, BOB).size, 1);
});

test('no blocks at all filters nobody', () => {
  assert.equal(blockedUserIds([], ALICE).size, 0);
  assert.equal(isBlockedEitherWay([], ALICE, BOB), false);
});

// ---------------------------------------------------------------------------
// Unblock, and the mutual-block trap.
// ---------------------------------------------------------------------------

test('one side unblocking does not lift a mutual block', () => {
  // Alice unblocks Bob, but Bob still blocks Alice. They must stay unable to interact.
  // This is the case that makes the Redis mirror in routes/blocks.ts conditional: dropping
  // the cache key here would let typing indicators flow while Postgres still says no.
  const afterAliceUnblocks: BlockRow[] = [{ blocker_user_id: BOB, blocked_user_id: ALICE }];
  assert.equal(isBlockedEitherWay(afterAliceUnblocks, ALICE, BOB), true);
  assert.equal(hasBlocked(afterAliceUnblocks, ALICE, BOB), false);
});

test('unblocking a one-way block fully restores contact', () => {
  assert.equal(isBlockedEitherWay([], ALICE, BOB), false);
});
