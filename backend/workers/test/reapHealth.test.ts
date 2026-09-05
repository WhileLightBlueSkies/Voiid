// C02/C04 — a reaper that does not lose what it could not delete, and health that says so.
// REAP_TEST_DATABASE_URL=postgres://.../voiid_test_reap npx tsx --test test/reapHealth.test.ts
//
// Its own database: every DB-backed suite replays the migration set and `create extension` is
// database-scoped, so two of them in one database race.
//
// C04. The story reaper deleted the story row in two situations where the OBJECT had not been
// deleted: when R2 was not configured at all, and after MAX_REAP_ATTEMPTS failures. The row is
// the only thing that knows the object's key, so deleting it left media in the bucket with
// nothing anywhere able to name it — and the comment justifying that pointed at a bucket
// lifecycle rule this audit could not verify.
//
// C02. Jobs catch their own errors and RETURN failure counts. The supervisor treated any
// returned value as success, so retention could fail every pass, or the reaper could abandon
// rows every pass, while /health stayed green.
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Pool } from 'pg';

const url = process.env.REAP_TEST_DATABASE_URL;
process.env.DATABASE_URL = url ?? '';

import { pool } from '../src/db';
import { classifyJob, type JobHealthInput } from '../src/health';

// ── C02: the health classifier, pure ───────────────────────────────────────────

const base: JobHealthInput = {
  name: 'reapStories',
  intervalMs: 300_000,
  now: 10_000_000,
  lastRunAt: 9_900_000,
  lastOkAt: 9_900_000,
  lastError: null,
  lastResult: { claimed: 0, failed: 0, abandoned: 0 },
  startedAt: null,
};

test('an empty successful sweep is healthy', () => {
  assert.equal(classifyJob(base).status, 'ok');
});

test('a thrown error is a failure, as it always was', () => {
  const v = classifyJob({ ...base, lastError: 'connection refused' });
  assert.equal(v.status, 'failed');
  assert.match(v.reasons.join(' '), /connection refused/);
});

// THE BUG: these were all reported as success.
test('a pass that returned failures is degraded, not healthy', () => {
  const v = classifyJob({ ...base, lastResult: { claimed: 5, failed: 3, abandoned: 0 } });
  assert.equal(v.status, 'degraded');
  assert.match(v.reasons.join(' '), /failed/);
});

test('abandoning rows is degraded even though the pass "succeeded"', () => {
  const v = classifyJob({ ...base, lastResult: { claimed: 5, failed: 0, abandoned: 2 } });
  assert.equal(v.status, 'degraded');
});

test('a backlog of objects nobody could delete is degraded', () => {
  const v = classifyJob({ ...base, lastResult: { objectsPending: 41 } });
  assert.equal(v.status, 'degraded');
  assert.match(v.reasons.join(' '), /41/);
});

test('a job that has not succeeded for several intervals is stale', () => {
  const v = classifyJob({ ...base, lastOkAt: base.now - 300_000 * 4 });
  assert.equal(v.status, 'stale');
  assert.match(v.reasons.join(' '), /succeeded/);
});

test('a job that has never run yet is not stale on the first tick', () => {
  const v = classifyJob({ ...base, lastRunAt: null, lastOkAt: null, startedAt: null, now: base.now });
  assert.equal(v.status, 'ok', 'a process that just booted has not failed at anything');
});

test('a job still running long past its interval is reported hung', () => {
  const v = classifyJob({ ...base, startedAt: base.now - 300_000 * 3 });
  assert.equal(v.status, 'stale');
  assert.match(v.reasons.join(' '), /still running/);
});

test('recovery clears the signal without a restart', () => {
  const broken = classifyJob({ ...base, lastError: 'boom' });
  assert.equal(broken.status, 'failed');
  const recovered = classifyJob({ ...base, lastError: null, lastOkAt: base.now - 1000 });
  assert.equal(recovered.status, 'ok');
});

