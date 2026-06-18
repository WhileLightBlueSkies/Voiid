// VOIID — minimal SQL migration runner (run on the box during deploy).
//
// Applies every database/migrations/NNN_*.sql that hasn't been applied yet, in
// filename order, each inside its own transaction, and records it in a
// schema_migrations table so re-runs are no-ops. The .sql files are already
// idempotent (`if not exists`), but the ledger means we don't re-run them and
// a future non-idempotent migration is still applied exactly once.
//
// Connects with the same TLS rule as backend/api/src/db.ts (SSL for non-local).
// Reads DATABASE_URL from the environment — the deploy script invokes it via
// `node --env-file=/opt/voiid/.env` so it uses the same DEV creds as the API.
//
// Usage:  node --env-file=/opt/voiid/.env infrastructure/deployment/migrate.mjs

import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

// pg lives in the workspace node_modules (api dependency); resolve from there.
const require = createRequire(import.meta.url);
const { Client } = require('pg');

const __dirname = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = join(__dirname, '..', '..', 'database', 'migrations');

const url = process.env.DATABASE_URL ?? '';
if (!url) {
  console.error('[migrate] DATABASE_URL is not set');
  process.exit(1);
}
const isLocal = url.includes('localhost') || url.includes('127.0.0.1');

const client = new Client({
  connectionString: url,
  ssl: isLocal ? undefined : { rejectUnauthorized: false },
});

async function main() {
  await client.connect();

  await client.query(`
    create table if not exists schema_migrations (
      filename    text primary key,
      applied_at  timestamptz not null default now()
    )
  `);

  const applied = new Set(
    (await client.query('select filename from schema_migrations')).rows.map((r) => r.filename),
  );

  const files = readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .sort(); // 001_, 002_, ... 010_ — zero-padded so lexical == numeric order

  let ran = 0;
  for (const file of files) {
    if (applied.has(file)) continue;
    const sql = readFileSync(join(MIGRATIONS_DIR, file), 'utf8');
    process.stdout.write(`[migrate] applying ${file} ... `);
    try {
      await client.query('begin');
      await client.query(sql);
      await client.query('insert into schema_migrations (filename) values ($1)', [file]);
      await client.query('commit');
      console.log('ok');
      ran++;
    } catch (e) {
      await client.query('rollback').catch(() => {});
      console.log('FAILED');
      console.error(`[migrate] ${file} failed: ${e.message}`);
      throw e;
    }
  }

  console.log(
    ran === 0
      ? `[migrate] up to date (${files.length} migrations already applied)`
      : `[migrate] applied ${ran} new migration(s); ${files.length} total`,
  );
}

main()
  .then(() => client.end())
  .catch(async (e) => {
    await client.end().catch(() => {});
    console.error('[migrate] aborted:', e.message);
    process.exit(1);
  });
