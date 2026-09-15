import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import pg from 'pg';
const url=process.env.FINANCE_TEST_DATABASE_URL;
test('group migration preserves partially admitted bookings and defaults new bookings to group', {skip:!url},async()=>{
 assert.match(new URL(url!).pathname,/finance_test$/);
 const client=new pg.Client({connectionString:url});await client.connect();
 try {
  await client.query('begin');
  await client.query('create temporary table event_orders(id text primary key);create temporary table event_tickets(order_id text,checked_in_at timestamptz)');
  await client.query("insert into event_orders values('fresh'),('partial');insert into event_tickets values('fresh',null),('partial',now()),('partial',null)");
  await client.query(readFileSync(new URL('../../../database/migrations/070_group_event_admission.sql',import.meta.url),'utf8'));
  await client.query("insert into event_orders(id) values('new')");
  assert.deepEqual((await client.query('select id,admission_mode from event_orders order by id')).rows,[{id:'fresh',admission_mode:'group'},{id:'new',admission_mode:'group'},{id:'partial',admission_mode:'individual'}]);
 } finally {await client.query('rollback');await client.end();}
});
