import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isPrivacyVisibility, ownerPrivacyPreferences } from '../src/privacy';

const values = { last_seen_privacy: 'nobody', photo_privacy: 'contacts', about_privacy: 'everyone' };
test('owner receives all saved audiences for cross-device settings hydration', () => {
  assert.deepEqual(ownerPrivacyPreferences('alice', 'alice', values), values);
});
test('other viewers cannot inspect the owner’s audience settings', () => {
  assert.deepEqual(ownerPrivacyPreferences('bob', 'alice', values), {});
});
test('owner projection is an explicit whitelist, not a user record spread', () => {
  const user = { ...values, phone_number: '+15555555555', contact_pin_hash: 'secret' };
  assert.deepEqual(ownerPrivacyPreferences('alice', 'alice', user), values);
});
test('accepts only supported audience strings', () => {
  for (const value of ['everyone', 'contacts', 'nobody']) assert.equal(isPrivacyVisibility(value), true);
  for (const value of [undefined, null, '', 'Everyone', 'friends', ['nobody'], { toString: () => 'nobody' }, 1]) {
    assert.equal(isPrivacyVisibility(value), false);
  }
});
