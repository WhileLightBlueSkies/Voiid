// Run only against the intended environment. See README.md for legacy baselining.
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
const directory = join(dirname(fileURLToPath(import.meta.url)), '../../database/migrations');
const checksum = bytes => createHash('sha256').update(bytes).digest('hex');

// Session lock: keep the SAME connection for the ledger, SQL and unlock, including
// nontransactional migrations. All environments/runners use this fixed key.
export async function runMigrations(client, { directory: dir = directory, baseline = {} } = {}) {
  await client.query('select pg_advisory_lock(862419, 1)');
  try {
    await client.query(`create table if not exists schema_migrations (
      filename text primary key, applied_at timestamptz not null default now(),
      checksum text, in_progress boolean not null default false
    )`);
    await client.query('alter table schema_migrations add column if not exists checksum text');
    await client.query('alter table schema_migrations add column if not exists in_progress boolean not null default false');
    const files = readdirSync(dir).filter(f => f.endsWith('.sql')).sort().map(filename => {
      const bytes = readFileSync(join(dir, filename));
      return { filename, sql: bytes.toString('utf8'), checksum: checksum(bytes) };
    });
    const byName = new Map(files.map(f => [f.filename, f]));
    const applied = (await client.query('select filename, checksum, in_progress from schema_migrations')).rows;
    // Check ALL history before applying anything. Never silently bless local bytes.
    for (const row of applied) {
      const file = byName.get(row.filename);
      if (!file) throw new Error(`Applied migration missing from artifact: ${row.filename}`);
      if (row.in_progress) throw new Error(`incomplete nontransactional migration ${row.filename}; inspect database effects and reconcile the ledger manually before retrying`);
      if (row.checksum === null) {
        if (baseline[row.filename] !== file.checksum) throw new Error(`${row.filename}: reviewed baseline required; supply MIGRATION_BASELINE_FILE from the previously deployed artifact`);
      } else if (row.checksum !== file.checksum) throw new Error(`${row.filename}: checksum mismatch; restore the applied file and add a new migration`);
    }
    for (const row of applied.filter(r => r.checksum === null)) {
      await client.query('update schema_migrations set checksum=$2 where filename=$1', [row.filename, byName.get(row.filename).checksum]);
    }
    const done = new Set(applied.map(r => r.filename));
    for (const file of files.filter(f => !done.has(f.filename))) {
      const outside = /^-- migrate:transaction off\r?\n/.test(file.sql);
      // Typos in an explicit directive must not silently change transaction semantics.
      if (/^-- migrate:transaction/m.test(file.sql) && !outside) throw new Error(`${file.filename}: unsupported transaction directive (must be first line: -- migrate:transaction off)`);
      try {
        if (outside) {
          // Persist intent BEFORE SQL: a crash between DDL and ledger completion cannot
          // cause automatic reexecution of a partially applied nontransactional change.
          await client.query('insert into schema_migrations (filename, checksum, in_progress) values ($1,$2,true)', [file.filename, file.checksum]);
        } else await client.query('begin');
        await client.query(file.sql);
        if (outside) await client.query('update schema_migrations set in_progress=false, applied_at=now() where filename=$1', [file.filename]);
        else {
          await client.query('insert into schema_migrations (filename, checksum) values ($1,$2)', [file.filename, file.checksum]);
          await client.query('commit');
        }
        console.log(`[migrate] applied ${file.filename} sha256=${file.checksum}`);
      } catch (error) {
        if (!outside) await client.query('rollback').catch(() => {});
        throw error;
      }
    }
  } finally {
    await client.query('select pg_advisory_unlock(862419, 1)');
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const require = createRequire(import.meta.url);
  const { Client } = require('pg');
  const { resolveDatabaseSsl, describeDatabaseTls } = require('@voiid/common-utils');
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error('[migrate] DATABASE_URL is not set');
  const ssl = resolveDatabaseSsl(url);
  console.log(`[migrate] ${describeDatabaseTls(ssl)}`);
  const client = new Client({ connectionString: url, ssl, connectionTimeoutMillis: 10000 });
  try {
    const baseline = process.env.MIGRATION_BASELINE_FILE ? JSON.parse(readFileSync(process.env.MIGRATION_BASELINE_FILE, 'utf8')) : {};
    await client.connect();
    await runMigrations(client, { baseline });
  } catch (error) {
    console.error('[migrate] aborted:', error.message); process.exitCode = 1;
  } finally { await client.end(); }
}
