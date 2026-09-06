// R05 — the participant cap holds when two people add someone at the same instant.
// CONF_TEST_DATABASE_URL=postgres://.../voiid_test_conf npx tsx --test test/conferenceCapPostgres.test.ts
//
// Its own database: every DB-backed suite replays the migration set and `create extension` is
// database-scoped, so two of them in one database race.
//
// WHY A FAKE COULD NEVER SETTLE THIS. Q01 rewrote the conference fake so it models the real
// INSERT's semantics, and its own record says so plainly: "a fake cannot prove Postgres
// evaluates the count and the write in one snapshot. The real concurrency guarantee remains
// UNVERIFIED and is R05's isolated-database race test." This is that test.
//
// The claim under examination: the cap lives inside the INSERT's own WHERE, so
// `(select count(*) ...) < $4` is evaluated by the same statement that writes. Under READ
// COMMITTED that subquery reads the snapshot taken when the STATEMENT began — so two
// transactions that both begin before either commits both see the same roster, both pass the
// count, and both insert different users. One statement is not a serialization boundary for an
// invariant that spans rows.
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Pool } from 'pg';

import { pool } from '../src/db';
import { redis, publisher } from '../src/redis';
import { admitParticipant } from '../src/routes/calls';

redis.disconnect();
publisher.disconnect();
const url = process.env.CONF_TEST_DATABASE_URL;

