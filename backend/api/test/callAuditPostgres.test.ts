import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Pool } from 'pg';
import express from 'express';
import { pool } from '../src/db';
import { redis, publisher } from '../src/redis';
import { issueToken } from '../src/auth';
import callsRouter, { sweepExpiredConferenceInvites } from '../src/routes/calls';
import { sweepUnansweredCalls } from '../src/missedCallNotifications';
redis.disconnect(); publisher.disconnect();
const url = process.env.CALL_TEST_DATABASE_URL;

test('conference arbitration, rollback, expiry and missed history against PostgreSQL', {skip:!url}, async t => {
  const target = new URL(url!);
  assert.ok(['localhost','127.0.0.1'].includes(target.hostname));
  assert.match(target.pathname, /^\/voiid_test_[a-z_]+$/);
  const schema = `call_audit_${randomUUID().replaceAll('-','')}`;
  const admin = new Pool({connectionString:url,ssl:false});
  await admin.query(`create schema ${schema}`);
  const db = new Pool({connectionString:url,ssl:false,options:`-c search_path=${schema},public`});
  const originalQuery = pool.query, originalConnect = pool.connect;
  (pool as any).query = db.query.bind(db); (pool as any).connect = db.connect.bind(db);
  const events: any[] = [], grants = new Map<string,string>();
  (redis as any).get = async (key:string) => key.startsWith('auth:active:') ? '1' : grants.get(key) ?? null;
  (redis as any).set = async (key:string,value:string) => { grants.set(key,value); return 'OK'; };
  (redis as any).del = async (key:string) => { grants.delete(key); return 1; };
  (redis as any).hset = async () => 1; (redis as any).expire = async () => 1;
  (redis as any).publish = async (_key:string,frame:string) => { events.push(JSON.parse(frame)); return 1; };
  const app = express(); app.use(express.json()); app.use('/calls',callsRouter);
  app.use((error:any,_req:any,res:any,_next:any)=>{ console.error(error);res.status(500).json({error:'test failure'}); });
  const server = app.listen(0,'127.0.0.1');
  await new Promise<void>(resolve=>server.once('listening',resolve));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;
  const a=randomUUID(),b=randomUUID(),c=randomUUID(),outsider=randomUUID();
  const ad=randomUUID(),bd=randomUUID(),cd=randomUUID(),sibling=randomUUID();
  const conv=randomUUID();
  async function request(path:string,user:string,device?:string,body?:any) {
    const response = await fetch(base+path,{method:body===undefined?'GET':'POST',
      headers:{'content-type':'application/json',authorization:`Bearer ${issueToken({user_id:user})}`},
      body:body===undefined?undefined:JSON.stringify({protocol_version:2,...body,device_id:device})});
    return {status:response.status,body:await response.json() as any};
  }
  async function seed() {
    const id=randomUUID();
    await db.query("insert into calls(id,conversation_id,caller_user_id,call_kind,status) values($1,$2,$3,'voice','connected')",[id,conv,a]);
    await db.query(`insert into call_participants(call_id,user_id,device_id,state,invited_by,state_changed_at)
      values($1,$2,$5,'joined',null,now()),($1,$3,$6,'joined',null,now()),($1,$4,null,'invited',$2,now())`,[id,a,b,c,ad,bd]);
    return id;
  }
  try {
    const dir=resolve(process.cwd().endsWith('backend/api')?'../../database/migrations':'database/migrations');
    for(const file of (await readdir(dir)).filter(f=>f.endsWith('.sql')).sort()) await db.query(await readFile(resolve(dir,file),'utf8'));
    for(const [i,user] of [a,b,c,outsider].entries()) await db.query("insert into users(id,phone_number,username) values($1,$2,$3)",[user,`+1999000000${i}`,`user${i}`]);
    for(const [i,[device,user]] of [[ad,a],[bd,b],[cd,c],[sibling,c]].entries()) await db.query(
      "insert into devices(id,user_id,platform,registration_id,identity_public_key) values($1,$2,'test',$3,$4)",[device,user,i,Buffer.from('fixture')]);
    await db.query("insert into conversations(id,type) values($1,'direct')",[conv]);
    for(const user of [a,b]) await db.query("insert into conversation_members(conversation_id,user_id,request_state) values($1,$2,'accepted')",[conv,user]);
    await t.test('legacy clients cannot start or join a room-key conference',async()=>{
      const id=await seed();
      for(const action of ['escalate','join']) {
        assert.equal((await request(`/calls/${id}/${action}`,a,ad,{protocol_version:1})).status,409);
      }
    });
    await t.test('unanswered classification works without pushes and respects relay answer evidence',async()=>{
      const missed=randomUUID(),answered=randomUUID();
      for(const id of [missed,answered]) await db.query(
        "insert into calls(id,conversation_id,caller_user_id,call_kind,status,started_at) values($1,$2,$3,'voice','ringing',now()-interval '80 seconds')",[id,conv,a]);
      grants.set(`call:answered:${answered}`,new Date().toISOString());
      await sweepUnansweredCalls();
      const rows=(await db.query('select id,status,answered_at from calls where id=any($1::uuid[])',[[missed,answered]])).rows;
      assert.equal(rows.find(r=>r.id===missed).status,'missed');
      assert.equal(rows.find(r=>r.id===answered).status,'connected');
      assert.ok(rows.find(r=>r.id===answered).answered_at);
      await db.query('delete from calls where id=any($1::uuid[])',[[missed,answered]]);
    });
    await t.test('sibling cannot steal a join or remove the answering device',async()=>{
      const id=await seed(); events.length=0;
      assert.equal((await request(`/calls/${id}/join`,c,cd,{})).status,200);
      assert.ok(events.some(e=>e.type==='call_taken'&&e.winner_device_id===cd));
      assert.equal((await request(`/calls/${id}/join`,c,sibling,{})).status,403);
      assert.equal((await request(`/calls/${id}/leave`,c,sibling,{})).status,200);
      assert.equal((await db.query('select state,device_id from call_participants where call_id=$1 and user_id=$2',[id,c])).rows[0].state,'joined');
      assert.equal((await request(`/calls/${id}/leave`,c,cd,{})).status,200);
      assert.equal((await db.query('select state from call_participants where call_id=$1 and user_id=$2',[id,c])).rows[0].state,'left');
    });
    await t.test('expired invites cannot join and the sweep removes them',async()=>{
      const id=await seed();
      await db.query("update call_participants set state_changed_at=now()-interval '61 seconds' where call_id=$1 and user_id=$2",[id,c]);
      assert.equal((await request(`/calls/${id}/join`,c,cd,{})).status,403);
      await sweepExpiredConferenceInvites();
      assert.equal((await db.query('select state from call_participants where call_id=$1 and user_id=$2',[id,c])).rows[0].state,'declined');
      assert.ok(!JSON.parse(grants.get(`callgrant:${id}`)!).p.includes(c));
    });
    await t.test('rollback cancels invitees and restores the original grant; committed handovers cannot abort',async()=>{
      const id=await seed(); events.length=0;
      assert.equal((await request(`/calls/${id}/abort-escalation`,c,cd,{})).status,403);
      assert.equal((await request(`/calls/${id}/abort-escalation`,a,ad,{})).status,200);
      assert.equal((await db.query('select 1 from call_participants where call_id=$1',[id])).rowCount,0);
      assert.equal(JSON.parse(grants.get(`callgrant:${id}`)!).mode,'one-to-one');
      assert.ok(events.some(e=>e.reason==='conference-aborted'));
      const active=await seed();
      assert.equal((await request(`/calls/${active}/complete-escalation`,a,ad,{})).status,200);
      assert.equal((await request(`/calls/${active}/abort-escalation`,b,bd,{})).status,409);
    });
    await t.test('missed history belongs only to the callee and excludes answered calls',async()=>{
      const missed=randomUUID(),answered=randomUUID();
      await db.query(`insert into calls(id,conversation_id,caller_user_id,call_kind,status,ended_at,answered_at)
        values($1,$3,$4,'voice','missed',now(),null),($2,$3,$4,'voice','ended',now(),now())`,[missed,answered,conv,a]);
      const page=await request('/calls/history/missed',b);
      assert.equal(page.status,200); assert.ok(page.body.calls.some((call:any)=>call.id===missed));
      assert.ok(!page.body.calls.some((call:any)=>call.id===answered));
      assert.deepEqual((await request('/calls/history/missed',outsider)).body.calls,[]);
      assert.deepEqual((await request('/calls/history/missed',a)).body.calls,[]);
      assert.equal((await request('/calls/history/missed?cursor=bad',b)).status,400);
    });
  } finally {
    await new Promise<void>(resolve=>server.close(()=>resolve()));
    (pool as any).query=originalQuery; (pool as any).connect=originalConnect;
    await db.end(); await admin.query(`drop schema ${schema} cascade`); await admin.end();
  }
});
