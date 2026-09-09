import test from 'node:test';
import assert from 'node:assert/strict';
import { decodeWire } from '../src/protocol';
test('wire parser rejects non-Olm types and malformed envelopes', () => {
  for (const value of [{ t: 2, b: 'x' }, { t: 0, b: 1 }, {}]) assert.throws(() => decodeWire(btoa(JSON.stringify(value))));
});
