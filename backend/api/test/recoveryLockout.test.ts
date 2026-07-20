// The online PIN guess-limiting state machine.
//
// This is what stands between an attacker holding a stolen JWT and an exhaustive
// online search of a 6-digit PIN. A regression here is silent (nothing errors; the
// lock just stops locking), so every transition is asserted explicitly.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  applyFailure,
  applySuccess,
  lockRetryAfter,
  isValidWrappedKey,
  pickWrappedKey,
  LOCK_THRESHOLD,
  LOCK_COOLDOWNS_MS,
} from '../src/recoveryLockout';

const T0 = 1_700_000_000_000;

// --- Failure counting ---------------------------------------------------------------

test('each failure increments the counter by exactly one', () => {
  assert.equal(applyFailure(0, T0).failed_attempts, 1);
  assert.equal(applyFailure(4, T0).failed_attempts, 5);
  assert.equal(applyFailure(8, T0).failed_attempts, 9);
});

test('no lock is applied below the threshold', () => {
  for (let prev = 0; prev < LOCK_THRESHOLD - 1; prev++) {
    const s = applyFailure(prev, T0);
    assert.equal(s.locked_until, null, `locked early at attempt ${s.failed_attempts}`);
    assert.equal(s.retry_after, undefined);
  }
});

test('the lock engages exactly ON the threshold attempt, not before or after', () => {
  const justBefore = applyFailure(LOCK_THRESHOLD - 2, T0); // -> attempt 9
  assert.equal(justBefore.failed_attempts, LOCK_THRESHOLD - 1);
  assert.equal(justBefore.locked_until, null);

  const atThreshold = applyFailure(LOCK_THRESHOLD - 1, T0); // -> attempt 10
  assert.equal(atThreshold.failed_attempts, LOCK_THRESHOLD);
  assert.ok(atThreshold.locked_until, 'must lock at the threshold');
  assert.equal(atThreshold.locked_until!.getTime(), T0 + LOCK_COOLDOWNS_MS[0]);
});

// --- Escalating cooldowns -----------------------------------------------------------

test('cooldowns escalate 15m -> 1h -> 24h past the threshold', () => {
  const first = applyFailure(LOCK_THRESHOLD - 1, T0); // 10th failure
  const second = applyFailure(LOCK_THRESHOLD, T0); // 11th
  const third = applyFailure(LOCK_THRESHOLD + 1, T0); // 12th

  assert.equal(first.locked_until!.getTime() - T0, 15 * 60_000);
  assert.equal(second.locked_until!.getTime() - T0, 60 * 60_000);
  assert.equal(third.locked_until!.getTime() - T0, 24 * 60 * 60_000);
  // Strictly increasing — the whole point of escalation.
  assert.ok(first.locked_until! < second.locked_until!);
  assert.ok(second.locked_until! < third.locked_until!);
});

test('the cooldown caps at the longest entry and never wraps back to a short one', () => {
  const cap = LOCK_COOLDOWNS_MS[LOCK_COOLDOWNS_MS.length - 1];
  for (const prev of [LOCK_THRESHOLD + 2, LOCK_THRESHOLD + 50, 10_000]) {
    const s = applyFailure(prev, T0);
    assert.equal(
      s.locked_until!.getTime() - T0,
      cap,
      `attempt ${s.failed_attempts} did not stay at the cap`
    );
  }
});

test('a locked state reports retry_after in seconds', () => {
  const s = applyFailure(LOCK_THRESHOLD - 1, T0);
  assert.equal(s.retry_after, 900); // 15 minutes
  const long = applyFailure(LOCK_THRESHOLD + 5, T0);
  assert.equal(long.retry_after, 86_400);
});

test('an attacker cannot outrun the lock: 30 straight failures stay locked', () => {
  let failed = 0;
  let last: ReturnType<typeof applyFailure> | null = null;
  for (let i = 0; i < 30; i++) {
    last = applyFailure(failed, T0);
    failed = last.failed_attempts;
  }
  assert.equal(failed, 30);
  assert.ok(last!.locked_until, 'still must be locked after 30 failures');
  assert.equal(last!.locked_until!.getTime() - T0, 24 * 60 * 60_000);
});

