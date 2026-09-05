// R02 — who the relay is actually allowed to send a frame to, against real PostgreSQL.
// RELAY_TEST_DATABASE_URL=postgres://.../voiid_test_relay npx tsx --test test/recipients.test.ts
//
// Its OWN database, not just its own schema: every DB-backed suite replays the full migration
// set, and `create extension` is database-scoped, so two suites doing that concurrently in one
// database race and one loses on pg_extension. Node runs test files in parallel.
//
// Before this, typing / session_reset / loc_* all took `recipient_ids` from the client and
// published to whatever it named. The relay had no database, so "the client knows its own
// conversation members" was the only option available. S03 gave it one, which is why R02
// depends on S03: the recipient list can now be DERIVED instead of trusted.
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Pool } from 'pg';

const url = process.env.RELAY_TEST_DATABASE_URL;
process.env.DATABASE_URL = url ?? '';

import { sessionPool } from '../src/session';
import { conversationRecipients, shareRecipients, useRecipientCache } from '../src/recipients';

test('authoritative recipient resolution against PostgreSQL', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `relay_recipients_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema},public` });
  const pool = sessionPool();
  (pool as any).query = db.query.bind(db);

  const cache = new Map<string, string>();
  useRecipientCache({
    get: async (key: string) => cache.get(key) ?? null,
    set: async (key: string, value: string) => { cache.set(key, value); return 'OK'; },
  });

  const ana = randomUUID(), ben = randomUUID(), cleo = randomUUID(), mal = randomUUID();
  const group = randomUUID(), share = randomUUID();
  const sorted = (ids: string[]) => [...ids].sort();

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    for (const [i, id] of [ana, ben, cleo, mal].entries()) {
      await db.query('insert into users(id, phone_number) values($1,$2)', [id, `+1999000400${i}`]);
    }
    await db.query("insert into conversations(id, type) values($1,'group')", [group]);
    for (const id of [ana, ben, cleo]) {
      await db.query('insert into conversation_members(conversation_id,user_id) values($1,$2)', [group, id]);
    }
    await db.query(
      `insert into location_shares(id, owner_user_id, kind, conversation_id, expires_at)
       values($1,$2,'conversation',$3, now() + interval '1 hour')`,
      [share, ana, group]
    );
    for (const id of [ben, cleo]) {
      await db.query('insert into location_share_targets(share_id,target_user_id) values($1,$2)', [share, id]);
    }

    await t.test('a member gets the other active members, never itself', async () => {
      cache.clear();
      const out = await conversationRecipients(ana, group);
      assert.deepEqual(sorted(out), sorted([ben, cleo]));
      assert.ok(!out.includes(ana), 'the sender is never a recipient');
    });

    await t.test('an outsider derives nobody, whatever it claims', async () => {
      cache.clear();
      assert.deepEqual(await conversationRecipients(mal, group), []);
      // The conversation need not even exist.
      assert.deepEqual(await conversationRecipients(mal, randomUUID()), []);
      // A non-uuid never reaches the database.
      assert.deepEqual(await conversationRecipients(mal, 'not-a-uuid'), []);
      assert.deepEqual(await conversationRecipients(mal, ''), []);
    });

    await t.test('a member who left is neither a sender nor a recipient', async () => {
      cache.clear();
      await db.query('update conversation_members set left_at=now() where conversation_id=$1 and user_id=$2', [group, cleo]);
      assert.deepEqual(await conversationRecipients(ana, group), [ben]);
      cache.clear();
      assert.deepEqual(await conversationRecipients(cleo, group), [], 'a former member cannot address the room');
      await db.query('update conversation_members set left_at=null where conversation_id=$1 and user_id=$2', [group, cleo]);
    });

    await t.test('a block removes that pair in both directions', async () => {
      cache.clear();
      await db.query('insert into user_blocks(blocker_user_id,blocked_user_id) values($1,$2)', [ben, ana]);
      assert.deepEqual(await conversationRecipients(ana, group), [cleo], 'blocked BY ben');
      cache.clear();
      assert.deepEqual(await conversationRecipients(ben, group), [cleo], 'and ben does not hear ana either');
      await db.query('delete from user_blocks');
    });

    await t.test('a share resolves to its own targets, for its owner only', async () => {
      cache.clear();
      assert.deepEqual(sorted(await shareRecipients(ana, share)), sorted([ben, cleo]));
      // Not the owner: a share id is not a capability.
      assert.deepEqual(await shareRecipients(mal, share), []);
      assert.deepEqual(await shareRecipients(ben, share), []);
      // An invented share id resolves to nobody, which is what makes the old
      // random-share-id buffer attack pointless rather than merely rate-limited.
      assert.deepEqual(await shareRecipients(ana, randomUUID()), []);
      assert.deepEqual(await shareRecipients(ana, 'not-a-uuid'), []);
    });

    await t.test('revocation, expiry and ending each stop the relay', async () => {
      cache.clear();
      await db.query('update location_share_targets set revoked_at=now() where share_id=$1 and target_user_id=$2', [share, ben]);
      assert.deepEqual(await shareRecipients(ana, share), [cleo], 'one revoked target, the other unaffected');

      cache.clear();
      await db.query('update location_shares set expires_at = now() - interval $$1 minute$$ where id=$1', [share]);
      assert.deepEqual(await shareRecipients(ana, share), [], 'an expired share relays to nobody');

      cache.clear();
      await db.query("update location_shares set expires_at = now() + interval '1 hour', ended_at = now() where id=$1", [share]);
      assert.deepEqual(await shareRecipients(ana, share), [], 'an ended share relays to nobody');

      await db.query('update location_shares set ended_at = null where id=$1', [share]);
      await db.query('update location_share_targets set revoked_at = null where share_id=$1', [share]);
    });

    await t.test('an unreachable database resolves to nobody rather than to everybody', async () => {
      cache.clear();
      (pool as any).query = async () => { throw new Error('connection refused'); };
      try {
        assert.deepEqual(await conversationRecipients(ana, group), []);
        assert.deepEqual(await shareRecipients(ana, share), []);
      } finally { (pool as any).query = db.query.bind(db); }
    });
  } finally {
    await db.end();
    await admin.query(`drop schema ${schema} cascade`);
    await admin.end();
    await pool.end().catch(() => {});
  }
});
