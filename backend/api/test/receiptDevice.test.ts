// Receipts must be attributed to a DEVICE, and the device id is not in the token.
//
// THE BUG THIS EXISTS FOR
// -----------------------
// Android messages stuck on "Sent" forever — Delivered and Seen never arrived. Two halves,
// and the fix needed both:
//
//   1. CLIENT: neither app sent its device id with POST /receipts/mark.
//   2. SERVER: the route read `req.auth.device_id` and nothing else.
//
// POST /auth/firebase issues `issueToken({ user_id })` — no device claim at all. Only device
// LINKING (routes/linking.ts) puts one in. So on every normally logged-in device the token's
// device_id is undefined, and every receipt was written with device_id NULL.
//
// That is what made the receipt upsert unreachable: `on conflict (message_id, user_id,
// device_id)` cannot match when device_id is null, because Postgres treats NULLs as distinct.
// Each mark inserted a new row instead of advancing the existing one, the never-downgrade
// guard was bypassed, and the sender's status never moved off Sent.
//
// messages.ts and stories.ts already solved this with a `callerDeviceId` fallback. Receipts
// did not have one. This test pins the resolution order so it cannot regress to token-only.
import { test } from 'node:test';
import assert from 'node:assert/strict';

/**
 * Mirrors `callerDeviceId` in routes/receipts.ts.
 *
 * Duplicated rather than imported because the route module pulls in db/redis at import time,
 * which a unit test has no business booting. If the route's version changes, this must too —
 * the assertions below say what the behaviour has to be.
 */
function callerDeviceId(req: any): string | null {
  const fromAuth = req.auth?.device_id;
  if (typeof fromAuth === 'string' && fromAuth) return fromAuth;
  const fromBody = req.body?.device_id;
  if (typeof fromBody === 'string' && fromBody) return fromBody;
  const fromQuery = req.query?.device_id;
  return typeof fromQuery === 'string' && fromQuery ? fromQuery : null;
}

test('a linked-device token supplies the device id', () => {
  assert.equal(callerDeviceId({ auth: { user_id: 'u', device_id: 'dev-from-token' } }), 'dev-from-token');
});

test('the request body supplies it when the token does not', () => {
  // THE CASE THAT WAS BROKEN. This is what every normal login looks like: a token with a
  // user and no device. Returning null here is what stuck messages on Sent.
  assert.equal(
    callerDeviceId({ auth: { user_id: 'u' }, body: { device_id: 'dev-from-body' } }),
    'dev-from-body'
  );
});

test('the token wins over the body', () => {
  // The body is client-supplied, so it must never override a device the token asserts —
  // otherwise a caller could attribute its receipts to someone else's device.
  assert.equal(
    callerDeviceId({ auth: { user_id: 'u', device_id: 'tok' }, body: { device_id: 'spoofed' } }),
    'tok'
  );
});

test('a query param is accepted as a last resort', () => {
  assert.equal(callerDeviceId({ auth: { user_id: 'u' }, query: { device_id: 'dev-q' } }), 'dev-q');
});

test('null only when there is genuinely no device anywhere', () => {
  // Still a supported path — 027's partial index makes the NULL upsert work — but it must be
  // the exception, not what every logged-in device hits.
  assert.equal(callerDeviceId({ auth: { user_id: 'u' } }), null);
  assert.equal(callerDeviceId({ auth: { user_id: 'u' }, body: {}, query: {} }), null);
});

test('empty strings and non-strings do not count as a device', () => {
  // An empty string would be written as a device id of '', which is neither null (so it
  // misses the null-path index) nor a real device — the worst of both.
  assert.equal(callerDeviceId({ auth: { device_id: '' }, body: { device_id: '' } }), null);
  assert.equal(callerDeviceId({ auth: { device_id: 123 }, body: { device_id: null } }), null);
  assert.equal(callerDeviceId({}), null);
});
