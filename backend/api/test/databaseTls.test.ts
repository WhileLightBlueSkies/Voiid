// S05 — the database connection is encrypted AND the server on the other end is checked.
//
// Every service connected with `rejectUnauthorized: false`. TLS was on, so the traffic looked
// encrypted, and nothing verified WHO it was encrypted to — anyone able to sit between the box
// and Supabase could present any certificate and read or rewrite the entire database: every
// ciphertext envelope, every device row, every session.
//
// The local-development exemption was decided by `url.includes('localhost')` over the WHOLE
// connection string, so a password containing that word, or a host called
// `localhost.attacker.example`, silently turned verification off for a remote database.
import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveDatabaseSsl } from '@voiid/common-utils';

const REMOTE = 'postgres://user:secret@db.abcdefgh.supabase.co:5432/postgres';

test('a loopback database needs no TLS', () => {
  for (const url of [
    'postgres://postgres:postgres@localhost:5432/voiid',
    'postgres://postgres:postgres@127.0.0.1:5432/voiid',
    'postgres://postgres@[::1]:5432/voiid',
  ]) {
    assert.equal(resolveDatabaseSsl(url, {}), undefined, url);
  }
});

test('a remote database is verified, not merely encrypted', () => {
  const ssl = resolveDatabaseSsl(REMOTE, {});
  assert.ok(ssl, 'TLS must be on');
  assert.equal(ssl.rejectUnauthorized, true, 'and the certificate must actually be checked');
});

// THE BUG. `url.includes('localhost')` matched anywhere in the string.
test('the word localhost outside the hostname does not disable verification', () => {
  const cases = [
    // A password that happens to contain it.
    'postgres://user:localhost@db.abcdefgh.supabase.co:5432/postgres',
    // A hostname an attacker can register that merely starts with it.
    'postgres://user:secret@localhost.attacker.example:5432/postgres',
    // ...or ends with it.
    'postgres://user:secret@db.notlocalhost:5432/postgres',
    // A database name containing it.
    'postgres://user:secret@db.abcdefgh.supabase.co:5432/localhost',
    // The loopback address as part of a longer host.
    'postgres://user:secret@127.0.0.1.attacker.example:5432/postgres',
  ];
  for (const url of cases) {
    const ssl = resolveDatabaseSsl(url, {});
    assert.ok(ssl, `TLS was disabled for ${url}`);
    assert.equal(ssl.rejectUnauthorized, true, `verification was disabled for ${url}`);
  }
});

test('a supplied CA is used to verify, without turning verification off', () => {
  const ssl = resolveDatabaseSsl(REMOTE, { VOIID_DB_CA_CERT: '-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----' });
  assert.ok(ssl);
  assert.equal(ssl.rejectUnauthorized, true);
  assert.match(String(ssl.ca), /BEGIN CERTIFICATE/);
});

test('the insecure escape hatch works, but only when asked for explicitly', () => {
  const ssl = resolveDatabaseSsl(REMOTE, { VOIID_DB_TLS_INSECURE: '1' });
  assert.ok(ssl);
  assert.equal(ssl.rejectUnauthorized, false, 'the documented staged-rollout escape');
  // Anything other than the exact opt-in keeps verification on: a stray value in a deploy
  // env must not be a way to turn certificate checking off by accident.
  for (const value of ['0', 'false', 'true', 'yes', '', ' 1']) {
    const guarded = resolveDatabaseSsl(REMOTE, { VOIID_DB_TLS_INSECURE: value });
    assert.equal(guarded!.rejectUnauthorized, true, `VOIID_DB_TLS_INSECURE=${JSON.stringify(value)} disabled verification`);
  }
});

// "Validate node-postgres connection-string SSL options so they cannot silently override
// the intended policy."
test('a connection string cannot quietly downgrade the policy', () => {
  for (const url of [
    `${REMOTE}?sslmode=disable`,
    `${REMOTE}?sslmode=no-verify`,
    `${REMOTE}?sslmode=prefer`,
    `${REMOTE}?ssl=false`,
  ]) {
    assert.throws(
      () => resolveDatabaseSsl(url, {}),
      /sslmode|ssl option/i,
      `${url} was accepted instead of refused`
    );
  }
});

test('an sslmode that agrees with the policy is accepted', () => {
  for (const url of [`${REMOTE}?sslmode=verify-full`, `${REMOTE}?sslmode=require`]) {
    const ssl = resolveDatabaseSsl(url, {});
    assert.ok(ssl);
    assert.equal(ssl.rejectUnauthorized, true);
  }
  // A loopback URL may say disable, because that is what it already is.
  assert.equal(resolveDatabaseSsl('postgres://postgres@localhost:5432/voiid?sslmode=disable', {}), undefined);
});

test('an unset URL expresses no opinion; an unparseable one fails closed', () => {
  assert.equal(resolveDatabaseSsl('', {}), undefined, 'nothing to connect to yet');
  const ssl = resolveDatabaseSsl('not a url at all', {});
  assert.ok(ssl, 'an unreadable URL must never be treated as local');
  assert.equal(ssl.rejectUnauthorized, true);
});

// The guard: the bug was four copies of the same two lines, and the fix is worth nothing if
// one of them grows the old shape back.
test('no service reintroduces unverified TLS or substring host matching', async () => {
  const { readFile } = await import('node:fs/promises');
  const { resolve } = await import('node:path');
  const root = resolve(__dirname, '../../..');
  const files = [
    'backend/api/src/db.ts',
    'backend/games/src/db.ts',
    'backend/workers/src/db.ts',
    'infrastructure/deployment/migrate.mjs',
    // Added in S03 and, until this change, carrying the same unverified form.
    'backend/websocket/src/session.ts',
  ];
  for (const file of files) {
    const source = (await readFile(resolve(root, file), 'utf8'))
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .split('\n').filter((line) => !line.trim().startsWith('//')).join('\n');
    assert.ok(
      !/rejectUnauthorized:\s*false/.test(source),
      `${file} disables certificate verification directly instead of going through the shared policy`
    );
    assert.ok(
      !/includes\(['"]localhost['"]\)/.test(source),
      `${file} decides "is this local" by substring again — that is the bug, not the check`
    );
    assert.ok(
      /resolveDatabaseSsl/.test(source),
      `${file} must use the shared, tested policy rather than its own`
    );
  }
});