test('the worst job decides the service, and every reason is named', () => {
  const { status, jobs } = classifyJob.service([
    { ...base, name: 'a' },
    { ...base, name: 'b', lastResult: { claimed: 1, failed: 1, abandoned: 0 } },
    { ...base, name: 'c', lastError: 'boom' },
  ]);
  assert.equal(status, 'failed', 'one failed job is not averaged away by two healthy ones');
  assert.equal(jobs.a.status, 'ok');
  assert.equal(jobs.b.status, 'degraded');
  assert.equal(jobs.c.status, 'failed');
});

// ── C04: the reaper keeps what it could not delete ─────────────────────────────

test('story reaping against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `reap_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema},public` });
  const originalQuery = pool.query;
  const originalConnect = pool.connect;
  (pool as any).query = db.query.bind(db);
  (pool as any).connect = db.connect.bind(db);

  const author = randomUUID();
  const pendingKeys = async () =>
    (await db.query('select r2_key from erasure_pending_objects order by r2_key')).rows.map((r: any) => r.r2_key);
  const storyCount = async () =>
    Number((await db.query('select count(*)::int as n from stories')).rows[0].n);

  async function expiredStory(key: string, attempts = 0) {
    const id = randomUUID();
    await db.query(
      `insert into stories (id, author_id, r2_key, expires_at, reap_attempts)
       values ($1,$2,$3, now() - interval '2 days', $4)`,
      [id, author, key, attempts]
    );
    return id;
  }

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    await db.query('insert into users(id, phone_number) values($1,$2)', [author, '+19990010001']);

    await t.test('with no storage configured, the key is kept rather than dropped', async () => {
      await db.query('delete from erasure_pending_objects');
      await db.query('delete from stories');
      await expiredStory('media/stories/unconfigured.jpg');
      const { reapStories } = await import('../src/reapStories');
      const result = await reapStories();

      assert.equal(await storyCount(), 0, 'the expired story is still removed');
      assert.deepEqual(
        await pendingKeys(), ['media/stories/unconfigured.jpg'],
        'the object key was lost — nothing left in the system can name the file in the bucket'
      );
      assert.ok((result as any).objectsQueued >= 1, 'and the pass reports it');
    });

    await t.test('a key abandoned after repeated failures is queued, not forgotten', async () => {
      await db.query('delete from erasure_pending_objects');
      await db.query('delete from stories');
      // Already at the attempt ceiling: this row takes the abandon path.
      await expiredStory('media/stories/abandoned.jpg', 99);
      const { reapStories } = await import('../src/reapStories');
      const result = await reapStories();

      assert.equal(await storyCount(), 0);
      assert.deepEqual(await pendingKeys(), ['media/stories/abandoned.jpg']);
      assert.ok((result as any).abandoned >= 1);
    });

    await t.test('queueing the same key twice does not raise', async () => {
      await db.query('delete from erasure_pending_objects');
      await db.query('delete from stories');
      await expiredStory('media/stories/same.jpg', 99);
      await expiredStory('media/stories/same.jpg', 99);
      const { reapStories } = await import('../src/reapStories');
      await reapStories();
      assert.deepEqual(await pendingKeys(), ['media/stories/same.jpg']);
    });

    await t.test('a story with no object key queues nothing', async () => {
      await db.query('delete from erasure_pending_objects');
      await db.query('delete from stories');
      const id = randomUUID();
      await db.query(
        `insert into stories (id, author_id, r2_key, expires_at) values ($1,$2,$3, now() - interval '2 days')`,
        [id, author, '']
      );
      const { reapStories } = await import('../src/reapStories');
      await reapStories();
      assert.deepEqual(await pendingKeys(), [], 'an empty key is not a file to chase');
    });
  } finally {
    (pool as any).query = originalQuery;
    (pool as any).connect = originalConnect;
    await db.end();
    await admin.query(`drop schema ${schema} cascade`);
    await admin.end();
    await pool.end().catch(() => {});
  }
});
