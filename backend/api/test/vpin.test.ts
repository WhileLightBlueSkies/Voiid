// V PIN — the pure rules: the proof both apps must compute, the verifier, the sealing, and
// the lock. The database half (the row lock, the routes) is vpinPostgres.test.ts.
import test from 'node:test';
import assert from 'node:assert/strict';
import { pbkdf2Sync, randomBytes } from 'node:crypto';

process.env.VOIID_SECRETBOX_KEY = randomBytes(32).toString('base64');

import { resetSecretboxKeyForTests } from '../src/secretbox';
import {
  PROOF_BYTES,
  PROOF_ITERATIONS,
  PROOF_SALT_PREFIX,
  VPIN_LOCK_MS,
  VPIN_MAX_ATTEMPTS,
  afterWrongProof,
  attemptsLeft,
  decodeExact,
  lockSecondsLeft,
  openEnvelope,
  proofMatches,
  sealEnvelope,
  verifierFor,
} from '../src/vpin';

resetSecretboxKeyForTests();

/** The proof exactly as the apps build it. */
function proofOf(pin: string, salt: Buffer): Buffer {
  return pbkdf2Sync(Buffer.from(pin, 'utf8'),
    Buffer.concat([Buffer.from(PROOF_SALT_PREFIX, 'utf8'), salt]),
    PROOF_ITERATIONS, PROOF_BYTES, 'sha256');
}

// THE CROSS-PLATFORM CONTRACT. iOS VPinProof.swift and Android VPinProof.kt carry this same
// vector in their own checks. If any of the three changes, restore breaks across platforms:
// a PIN set on an iPhone could never be unlocked from an Android phone.
test('known-answer proof: pin 24681357, salt 00..0f', () => {
  const salt = Buffer.from('000102030405060708090a0b0c0d0e0f', 'hex');
  assert.equal(proofOf('24681357', salt).toString('base64'),
    '+UVIgV0f50UAMTdE4+wxE22X62xIZX1Gxyos9o1wzyA=');
});

test('the right proof matches; a different PIN does not', () => {
  const salt = randomBytes(16);
  const verifier = verifierFor(proofOf('24681357', salt));
  assert.equal(proofMatches(proofOf('24681357', salt), verifier), true);
  assert.equal(proofMatches(proofOf('24681358', salt), verifier), false);
});

test('the verifier is not the proof, and needs the server key', () => {
  const proof = proofOf('24681357', randomBytes(16));
  const verifier = verifierFor(proof);
  assert.notEqual(verifier, proof.toString('base64'));

  // Same proof under a DIFFERENT server key gives a different verifier — a database copy
  // without the key cannot test guesses against what is stored.
  process.env.VOIID_SECRETBOX_KEY = randomBytes(32).toString('base64');
  resetSecretboxKeyForTests();
  assert.notEqual(verifierFor(proof), verifier);
});

test('a sealed envelope opens only for its owner', () => {
  const envelope = { version: 1, salt: 'c2FsdA==', nonce: 'bm9uY2U=', ciphertext: 'Y2lwaGVy' };
  const sealed = sealEnvelope('user-a', envelope);
  assert.ok(!sealed.includes('Y2lwaGVy'), 'the envelope must not appear in the sealed text');
  assert.deepEqual(openEnvelope('user-a', sealed), envelope);
  assert.equal(openEnvelope('user-b', sealed), null, 'copied to another account, it must not open');
  assert.equal(openEnvelope('user-a', sealed.slice(0, -2) + 'AA'), null, 'tampered, it must not open');
});

test('5 wrong proofs lock for 24 hours, then the count starts fresh', () => {
  const now = Date.parse('2026-09-29T00:00:00Z');
  let state = { failedAttempts: 0, lockedUntil: null as Date | null };
  for (let i = 1; i < VPIN_MAX_ATTEMPTS; i++) {
    state = afterWrongProof(state, now);
    assert.equal(state.lockedUntil, null, `wrong #${i} must not lock`);
    assert.equal(attemptsLeft(state), VPIN_MAX_ATTEMPTS - i);
  }
  state = afterWrongProof(state, now);
  assert.equal(state.lockedUntil?.getTime(), now + VPIN_LOCK_MS, 'wrong #5 locks for exactly 24h');
  assert.equal(state.failedAttempts, 0, 'the counter resets, so after the lock there are 5 again');
  assert.equal(VPIN_MAX_ATTEMPTS, 5);
  assert.equal(VPIN_LOCK_MS, 24 * 60 * 60 * 1000);
});

test('lock time left', () => {
  const now = Date.parse('2026-09-29T00:00:00Z');
  assert.equal(lockSecondsLeft(null, now), null);
  assert.equal(lockSecondsLeft(new Date(now - 1), now), null, 'an expired lock is no lock');
  assert.equal(lockSecondsLeft(new Date(now + 90_500), now), 91);
});

test('strict base64 decoding of fixed-size inputs', () => {
  const ok = randomBytes(32).toString('base64');
  assert.ok(decodeExact(ok, 32));
  assert.equal(decodeExact(ok, 16), null, 'wrong length');
  assert.equal(decodeExact(ok.replace(/=+$/, ''), 32), null, 'non-canonical padding');
  assert.equal(decodeExact(ok.replaceAll('+', '-').replaceAll('/', '_'), 32) === null ||
    !/[+/]/.test(ok), true, 'url alphabet refused');
  assert.equal(decodeExact(' ' + ok, 32), null, 'whitespace');
  assert.equal(decodeExact(12345, 32), null, 'not a string');
});
