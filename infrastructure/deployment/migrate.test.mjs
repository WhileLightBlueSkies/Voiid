import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { Client } = require('pg');
const url = process.env.MIGRATION_TEST_DATABASE_URL;
const hash = s => createHash('sha256').update(s).digest('hex');

test('migration locking, rollback, drift and explicit legacy baseline', { skip: !url }, async () => {
  const { runMigrations } = await import('./migrate.mjs');
  const schema = `migration_test_${process.pid}_${Date.now()}`;
  const admin = new Client({ connectionString: url });
  await admin.connect();
  await admin.query(`create schema ${schema}`);
  const clients = [];
  const dir = mkdtempSync(join(tmpdir(), 'voiid-migrations-'));
  const connect = async () => {
    const c = new Client({ connectionString: url }); await c.connect();
    await c.query(`set search_path to ${schema}`); clients.push(c); return c;
  };
  try {
    const a = await connect(), b = await connect();
    const first = 'create table events (id int); insert into events values (1); select pg_sleep(0.15);';
    writeFileSync(join(dir, '001_first.sql'), first);
    await Promise.all([runMigrations(a, { directory: dir }), runMigrations(b, { directory: dir })]);
    assert.equal((await a.query('select count(*)::int n from events')).rows[0].n, 1);
    writeFileSync(join(dir, '001_first.sql'), first + '\n-- edit');
    await assert.rejects(runMigrations(a, { directory: dir }), /checksum mismatch/);
    writeFileSync(join(dir, '001_first.sql'), first);
    writeFileSync(join(dir, '002_bad.sql'), 'insert into events values (2); select nonexistent_column from events;');
    await assert.rejects(runMigrations(a, { directory: dir }), /nonexistent_column/);
    assert.equal((await a.query('select count(*)::int n from events')).rows[0].n, 1);
    assert.equal((await a.query("select count(*)::int n from schema_migrations where filename='002_bad.sql'")).rows[0].n, 0);
    rmSync(join(dir, '002_bad.sql'));
    await a.query('update schema_migrations set checksum = null');
    await assert.rejects(runMigrations(a, { directory: dir }), /reviewed baseline/);
    await assert.rejects(runMigrations(a, { directory: dir, baseline: { '001_first.sql': '0'.repeat(64) } }), /reviewed baseline/);
    await runMigrations(a, { directory: dir, baseline: { '001_first.sql': hash(first) } });
    assert.equal((await a.query('select checksum from schema_migrations')).rows[0].checksum, hash(first));
    writeFileSync(join(dir, '002_index.sql'), '-- migrate:transaction off\ncreate index concurrently event_id on events(id);');
    await runMigrations(a, { directory: dir });
    writeFileSync(join(dir, '003_partial.sql'), '-- migrate:transaction off\nselect nonexistent_column from events;');
    await assert.rejects(runMigrations(a, { directory: dir }), /nonexistent_column/);
    await assert.rejects(runMigrations(a, { directory: dir }), /incomplete nontransactional/);
    // The lock is released on errors (another connection can acquire it).
    await b.query("set statement_timeout='2s'");
    await assert.rejects(runMigrations(b, { directory: dir }), /incomplete nontransactional/);
  } finally {
    for (const c of clients) await c.end();
    await admin.query(`drop schema ${schema} cascade`); await admin.end();
    rmSync(dir, { recursive: true, force: true });
  }
});
