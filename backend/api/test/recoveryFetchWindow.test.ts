import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Pool } from 'pg';

const url = process.env.RECOVERY_TEST_DATABASE_URL;
test('recovery fetch cooldown expires without retry requests extending it', { skip: !url }, async () => {
  assert.ok(['localhost', '127.0.0.1'].includes(new URL(url!).hostname));
  const schema = `backup_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema}` });
  try {
    await db.query('create table recovery_keys(user_id uuid primary key, fetch_count integer not null default 0, last_fetched_at timestamptz, locked_until timestamptz, wrapped_key jsonb)');
    const source = readFileSync(resolve(__dirname, '../src/routes/recovery.ts'), 'utf8');
    const match = source.match(/`(update recovery_keys\s+set fetch_count = case[\s\S]*?)`/);
    assert.ok(match, 'test must exercise the production atomic update');
    const user = randomUUID();
    await db.query('insert into recovery_keys(user_id) values($1)', [user]);
    const fetch = () => db.query(match![1], [user, 25, 86400]).then(r => r.rows[0]);
    const results = await Promise.all(Array.from({ length: 30 }, fetch));
    assert.equal(results.filter(r => r.fetch_count <= 25).length, 25);
    const locked = await fetch();
    assert.equal(locked.fetch_count, 26);
    const retried = await fetch();
    assert.equal(+retried.last_fetched_at, +locked.last_fetched_at, 'blocked retries must not extend the cooldown');
    await db.query("update recovery_keys set last_fetched_at=now()-interval '25 hours' where user_id=$1", [user]);
    const expired = await fetch();
    assert.equal(expired.fetch_count, 1, 'the advertised wait must eventually allow recovery again');
    assert.ok(Date.now() - +expired.last_fetched_at < 5000);
    const lockUpdate = source.match(/`(update recovery_keys set locked_until = greatest[\s\S]*?)`/);
    assert.ok(lockUpdate);
    const later = new Date(Date.now() + 3600000);
    await db.query('update recovery_keys set locked_until=$2 where user_id=$1', [user, later]);
    await db.query(lockUpdate![1], [user, new Date(Date.now() + 900000)]);
    await db.query(lockUpdate![1], [user, null]);
    const retained = (await db.query('select locked_until from recovery_keys where user_id=$1', [user])).rows[0];
    assert.equal(+retained.locked_until, +later, 'out-of-order failures cannot shorten an existing cooldown');
  } finally {
    await db.end();
    await admin.query(`drop schema ${schema} cascade`);
    await admin.end();
  }
});
