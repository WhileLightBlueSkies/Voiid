import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/*
 * GROUP ROLE INVARIANTS (036_group_roles.sql + routes/conversations.ts).
 *
 * These are STATIC assertions over the shipped source rather than a live-database
 * simulation, and that is deliberate: the properties worth protecting here are structural.
 * The database enforces one-owner with a partial unique index, so a route bug cannot
 * produce two owners — what a test CAN protect is that the route keeps the accompanying
 * discipline (locking before counting, resetting role on reinstate) that the index alone
 * cannot express. Every assertion below failed before the change that introduced it.
 */

const root = join(import.meta.dirname, '..', '..', '..');
const routes = readFileSync(join(root, 'backend/api/src/routes/conversations.ts'), 'utf8');
const migration = readFileSync(join(root, 'database/migrations/036_group_roles.sql'), 'utf8');

test('the one-owner rule is enforced by the database, not only by route logic', () => {
  assert.match(migration, /create unique index[^;]*idx_conversation_one_owner/s);
  // PARTIAL on left_at: a total index would forbid a group from ever having an owner again
  // once one leaves, because departed members keep their row.
  assert.match(migration, /idx_conversation_one_owner[\s\S]*?where role = 'owner' and left_at is null/);
});

test('role is constrained to the three known values', () => {
  assert.match(migration, /check \(role in \('owner', 'admin', 'member'\)\)/);
});

test('the group creator becomes owner, not merely admin', () => {
  assert.match(routes, /m === user_id \? 'owner' : 'member'/);
});

test('reinstating a member RESETS their role', () => {
  // The hazard this guards: a former owner re-added while still carrying role='owner'
  // trips the one-owner index, and the insert fails — making that person impossible to
  // re-add at all. Verified against a real Postgres before this test was written.
  assert.match(routes, /do update set left_at = null, role = 'member'/);
});

test('member and admin caps are counted while holding a lock', () => {
  // Counting outside a transaction lets two concurrent adds each read a count below the
  // cap and both proceed, so an unlocked "limit" is not a limit.
  const forUpdate = routes.match(/select 1 from conversations where id = \$1 for update/g) ?? [];
  assert.ok(forUpdate.length >= 3,
    `expected add/role/transfer to each lock the conversation row, found ${forUpdate.length}`);
  assert.match(routes, /MAX_GROUP_MEMBERS = 1000/);
  assert.match(routes, /MAX_GROUP_ADMINS = 50/);
});

test('ownership transfer demotes before promoting, inside one transaction', () => {
  const i = routes.indexOf("transfer-ownership");
  const body = routes.slice(i, i + 3000);
  const demote = body.indexOf("set role = 'admin'");
  const promote = body.indexOf("set role = 'owner'");
  assert.ok(demote > 0 && promote > 0, 'transfer must both demote and promote');
  // Promote-then-demote would momentarily have two owners and trip the unique index.
  assert.ok(demote < promote, 'the outgoing owner must be demoted BEFORE the new one is promoted');
  assert.ok(body.indexOf("commit") > promote, 'both halves must land in the same transaction');
});

test('only the owner can dismiss an admin', () => {
  assert.match(routes, /only the owner can dismiss an admin/);
});

test("the owner's role cannot be changed through the role endpoint", () => {
  assert.match(routes, /the owner's role can only change by transferring ownership/);
});

test('system events are structured payloads, never pre-baked sentences', () => {
  // The client composes the sentence so "You made X an admin" and "Nehal made X an admin"
  // can differ for the two people reading the same row — and so it can be localized.
  assert.match(routes, /kind, actor_id: actorId/);
  assert.doesNotMatch(routes, /made .* an admin'/,
    'a rendered English sentence must not be stored server-side');
});

test('a system row must carry an event, and a normal row must not', () => {
  assert.match(migration, /content_type = 'system' and system_event is not null/);
  assert.match(migration, /content_type <> 'system' and system_event is null/);
});
