// The PAN ↔ Aadhaar name comparison the reviewer sees. Names differ in initials and order
// between the two documents, so this must accept those and nothing looser.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { namesMatch } from '../src/kycNames';

test('same person across PAN and Aadhaar spellings', () => {
  assert.equal(namesMatch('RAHUL KUMAR SHARMA', 'Rahul Kumar Sharma'), true);
  assert.equal(namesMatch('R. K. SHARMA', 'Rahul Kumar Sharma'), true);       // initials
  assert.equal(namesMatch('SHARMA RAHUL', 'Rahul Sharma'), true);              // order
  assert.equal(namesMatch('Rahul Sharma', 'RAHUL KUMAR SHARMA'), true);        // middle name missing
});

test('different people do not match', () => {
  assert.equal(namesMatch('Rahul Sharma', 'Rohit Sharma'), false);
  assert.equal(namesMatch('R. Verma', 'Rahul Sharma'), false);
  assert.equal(namesMatch('', 'Rahul Sharma'), false);
});
