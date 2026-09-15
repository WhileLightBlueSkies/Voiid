import test from 'node:test';
import assert from 'node:assert/strict';
import { callDiagnostic } from '../src/callDiagnostics';

test('diagnostics expire and exclude media/key events', () => {
  for (const until of [0, 10, NaN, Infinity])
    assert.equal(callDiagnostic('call_hangup', 'local-hangup', 'allowed', until, 10), null);
  for (const type of ['call_ice', 'call_key', 'message', { secret: 'private' }])
    assert.equal(callDiagnostic(type, 'private', 'received', 20, 10), null);
});
test('diagnostics retain known reasons and redact arbitrary client content', () => {
  assert.deepEqual(callDiagnostic('call_hangup', 'local-hangup', 'allowed', 20, 10), {
    at: new Date(10).toISOString(), event: 'call_hangup', decision: 'allowed', reason: 'local-hangup',
  });
  for (const reason of ['phone-number-or-secret', { token: 'secret' }, null])
    assert.equal(callDiagnostic('call_hangup', reason, 'received', 20, 10)?.reason, 'unspecified');
});
