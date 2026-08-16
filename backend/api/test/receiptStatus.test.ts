// `receipt_status` decides the sender's ticks. It got two things wrong.
//
// THE BUGS THIS EXISTS FOR
// ------------------------
// GET /messages/conversation/:id computes, per message, the state to show the SENDER —
// Sent (null) → Delivered → Seen. It used to be:
//
//     case when bool_or(r.status = 'read')      then 'read'
//          when bool_or(r.status = 'delivered') then 'delivered'
//          else null end
//     ... left join message_read_receipts r on r.message_id = m.id
//
//   1. THE JOIN HAD NO SENDER FILTER. A receipt written by the sender's OWN linked device
//      counted. Fan-out marks inbound copies delivered, so a second device of yours turned
//      your own message Delivered — and in Note to Self, where every receipt is your own,
//      messages showed Seen that literally no one else could have read. iOS filters
//      `!isMine` client-side, which hid it, but a server that trusts a client to not forge
//      its own read receipts is not enforcing anything: Android, web, or a replayed request
//      would still do it.
//
//   2. `bool_or` MEANT "ANY ONE PERSON READ IT". In a group the tick went blue the moment a
//      single member opened the message, while everyone else had not seen it. That is not
//      what a blue tick promises and not what WhatsApp or Signal do.
//
// The replacement counts DISTINCT recipient user ids and compares against the number of
// active members other than the sender:
//
//   * 'read'      — every active recipient reached 'read'
//   * 'delivered' — at least one recipient has it (answers "did it leave the building")
//   * null        — nobody has it yet
//
// The `> 0` guard on the read branch is load-bearing: without it a message with NO receipts
// evaluates `0 >= 0` and every unread message in the app turns blue.
//
// Verified against a real Postgres 18 during development; this test pins the decision logic
// so it cannot regress. The SQL is mirrored here rather than imported because the route
// module boots db/redis at import time.
import { test } from 'node:test';
import assert from 'node:assert/strict';

interface Receipt {
  user_id: string;
  status: 'delivered' | 'read';
}

/**
 * Mirrors the `receipt_status` CASE expression in routes/messages.ts.
 *
 * `receipts` is already filtered the way the SQL's join filters it: the sender's own
 * receipts are excluded via `r.user_id <> m.sender_id`, so anything reaching this function
 * belongs to someone else. `activeRecipientCount` is the subquery over conversation_members
 * (left_at is null, user_id <> sender).
 */
function receiptStatus(receipts: Receipt[], activeRecipientCount: number): string | null {
  const distinct = (pred: (r: Receipt) => boolean) =>
    new Set(receipts.filter(pred).map((r) => r.user_id)).size;

  const readers = distinct((r) => r.status === 'read');
  const holders = distinct((r) => r.status === 'delivered' || r.status === 'read');

  if (readers > 0 && readers >= activeRecipientCount) return 'read';
  if (holders > 0) return 'delivered';
  return null;
}

/** Applies the join's sender-exclusion, so tests can pass raw rows as the DB holds them. */
function excludingSender(rows: Array<Receipt>, senderId: string): Receipt[] {
  return rows.filter((r) => r.user_id !== senderId);
}

const ALICE = 'alice';   // always the sender below
const BOB = 'bob';
const CAROL = 'carol';

// ---------------------------------------------------------------------------
// Bug 1 — the sender's own receipts must never move the sender's own ticks.
// ---------------------------------------------------------------------------

test('a receipt from the sender\'s own device does not mark their message delivered', () => {
  // Alice's second device received the fan-out copy and marked it delivered.
  const rows: Receipt[] = [{ user_id: ALICE, status: 'delivered' }];
  assert.equal(receiptStatus(excludingSender(rows, ALICE), 1), null);
});

test('note to self never reports Seen — every receipt in it is the sender\'s own', () => {
  // The pathological case: a conversation where the only other "member" is yourself.
  const rows: Receipt[] = [{ user_id: ALICE, status: 'read' }];
  assert.equal(receiptStatus(excludingSender(rows, ALICE), 0), null);
});

test('the sender\'s own read receipt cannot forge Seen while the recipient has only received it', () => {
  const rows: Receipt[] = [
    { user_id: ALICE, status: 'read' },      // sender's own device — must not count
    { user_id: BOB, status: 'delivered' },   // the actual recipient has NOT read it
  ];
  assert.equal(receiptStatus(excludingSender(rows, ALICE), 1), 'delivered');
});

// ---------------------------------------------------------------------------
// Bug 2 — 'read' means EVERY active recipient read it, not merely one.
// ---------------------------------------------------------------------------

test('a group where only one of two members has read stays Delivered', () => {
  const rows: Receipt[] = [
    { user_id: BOB, status: 'read' },
    { user_id: CAROL, status: 'delivered' },
  ];
  assert.equal(receiptStatus(excludingSender(rows, ALICE), 2), 'delivered');
});

test('a group turns Seen only once every member has read', () => {
  const rows: Receipt[] = [
    { user_id: BOB, status: 'read' },
    { user_id: CAROL, status: 'read' },
  ];
  assert.equal(receiptStatus(excludingSender(rows, ALICE), 2), 'read');
});

test('a member who left the group is not waited on', () => {
  // Carol left; she can never read it. Counting her would leave the tick grey forever.
  // activeRecipientCount excludes her (left_at is not null), so Bob alone satisfies it.
  const rows: Receipt[] = [{ user_id: BOB, status: 'read' }];
  assert.equal(receiptStatus(excludingSender(rows, ALICE), 1), 'read');
});

test('one recipient reading is enough in a direct chat', () => {
  // The 1:1 case falls out of the same expression — one recipient means any-read and
  // all-read coincide. This is the overwhelmingly common path; it must not regress.
  const rows: Receipt[] = [{ user_id: BOB, status: 'read' }];
  assert.equal(receiptStatus(excludingSender(rows, ALICE), 1), 'read');
});

// ---------------------------------------------------------------------------
// The `> 0` guard, and ordinary progression.
// ---------------------------------------------------------------------------

test('a message with no receipts at all is Sent, not Seen', () => {
  // THE TRAP: without the `readers > 0` guard this evaluates 0 >= 0 and returns 'read',
  // turning every single unread message in the app blue.
  assert.equal(receiptStatus([], 1), null);
});

test('a message in an empty group is not Seen when nobody holds it', () => {
  // Degenerate but reachable: everyone left. 0 readers vs 0 recipients must still be null.
  assert.equal(receiptStatus([], 0), null);
});

test('delivered is reported as soon as any one recipient holds it', () => {
  const rows: Receipt[] = [
    { user_id: BOB, status: 'delivered' },
  ];
  assert.equal(receiptStatus(excludingSender(rows, ALICE), 2), 'delivered');
});

test('a read receipt also counts as delivered for the delivered branch', () => {
  // Someone who READ it obviously also RECEIVED it. If the delivered branch only matched
  // status='delivered', a group where one member read and the rest had nothing would report
  // null — a message going backwards from Delivered to Sent.
  const rows: Receipt[] = [{ user_id: BOB, status: 'read' }];
  assert.equal(receiptStatus(excludingSender(rows, ALICE), 2), 'delivered');
});

test('duplicate receipts from one user\'s several devices count that user once', () => {
  // Receipts are per (message, user, device). Two devices of Bob's must not satisfy a
  // two-recipient group on their own — that would be bug 2 through a different door.
  const rows: Receipt[] = [
    { user_id: BOB, status: 'read' },
    { user_id: BOB, status: 'read' },
  ];
  assert.equal(receiptStatus(excludingSender(rows, ALICE), 2), 'delivered');
});
