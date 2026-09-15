import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isCommunityNotificationMode, mentionedUsernames, shouldNotifyCommunity } from '../src/notificationPolicy';

test('All, Important and None cover all community activity types', () => {
  for (const kind of ['post', 'announcement', 'event', 'mention', 'reply'] as const) {
    assert.equal(shouldNotifyCommunity('all', kind), true);
    assert.equal(shouldNotifyCommunity('none', kind), false);
    assert.equal(shouldNotifyCommunity('important', kind), kind !== 'post');
  }
});
test('preference validation rejects arbitrary values', () => {
  for (const value of [null, {}, 'ALL', '', 'muted']) assert.equal(isCommunityNotificationMode(value), false);
  for (const value of ['all', 'important', 'none']) assert.equal(isCommunityNotificationMode(value), true);
});
test('mentions are bounded, deduplicated and do not match email addresses', () => {
  assert.deepEqual(mentionedUsernames('@Nehal hello @nehal, @voiid_test x@example.com'), ['nehal', 'voiid_test']);
  assert.equal(mentionedUsernames(Array.from({length:100},(_,i)=>`@user_${i}`).join(' ')).length, 50);
});
