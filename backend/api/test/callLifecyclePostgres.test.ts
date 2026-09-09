import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { Pool } from 'pg';

const url = process.env.CALL_TEST_DATABASE_URL;
test('real call status SQL never reopens terminal calls or overwrites their reason', { skip: !url }, async () => {
  const target = new URL(url!);
  assert.ok(['localhost', '127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_test_[a-z_]+$/);
  const pool = new Pool({ connectionString: url, ssl: false });
  const client = await pool.connect();
  try {
    await client.query(`create temporary table calls (
      id text primary key, status text, answered_at timestamptz, ended_at timestamptz, end_reason text)`);
    await client.query('create temporary table call_participants (call_id text)');
    const source = readFileSync(new URL('../src/routes/calls.ts', import.meta.url), 'utf8');
    const route = source.slice(source.indexOf("router.post('/:id/status'"));
    const sql = route.match(/`(update calls set[\s\S]*?)`/)?.[1];
    assert.ok(sql, 'execute the production status UPDATE unchanged');
    for (const terminal of ['ended', 'missed', 'declined']) {
      const id = randomUUID();
      await client.query("insert into calls(id,status) values($1,'ringing')", [id]);
      await client.query(sql, [id, terminal, 'original-reason']);
      await client.query(sql, [id, 'connected', null]);
      await client.query(sql, [id, 'ended', 'late-reason']);
      const { rows: [row] } = await client.query('select * from calls where id=$1', [id]);
      assert.equal(row.status, terminal);
      assert.equal(row.end_reason, 'original-reason');
      assert.equal(row.answered_at, null);
      assert.ok(row.ended_at);
    }
    const id = randomUUID();
    await client.query("insert into calls(id,status) values($1,'ringing')", [id]);
    await client.query(sql, [id, 'connected', null]);
    await client.query(sql, [id, 'ended', 'hangup']);
    await client.query(sql, [id, 'connected', null]);
    const { rows: [row] } = await client.query('select * from calls where id=$1', [id]);
    assert.equal(row.status, 'ended');
    assert.ok(row.answered_at && row.ended_at);
    const conferenceId = randomUUID();
    await client.query("insert into calls(id,status) values($1,'connected')", [conferenceId]);
    await client.query('insert into call_participants(call_id) values($1)', [conferenceId]);
    await client.query(sql, [conferenceId, 'ended', 'legacy-hangup']);
    const { rows: [conference] } = await client.query('select * from calls where id=$1', [conferenceId]);
    assert.equal(conference.status, 'connected', 'a legacy 1:1 status cannot end the shared conference');
    assert.equal(conference.ended_at, null);
  } finally { client.release(); await pool.end(); }
});
