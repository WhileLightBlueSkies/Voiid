import { test } from 'node:test';
import assert from 'node:assert/strict';
import { groupRemovalError } from '../src/groupMembershipPolicy';

for (const caller of ['owner', 'admin', 'member']) {
  for (const target of ['owner', 'admin', 'member']) {
    test(`${caller} removing ${target} respects the role hierarchy`, () => {
      const allowed = caller === 'owner' && target !== 'owner' || caller === 'admin' && target === 'member';
      assert.equal(groupRemovalError(caller, target, false, 3) === null, allowed);
    });
  }
}
test('owner transfers ownership before leaving a nonempty group', () => {
  assert.notEqual(groupRemovalError('owner', 'owner', true, 2), null);
  assert.equal(groupRemovalError('owner', 'owner', true, 1), null);
});
test('members and admins may leave without removing others', () => {
  for (const role of ['member', 'admin']) assert.equal(groupRemovalError(role, role, true, 3), null);
});
