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
  assert.match(v.reasons.join(' '), /last pass threw/);
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

test('successful queue production is healthy when the drain has no pending objects', () => {
  assert.equal(classifyJob({ ...base, lastResult: { objectsQueued: 5, objectsPending: 0 } }).status, 'ok');
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

test('retention failure lists and policy drift degrade health', () => {
  for (const lastResult of [{ failed: ['otp_sessions'] }, { drift: ['users'] }, { undeclared: ['users'] }]) {
    assert.equal(classifyJob({ ...base, lastResult }).status, 'degraded');
  }
});

test('never-started and never-successful jobs age from boot despite repeated ticks', () => {
  for (const lastRunAt of [null, base.now - 1]) {
    assert.equal(classifyJob({ ...base, lastRunAt, lastOkAt: null, bootAt: base.now - 900_000 }).status, 'stale');
  }
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

    for (const attempts of [0, 99]) {
      await t.test(`enqueue failure retains metadata (attempts=${attempts})`, async () => {
        await db.query('delete from stories');
        await expiredStory('media/stories/rollback.jpg', attempts);
        await db.query(`create function reject_queue() returns trigger language plpgsql as $$
          begin raise exception 'synthetic queue outage'; end $$`);
        await db.query(`create trigger reject_queue before insert on erasure_pending_objects
          for each row execute function reject_queue()`);
        try {
          const { reapStories } = await import('../src/reapStories');
          await reapStories().catch(() => {});
          assert.equal(await storyCount(), 1, 'metadata must survive enqueue failure');
        } finally {
          await db.query('drop trigger reject_queue on erasure_pending_objects');
          await db.query('drop function reject_queue()');
        }
      });
    }

    await t.test('queueing the same key twice does not raise', async () => {
      await db.query('delete from erasure_pending_objects');
      await db.query('delete from stories');
      await expiredStory('media/stories/same.jpg', 99);
      await expiredStory('media/stories/same.jpg', 99);
      const { reapStories } = await import('../src/reapStories');
      await reapStories();
      assert.deepEqual(await pendingKeys(), ['media/stories/same.jpg']);
    });

    await t.test('concurrent claims are disjoint and expired owners cannot finalize', async () => {
      const { claimObjects, completeObject } = await import('../src/cleanup');
      await db.query('delete from erasure_pending_objects');
      await db.query("insert into erasure_pending_objects(r2_key) values ('media/a'), ('media/b')");
      const [a, b] = await Promise.all([claimObjects(1), claimObjects(1)]);
      assert.equal(a.length, 1);
      assert.equal(b.length, 1);
      assert.notEqual(a[0].r2_key, b[0].r2_key);
      assert.equal((await claimObjects()).length, 0);
      await db.query("update erasure_pending_objects set lease_until = now() - interval '1 second' where r2_key = $1", [a[0].r2_key]);
      const recovered = await claimObjects();
      assert.equal(recovered.length, 1);
      assert.equal(await completeObject(a[0].r2_key, a[0].claim_token), 0);
      assert.equal(await completeObject(recovered[0].r2_key, recovered[0].claim_token), 1);
      assert.equal(await completeObject(b[0].r2_key, b[0].claim_token), 1);
    });

    await t.test('storage outage stays durable and restored storage drains the backlog', async () => {
      const { drainObjects } = await import('../src/cleanup');
      await db.query("insert into erasure_pending_objects(r2_key) values ('media/retry')");
      const failed = await drainObjects(async () => { throw new Error('synthetic R2 outage'); }, true);
      assert.equal(failed.failed, 1);
      assert.equal(failed.objectsPending, 1);
      assert.equal((await drainObjects(async () => {}, true)).objectsDeleted, 0, 'retry backoff is respected');
      await db.query('update erasure_pending_objects set next_attempt_at = now()');
      const restored = await drainObjects(async () => {}, true);
      assert.equal(restored.objectsDeleted, 1);
      assert.equal(restored.objectsPending, 0);
    });

    await t.test('erasure enqueue failure rolls back user and media, then retries successfully', async () => {
      const { runErasure } = await import('../src/erasure');
      await db.query('delete from stories');
      await db.query('delete from erasure_pending_objects');
      await expiredStory('media/stories/account.jpg');
      await db.query("update users set deleted_at = now() - interval '31 days' where id = $1", [author]);
      await db.query(`create function reject_queue() returns trigger language plpgsql as $$
        begin raise exception 'synthetic queue outage'; end $$`);
      await db.query(`create trigger reject_queue before insert on erasure_pending_objects
        for each row execute function reject_queue()`);
      try {
        const failed = await runErasure();
        assert.equal(failed.failed, 1);
        assert.equal(failed.usersErased, 0);
        assert.equal(failed.objectsQueued, 0);
        assert.equal(await storyCount(), 1);
        assert.equal((await db.query('select id from users where id = $1', [author])).rowCount, 1);
      } finally {
        await db.query('drop trigger reject_queue on erasure_pending_objects');
        await db.query('drop function reject_queue()');
      }
      const [first, second] = await Promise.all([runErasure(), runErasure()]);
      assert.equal(first.usersErased + second.usersErased, 1);
      assert.equal(first.claimed + second.claimed, 1);
      assert.deepEqual(await pendingKeys(), ['media/stories/account.jpg']);
      assert.equal(await storyCount(), 0);
      await db.query('insert into users(id, phone_number) values($1,$2)', [author, '+19990010001']);
    });

    await t.test('retention SQL failures and policy drift reach health, and recovery clears them', async () => {
      const { runRetentionSweep } = await import('../src/retention');
      await db.query("update data_retention_policy set declared_interval = interval '24 hours' where table_name = 'otp_sessions'");
      await db.query('alter table otp_sessions rename to otp_sessions_unavailable');
      try {
        const result = await runRetentionSweep();
        assert.ok(result.failed.includes('otp_sessions'));
        assert.equal(classifyJob({ ...base, lastResult: { ...result } }).status, 'degraded');
      } finally {
        await db.query('alter table otp_sessions_unavailable rename to otp_sessions');
      }
      await db.query("update data_retention_policy set declared_interval = interval '1 hour' where table_name = 'otp_sessions'");
      const drift = await runRetentionSweep();
      assert.ok(drift.drift.includes('otp_sessions'));
      assert.equal(classifyJob({ ...base, lastResult: { ...drift } }).status, 'degraded');
      await db.query('update data_retention_policy set declared_interval = enforced_interval where enforced_interval is not null and table_name != \'users\'');
      const recovered = await runRetentionSweep();
      assert.deepEqual(recovered.failed, []);
      assert.deepEqual(recovered.drift, []);
      assert.equal(classifyJob({ ...base, lastResult: { ...recovered } }).status, 'ok');
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
