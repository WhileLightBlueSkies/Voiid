// Tests for the at-rest secretbox (src/secretbox.ts) — the reversible sealing that lets a
// user view their own contact PIN after setting it (migration 026).
//
// The properties under test are the ones whose failure would be SILENT: a reused nonce, a
// ciphertext that decrypts under the wrong key, or an unset key quietly storing plaintext.
// Each of those looks like working software right up until it is a breach.
import { test } from 'node:test';
import assert from 'node:assert/strict';

const KEY_A = Buffer.alloc(32, 1).toString('base64');
const KEY_B = Buffer.alloc(32, 2).toString('base64');

/**
 * Point the module at a given key.
 *
 * `secretboxKey()` memoises — deliberately, since it is on the request path — so setting
 * process.env alone would not be observed after the first read. An earlier version of this
 * helper tried to defeat that by re-importing with a cache-busting query string; Node
 * resolved it to the SAME module instance, so the three tests that need a different key
 * silently ran against the first one and two of them passed for the wrong reason.
 */
async function load(key: string | undefined, _tag?: string) {
  if (key === undefined) delete process.env.VOIID_SECRETBOX_KEY;
  else process.env.VOIID_SECRETBOX_KEY = key;
  const mod = await import('../src/secretbox.js');
  mod.resetSecretboxKeyForTests();
  return mod;
}

test('seal then open round-trips the value', async () => {
  const { seal, open } = await load(KEY_A);
  assert.equal(open(seal('418302')), '418302');
});

test('each encryption uses a fresh nonce', async () => {
  const { seal } = await load(KEY_A);

  // THE catastrophic failure mode for AES-GCM. Reusing a nonce under one key leaks the XOR
  // of the two plaintexts and enables forgery — for six-digit PINs drawn from a 10^6 space,
  // that is effectively a full break. Deterministic output would prove it instantly.
  const seen = new Set<string>();
  for (let i = 0; i < 200; i++) seen.add(seal('418302').split('.')[1]);
  assert.equal(seen.size, 200, 'nonce repeated across seal() calls');
});

test('identical plaintexts produce different ciphertexts', async () => {
  const { seal } = await load(KEY_A);

  // Without this, equal ciphertexts reveal equal PINs across the whole users table — an
  // attacker with a dump could bucket users and attack the largest bucket first.
  assert.notEqual(seal('000000'), seal('000000'));
});

test('a value sealed under one key does not open under another', async () => {
  // Sealed under A, then the key is swapped to B before opening. Sequential, not two live
  // instances: there is one module and one cached key, which is also how production behaves.
  const { seal } = await load(KEY_A);
  const sealed = seal('418302');

  const { open } = await load(KEY_B);
  // GCM authenticates, so a wrong key fails the tag check rather than returning garbage.
  // Returning plausible-looking digits here would be far worse than returning null.
  assert.equal(open(sealed), null);
});

test('tampered ciphertext is rejected rather than silently altered', async () => {
  const { seal, open } = await load(KEY_A);
  const sealed = seal('418302');
  const [v, nonce, blob] = sealed.split('.');

  const bytes = Buffer.from(blob, 'base64url');
  bytes[0] ^= 0xff;
  assert.equal(open([v, nonce, bytes.toString('base64url')].join('.')), null);
});

test('malformed and empty input returns null instead of throwing', async () => {
  const { open } = await load(KEY_A);

  // These sit on a settings-screen read path. One unparseable row must not 500 the endpoint,
  // which is why `open` returns null rather than propagating.
  for (const bad of [null, undefined, '', 'garbage', 'v1.only-two', 'v9.aaaa.bbbb']) {
    assert.equal(open(bad as any), null);
  }
});

test('with no key configured, sealing refuses rather than storing plaintext', async () => {
  const { seal, open, secretboxAvailable } = await load(undefined);

  // The important half of this test is the THROW. A misconfigured deployment must fail
  // loudly at the call site; falling back to writing the PIN in the clear would silently
  // remove the exact protection the module exists to provide.
  assert.equal(secretboxAvailable(), false);
  assert.throws(() => seal('418302'));
  assert.equal(open('v1.aaaa.bbbb'), null);
});

test('a wrong-length key is rejected at load, not at first use', async () => {
  const { secretboxKey } = await load(Buffer.alloc(16, 7).toString('base64'), 'shortkey');

  // Treating a malformed key as "no key" would downgrade storage to hash-only while the
  // operator believes encryption is on. Better to refuse to start.
  assert.throws(() => secretboxKey(), /32 bytes/);
});