// --- Success resets ------------------------------------------------------------------

test('a successful unwrap resets the counter and clears the lock', () => {
  const s = applySuccess();
  assert.equal(s.failed_attempts, 0);
  assert.equal(s.locked_until, null);
});

test('after a success the next failure starts the count over at 1, unlocked', () => {
  applySuccess();
  const next = applyFailure(0, T0);
  assert.equal(next.failed_attempts, 1);
  assert.equal(next.locked_until, null);
});

// --- Retry-After / 429 behaviour -----------------------------------------------------

test('lockRetryAfter returns remaining seconds while locked', () => {
  const until = new Date(T0 + 90_000);
  assert.equal(lockRetryAfter(until, T0), 90);
  assert.equal(lockRetryAfter(until, T0 + 30_000), 60);
});

test('lockRetryAfter rounds partial seconds UP (never advertises 0 while locked)', () => {
  assert.equal(lockRetryAfter(new Date(T0 + 1), T0), 1);
  assert.equal(lockRetryAfter(new Date(T0 + 1500), T0), 2);
});

test('lockRetryAfter returns null once the lock has expired — the 429 stops', () => {
  const until = new Date(T0 + 1000);
  assert.equal(lockRetryAfter(until, T0 + 1000), null); // exactly at expiry
  assert.equal(lockRetryAfter(until, T0 + 5000), null);
  assert.equal(lockRetryAfter(null, T0), null);
});

// --- Wrapped-key envelope validation --------------------------------------------------

const GOOD = { version: 1, salt: 'c2FsdA==', nonce: 'bm9uY2U', ciphertext: 'Y2lwaGVy' };

test('accepts a well-formed PinWrappedSecret envelope', () => {
  assert.equal(isValidWrappedKey(GOOD), true);
});

test('accepts unpadded and base64url alphabets (vodozemac emits both)', () => {
  assert.equal(isValidWrappedKey({ ...GOOD, ciphertext: 'a-b_c' }), true);
  assert.equal(isValidWrappedKey({ ...GOOD, salt: 'YWJjZA' }), true);
});

test('rejects a non-object envelope', () => {
  for (const v of [null, undefined, 'x', 5, [], true]) {
    assert.equal(isValidWrappedKey(v), false, `accepted ${JSON.stringify(v)}`);
  }
});

test('rejects a missing or non-integer version', () => {
  assert.equal(isValidWrappedKey({ ...GOOD, version: undefined }), false);
  assert.equal(isValidWrappedKey({ ...GOOD, version: 1.5 }), false);
  assert.equal(isValidWrappedKey({ ...GOOD, version: '1' }), false);
});

test('rejects a missing, empty, or non-base64 component', () => {
  for (const field of ['salt', 'nonce', 'ciphertext']) {
    assert.equal(isValidWrappedKey({ ...GOOD, [field]: undefined }), false, `${field} missing`);
    assert.equal(isValidWrappedKey({ ...GOOD, [field]: '' }), false, `${field} empty`);
    assert.equal(isValidWrappedKey({ ...GOOD, [field]: 'not base64!!' }), false, `${field} junk`);
    assert.equal(isValidWrappedKey({ ...GOOD, [field]: 42 }), false, `${field} non-string`);
  }
});

test('pickWrappedKey stores only the four known fields', () => {
  const picked = pickWrappedKey({
    ...GOOD,
    user_id: 'attacker',
    pin: '123456',
    note: 'extra',
  });
  assert.deepEqual(Object.keys(picked).sort(), ['ciphertext', 'nonce', 'salt', 'version']);
  assert.ok(!JSON.stringify(picked).includes('123456'));
  assert.ok(!JSON.stringify(picked).includes('attacker'));
});
