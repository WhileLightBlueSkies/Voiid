import test from 'node:test';
import assert from 'node:assert/strict';
import { companionAllows } from '../src/webCompanion';
const own = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', other = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
test('linked browsers have only messaging and self-revocation capabilities', () => {
  for (const route of ['/linking/approve', '/linking/preview', '/devices/register', '/auth/firebase', '/calls/start', '/groups/create', '/recovery/enable']) assert.equal(companionAllows('POST', route, own, {}), false, route);
  assert.equal(companionAllows('DELETE', `/devices/${other}`, own), false);
  assert.equal(companionAllows('DELETE', `/devices/${own}`, own), true);
  assert.equal(companionAllows('POST', '/prekeys/upload', own, { device_id: other }), false);
  assert.equal(companionAllows('POST', '/prekeys/upload', own, { device_id: own }), true);
  assert.equal(companionAllows('GET', '/conversations', own), true);
  assert.equal(companionAllows('POST', '/messages/send', own), true);
  assert.equal(companionAllows('POST', '/linking/socket-ticket', own), true);
  assert.equal(companionAllows('GET', '/users/me/export', own), false);
});