test('conference participant cap under real concurrency', { skip: !url }, async (t) => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_(?:test_[a-z_]+|migration_replay)$/);
  const schema = `conf_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new Pool({ connectionString: url, ssl: false });
  await admin.query(`create schema ${schema}`);
  const db = new Pool({ connectionString: url, ssl: false, options: `-c search_path=${schema},public` });
  const originalQuery = pool.query;
  const originalConnect = pool.connect;
  (pool as any).query = db.query.bind(db);
  (pool as any).connect = db.connect.bind(db);

  const CAP = 8;
  const caller = randomUUID();
  const conversation = randomUUID();
  let seeded = 0;

  /**
   * A call whose roster is exactly `filled`, INCLUDING the requester.
   *
   * The requester counts: `admitParticipant` records whoever is doing the adding as joined
   * before it counts seats, so a fixture that seeds `filled` strangers and then admits leaves
   * `filled + 1` on the roster. Seeding the caller here keeps the arithmetic honest.
   */
  async function callWith(filled: number): Promise<string> {
    const callId = randomUUID();
    await db.query(
      `insert into calls (id, conversation_id, caller_user_id, call_kind, status)
       values ($1, $2, $3, 'voice', 'connected')`,
      [callId, conversation, caller]
    );
    await db.query(
      `insert into call_participants (call_id, user_id, state, state_changed_at)
       values ($1, $2, 'joined', now())`,
      [callId, caller]
    );
    for (let i = 0; i < filled - 1; i++) {
      const uid = randomUUID();
      await db.query('insert into users(id, phone_number) values($1,$2)', [uid, `+19995${String(++seeded).padStart(6, '0')}`]);
      await db.query(
        `insert into call_participants (call_id, user_id, state, state_changed_at)
         values ($1, $2, 'joined', now())`,
        [callId, uid]
      );
    }
    return callId;
  }

  const rosterSize = async (callId: string) =>
    Number((await db.query(
      'select count(*)::int as n from call_participants where call_id=$1 and left_at is null', [callId]
    )).rows[0].n);

  /**
   * THE PRODUCTION PATH, not a copy of it.
   *
   * `admitParticipant` is exported from routes/calls.ts precisely so this test drives the real
   * transaction and the real lock. An earlier version of this file re-implemented the INSERT
   * and proved only that the copy behaved the way the copy behaved.
   */
  async function admit(callId: string, invitee: string) {
    const call = (await db.query('select * from calls where id=$1', [callId])).rows[0];
    const r = await admitParticipant({
      call, callId, requesterId: caller, requesterDeviceId: null, inviteeId: invitee,
    });
    if (r.status !== 200 && process.env.CONF_DEBUG) console.log('admit ->', r.status, JSON.stringify(r.body));
    return r.status === 200;
  }

  async function newUser(): Promise<string> {
    const uid = randomUUID();
    await db.query('insert into users(id, phone_number) values($1,$2)', [uid, `+19996${String(++seeded).padStart(6, '0')}`]);
    return uid;
  }

  try {
    const root = resolve(__dirname, '../../..');
    for (const file of (await readdir(resolve(root, 'database/migrations'))).filter((f) => f.endsWith('.sql')).sort()) {
      await db.query(await readFile(resolve(root, 'database/migrations', file), 'utf8'));
    }
    await db.query('insert into users(id, phone_number) values($1,$2)', [caller, '+19990020001']);
    await db.query('insert into conversations(id) values($1)', [conversation]);

    // THE SCENARIO R05 NAMES: seven seats taken, two people add the eighth and ninth at once.
    await t.test('two connections racing the last seat admit exactly one', async () => {
      const callId = await callWith(CAP - 1);
      const [eighth, ninth] = [await newUser(), await newUser()];

      // FORCED OVERLAP, not hoped-for overlap.
      //
      // Firing two admissions and trusting them to interleave is a coin toss: each awaits
      // several statements, so Node will often run them almost sequentially and the second
      // counts a roster the first has already committed. That version of this test passed
      // against a build with the lock removed — the same trap the linking race test fell into.
      //
      // A blocker transaction holds the call row, so both admissions are provably in flight at
      // once. With `for update` they queue behind it; without it, nothing blocks and the wait
      // below never appears, which fails this test by name rather than silently passing.
      const blocker = await db.connect();
      let admittedA: boolean, admittedB: boolean;
      try {
        await blocker.query('begin');
        await blocker.query('select 1 from calls where id = $1 for update', [callId]);

        const inFlight = Promise.all([admit(callId, eighth), admit(callId, ninth)]);

        const deadline = Date.now() + 5000;
        let waiting = false;
        while (Date.now() < deadline) {
          const { rows } = await db.query(`select 1 from pg_stat_activity
            where datname = current_database() and wait_event_type = 'Lock'
              and query ilike '%from calls where id%'`);
          if (rows.length) { waiting = true; break; }
          await new Promise((r) => setTimeout(r, 10));
        }
        assert.ok(waiting, 'neither admission took the call lock — the cap is not serialized');
        await blocker.query('commit');
        [admittedA, admittedB] = await inFlight;
      } finally {
        await blocker.query('rollback').catch(() => {});
        blocker.release();
      }

      const admitted = [admittedA, admittedB].filter(Boolean).length;
      assert.equal(
        admitted, 1,
        `both callers were told they had a seat — ${admitted} admitted into one free slot`
      );
      assert.equal(
        await rosterSize(callId), CAP,
        'the roster went past the cap: a single INSERT does not serialize a cross-row invariant'
      );
    });

    await t.test('a crowd racing the last seat still admits exactly one', async () => {
      const callId = await callWith(CAP - 1);
      const contenders = await Promise.all(Array.from({ length: 6 }, () => newUser()));

      const outcomes = await Promise.all(contenders.map((u) => admit(callId, u).catch(() => false)));
      assert.equal(outcomes.filter(Boolean).length, 1, 'more than one contender took the same seat');
      assert.equal(await rosterSize(callId), CAP);
    });

    await t.test('a re-invite of someone already in the room is never refused by the cap', async () => {
      const callId = await callWith(CAP);
      const existing = (await db.query(
        'select user_id from call_participants where call_id=$1 and user_id <> $2 limit 1',
        [callId, caller]
      )).rows[0].user_id;
      assert.equal(
        await admit(callId, existing), true,
        're-inviting the eighth person after a dropped connection must still work'
      );
      assert.equal(await rosterSize(callId), CAP, 'and adds nobody');
    });

    await t.test('a seat freed by leaving is reusable, and only once', async () => {
      const callId = await callWith(CAP);
      // NOT the caller: `admitParticipant` re-joins whoever is doing the adding, so a fixture
      // that retires the requester frees a seat and then immediately refills it.
      const leaver = (await db.query(
        'select user_id from call_participants where call_id=$1 and user_id <> $2 limit 1',
        [callId, caller]
      )).rows[0].user_id;
      await db.query(
        `update call_participants set left_at = now(), state = 'left' where call_id=$1 and user_id=$2`,
        [callId, leaver]
      );

      const [x, y] = [await newUser(), await newUser()];
      const [ra, rb] = await Promise.all([admit(callId, x), admit(callId, y)]);
      assert.equal([ra, rb].filter(Boolean).length, 1, 'one freed seat admitted two people');
      assert.equal(await rosterSize(callId), CAP);
    });

    await t.test('a call below the cap still admits normally', async () => {
      const callId = await callWith(2);
      assert.equal(await admit(callId, await newUser()), true);
      assert.equal(await rosterSize(callId), 3);
    });
  } finally {
    (pool as any).query = originalQuery;
    (pool as any).connect = originalConnect;
    await db.end();
    await admin.query(`drop schema ${schema} cascade`);
    await admin.end();
  }
});
