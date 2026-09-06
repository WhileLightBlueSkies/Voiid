// R02 — the budgets that run BEFORE any Redis work, and the limiter map that used to grow
// without a ceiling.
//
// The old per-share location limiter was keyed by a client-supplied share id and never
// pruned, so a client could mint unlimited keys: each one got its own fresh allowance (so the
// limit bought nothing) and the map grew for the life of the socket. Both properties are
// pinned here, along with `narrow` — the rule that a client's recipient list may only ever
// shrink the audience the database derived for it.
import test from 'node:test';
import assert from 'node:assert/strict';
import { BoundedRateMap, SocketBudget } from '../src/budget';
import { narrow } from '../src/recipients';

test('the aggregate socket budget counts every frame, whatever its type', () => {
  const budget = new SocketBudget({ frames: 3, bytes: 1_000_000, windowMs: 1000 });
  assert.equal(budget.admit(10), true);
  assert.equal(budget.admit(10), true);
  assert.equal(budget.admit(10), true);
  // A per-type limit cannot see this: the point of an aggregate is that a client cannot
  // spend its way past one budget by spreading traffic across several frame types.
  assert.equal(budget.admit(10), false);
});

test('the byte budget refuses a flood of large frames the frame count would allow', () => {
  const budget = new SocketBudget({ frames: 100, bytes: 500, windowMs: 1000 });
  assert.equal(budget.admit(400), true);
  assert.equal(budget.admit(99), true);
  assert.equal(budget.admit(2), false, 'over the byte ceiling with frames to spare');
});

test('a budget refills when its window rolls over', () => {
  let now = 0;
  const budget = new SocketBudget({ frames: 1, bytes: 100, windowMs: 1000 }, () => now);
  assert.equal(budget.admit(10), true);
  assert.equal(budget.admit(10), false);
  now = 1001;
  assert.equal(budget.admit(10), true, 'a new window is a new allowance');
});

test('a keyed limiter still limits per key', () => {
  let now = 0;
  const map = new BoundedRateMap({ max: 100, limit: 2, windowMs: 1000 }, () => now);
  assert.equal(map.admit('a'), true);
  assert.equal(map.admit('a'), true);
  assert.equal(map.admit('a'), false);
  assert.equal(map.admit('b'), true, 'a different key has its own allowance');
  now = 1001;
  assert.equal(map.admit('a'), true, 'and it refills');
});

test('the keyed limiter cannot be grown without bound by inventing keys', () => {
  const map = new BoundedRateMap({ max: 8, limit: 5, windowMs: 60_000 });
  for (let i = 0; i < 5000; i++) map.admit(`share-${i}`);
  assert.ok(map.size <= 8, `map grew to ${map.size}, past its ceiling`);
});

test('evicting the oldest key does not hand the newest one a fresh allowance', () => {
  let now = 0;
  const map = new BoundedRateMap({ max: 2, limit: 1, windowMs: 60_000 }, () => now);
  assert.equal(map.admit('hot'), true);
  assert.equal(map.admit('hot'), false);
  // Push 'hot' out of the map with unrelated keys, then come back to it. If eviction reset
  // its allowance, a client could dodge the limit by cycling keys — which is precisely the
  // bypass the old unbounded map had, in a different shape.
  map.admit('x'); map.admit('y'); map.admit('z');
  assert.equal(map.admit('hot'), false, 'an evicted key must not refill early');
  now = 60_001;
  assert.equal(map.admit('hot'), true, 'only the clock refills it');
});

test('stale keys are dropped so a long-lived socket does not retain dead shares', () => {
  let now = 0;
  const map = new BoundedRateMap({ max: 100, limit: 5, windowMs: 1000 }, () => now);
  for (let i = 0; i < 50; i++) map.admit(`share-${i}`);
  assert.equal(map.size, 50);
  now = 10_000;
  map.admit('fresh');
  assert.ok(map.size < 50, `expired entries were not pruned (size ${map.size})`);
});

// ── narrow(): a client may address fewer people than it is entitled to, never more ──

test('a client list narrows the derived audience and can never widen it', () => {
  const audience = ['a', 'b', 'c'];
  assert.deepEqual(narrow(audience, ['b']), ['b']);
  assert.deepEqual(narrow(audience, ['b', 'c']), ['b', 'c']);
  // The whole point: an id the sender is not entitled to address is dropped, not published to.
  assert.deepEqual(narrow(audience, ['b', 'outsider']), ['b']);
  assert.deepEqual(narrow(audience, ['outsider']), []);
});

test('no list means the whole audience, which is what typing wants', () => {
  const audience = ['a', 'b'];
  assert.deepEqual(narrow(audience, undefined), audience);
  assert.deepEqual(narrow(audience, []), audience);
  assert.deepEqual(narrow(audience, 'not-an-array'), audience);
});

test('a repeated or malformed id costs one publish, not many', () => {
  const audience = ['a', 'b'];
  assert.deepEqual(narrow(audience, ['a', 'a', 'a', 'a']), ['a'], 'duplicates collapse');
  assert.deepEqual(narrow(audience, [null, 42, {}, 'a']), ['a'], 'non-strings are ignored');
});

test('an empty audience stays empty whatever the client asks for', () => {
  assert.deepEqual(narrow([], ['a', 'b']), []);
  assert.deepEqual(narrow([], undefined), []);
});
