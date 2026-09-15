import test from 'node:test';
import assert from 'node:assert/strict';
import { callKeyCopies, callKeyDeliveryFrames, CALL_DEVICE_CLAIM_SCRIPT } from '../src/callSignaling';
import Redis from 'ioredis';
import { randomUUID } from 'node:crypto';
import { encodeOneToOneCallGrant, encodeCallGrant, callGrantNeedsDeviceClaim, callGrantAllows } from '@voiid/common-utils';

test('API 1:1 grant enables device arbitration without treating a two-person conference as 1:1', () => {
  const pair = encodeOneToOneCallGrant('caller', 'callee');
  assert.equal(JSON.parse(pair).v, 2);
  assert.equal(callGrantNeedsDeviceClaim(JSON.parse(pair)), true);
  assert.equal(callGrantAllows(pair, 'caller', 'callee'), true);
  assert.equal(callGrantAllows(pair, 'caller', 'outsider'), false);
  assert.equal(callGrantNeedsDeviceClaim({ a: 'caller', b: 'callee' } as any), true);
  for (const roster of [['caller', 'callee'], ['caller', 'callee', 'third']])
    assert.equal(callGrantNeedsDeviceClaim(JSON.parse(encodeCallGrant(roster))), false);
});

const expected = [{ device_id: 'phone', body: 'opaque-encrypted-body' }];
test('iOS array, map and Android single-device keys normalize identically', () => {
  assert.deepEqual(callKeyCopies({ ciphertexts: expected }), expected);
  assert.deepEqual(callKeyCopies({ ciphertexts: { phone: expected[0].body } }), expected);
  assert.deepEqual(callKeyCopies({ device_id: 'phone', ciphertext: expected[0].body }), expected);
});
test('every recipient copy remains readable by existing iOS and Android decoders', () => {
  const copies = [...expected, { device_id: 'tablet', body: 'other-encrypted-body' }];
  const frames = callKeyDeliveryFrames('call', 'sender', 'sender-phone', copies).map(frame => JSON.parse(frame));
  assert.equal(frames.length, 2);
  frames.forEach((frame, index) => {
    assert.deepEqual(frame.ciphertexts, [copies[index]], 'iOS array format');
    assert.equal(frame.device_id, copies[index].device_id, 'Android recipient');
    assert.equal(frame.ciphertext, copies[index].body, 'Android body');
    assert.equal(frame.sender_device_id, 'sender-phone');
    assert.equal(frame.from_user_id, 'sender');
  });
});
test('malformed, duplicate, oversized and empty key fan-outs fail closed', () => {
  for (const input of [{}, { ciphertexts: [] }, { ciphertexts: [expected[0], expected[0]] },
    { ciphertexts: [{ device_id: 7, body: 'x' }] }, { ciphertexts: [{ device_id: 'phone', body: '' }] },
    { ciphertexts: Array.from({ length: 33 }, (_, n) => ({ device_id: String(n), body: 'x' })) },
    { device_id: 'phone', ciphertext: 'x'.repeat(65537) }]) assert.equal(callKeyCopies(input), null);
});

const url = process.env.CALL_TEST_REDIS_URL;
test('real Redis arbitrates two simultaneous answers and rejects stale device hangups', { skip: !url }, async () => {
  const parsed = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(parsed.hostname));
  const redis = new Redis(url!);
  const prefix = `call-test:${randomUUID()}`;
  const keys = [`${prefix}:callee`, `${prefix}:caller`];
  const claim = (device: string, kind: string, reversed = false) => redis.eval(
    CALL_DEVICE_CLAIM_SCRIPT, 2, ...(reversed ? [...keys].reverse() : keys), device, kind, 60, ''
  ) as Promise<[number, string, string]>;
  try {
    const results = await Promise.all([claim('ios', 'call_answer'), claim('android', 'call_answer')]);
    assert.equal(results.filter(r => r[0] === 1).length, 1);
    const winner = results.find(r => r[0] === 1)![1];
    const loser = winner === 'ios' ? 'android' : 'ios';
    assert.equal((await claim(loser, 'call_hangup'))[0], 0);
    assert.equal((await claim(loser, 'call_decline'))[0], 0);
    assert.deepEqual(await claim(winner, 'call_offer'), [1, winner, 'answer'], 'ICE restart preserves the answer winner');
    assert.deepEqual(await claim(loser, 'call_answer'), [0, winner, 'answer']);
    assert.equal((await claim(winner, 'call_answer'))[0], 1, 'winner may repeat its answer');
    assert.equal((await claim(winner, 'call_hangup'))[0], 1);
    assert.equal((await claim('caller', 'call_offer', true))[0], 0, 'late offer cannot resurrect ended call');
    await redis.del(...keys);
    const answerDecline = await Promise.all([claim('ios', 'call_decline'), claim('android', 'call_answer')]);
    assert.equal(answerDecline.filter(r => r[0] === 1).length, 1, 'answer/decline race has one verdict');
    await redis.del(...keys);
    assert.equal((await claim('caller', 'call_offer', true))[0], 1);
    assert.equal((await claim('caller-sibling', 'call_hangup', true))[0], 0, 'a caller sibling cannot cancel the dialing device');
    assert.equal((await claim('caller', 'call_hangup', true))[0], 1);
    assert.equal((await claim('callee', 'call_answer'))[0], 0, 'answer after caller cancellation is rejected');
  } finally { await redis.del(...keys); redis.disconnect(); }
});
