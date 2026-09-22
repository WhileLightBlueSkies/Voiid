// The relay's clocks are only correct relative to each other. Each of these held at the time
// it was written and none of them is visible from the value it constrains, so they are pinned
// here rather than left to a reader noticing a comment.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  HEARTBEAT_INTERVAL_MS,
  LEASE_TTL_MS,
  REAUTH_INTERVAL_MS,
  SESSION_STATE_TTL_MS,
} from '../src/cadence';

test('the lease is renewed several times over before it could expire', () => {
  // Not merely "less than": one missed tick must not cost a socket its presence.
  assert.ok(
    HEARTBEAT_INTERVAL_MS * 2 < LEASE_TTL_MS,
    `heartbeat ${HEARTBEAT_INTERVAL_MS}ms leaves no margin under a ${LEASE_TTL_MS}ms lease`
  );
});

test('re-authorization is served from the session cache, not from Postgres', () => {
  // THE REGRESSION THIS EXISTS FOR. A re-auth interval at or above the cache TTL does not
  // cache badly — it cannot hit at all, because the entry is always already expired when the
  // next check runs. That turns every live socket into a recurring database client.
  assert.ok(
    REAUTH_INTERVAL_MS < SESSION_STATE_TTL_MS,
    `re-auth every ${REAUTH_INTERVAL_MS}ms against a ${SESSION_STATE_TTL_MS}ms cache misses every time`
  );
});

test('re-authorization is rarer than the ping it used to share a timer with', () => {
  assert.ok(
    REAUTH_INTERVAL_MS > HEARTBEAT_INTERVAL_MS,
    'a re-auth on every ping is the shape that caused the problem'
  );
});

test('the re-auth interval lands on a heartbeat tick, so the clock is honoured', () => {
  // The check runs INSIDE the heartbeat, so the real cadence is rounded up to a multiple of
  // it. A value that is not a multiple silently drifts later than it reads.
  assert.equal(
    REAUTH_INTERVAL_MS % HEARTBEAT_INTERVAL_MS, 0,
    `re-auth every ${REAUTH_INTERVAL_MS}ms actually fires every ${
      Math.ceil(REAUTH_INTERVAL_MS / HEARTBEAT_INTERVAL_MS) * HEARTBEAT_INTERVAL_MS}ms`
  );
});
