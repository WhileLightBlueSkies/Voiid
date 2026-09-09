import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { initSync, WebIdentity, WebSession, encrypt_media, decrypt_media } from '../../../packages/e2e-core/bindings/wasm/pkg/voiid_e2e.js';
import { encodeWire, decodeWire } from '../src/protocol';
const base = new URL('../../../packages/e2e-core/bindings/wasm/', import.meta.url);
initSync({ module: readFileSync(new URL('pkg/voiid_e2e_bg.wasm', base)) });
const key = new Uint8Array(32).fill(7);
const text = new TextEncoder(), decode = new TextDecoder();
function native(input: object) {
  const run = spawnSync(fileURLToPath(new URL('target/debug/examples/interop', base)), [], { input: JSON.stringify(input), encoding: 'utf8' });
  assert.equal(run.status, 0, run.error?.message || run.stderr);
  return JSON.parse(run.stdout);
}
test('WASM ↔ native Olm: Unicode, wire format, ratchets and encrypted reload', () => {
  const web = new WebIdentity(), peer = native({ op: 'new' });
  const bundle = JSON.parse(web.publish_bundle(3));
  let session = web.initiate(peer.bundle.identity_key, peer.bundle.one_time_keys[0]);
  const first = decodeWire(encodeWire(session.encrypt(text.encode('Hello नमस्ते 👋'))));
  const received = native({ op: 'accept', identity: peer.identity, peer: bundle.identity_key, wire: first, reply: 'Hi from native' });
  assert.equal(received.text, 'Hello नमस्ते 👋');
  assert.equal(decode.decode(session.decrypt(received.wire)), 'Hi from native');
  const pickle = session.export_encrypted(key); session.free(); session = WebSession.restore(pickle, key);
  assert.equal(native({ op: 'decrypt', session: received.session, wire: session.encrypt(text.encode('After browser reload')) }).text, 'After browser reload');
  assert.throws(() => WebSession.restore(pickle, new Uint8Array(32).fill(9)));
  session.free(); web.free();
});
test('native initiates and WASM receives, then replies after identity/session restoration', () => {
  let web = new WebIdentity(); const bundle = JSON.parse(web.publish_bundle(3)), peer = native({ op: 'new' });
  const pickle = web.export_encrypted(key); web.free(); web = WebIdentity.restore(pickle, key);
  const first = native({ op: 'initiate', identity: peer.identity, peer: bundle.identity_key, prekey: bundle.one_time_keys[0], text: 'From iOS/Android core' });
  const accepted = web.accept(peer.bundle.identity_key, first.wire); let session = accepted.take_session();
  assert.equal(decode.decode(accepted.plaintext()), 'From iOS/Android core');
  const stored = session.export_encrypted(key); session.free(); session = WebSession.restore(stored, key);
  assert.equal(native({ op: 'decrypt', session: first.session, wire: session.encrypt(text.encode('Browser reply')) }).text, 'Browser reply');
  assert.throws(() => session.decrypt(first.wire), 'replay must be rejected');
  session.free(); accepted.free(); web.free();
});
test('attachment encryption interoperates and rejects modified ciphertext', () => {
  const encrypted = JSON.parse(encrypt_media(text.encode('private attachment')));
  assert.deepEqual(native({ op: 'media-decrypt', ...encrypted }).plaintext, [...text.encode('private attachment')]);
  const other = native({ op: 'media-encrypt', text: 'native attachment' });
  assert.equal(decode.decode(decrypt_media(JSON.stringify(other.media_key), Uint8Array.from(other.ciphertext))), 'native attachment');
  other.ciphertext[0] ^= 1;
  assert.throws(() => decrypt_media(JSON.stringify(other.media_key), Uint8Array.from(other.ciphertext)));
});
