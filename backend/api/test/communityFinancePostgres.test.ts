import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import vm from 'node:vm';
import ts from 'typescript';
import pg from 'pg';
const url=process.env.FINANCE_TEST_DATABASE_URL;
test('commission defaults, immutable snapshots, overrides, audit rollback and historical orders', {skip:!url}, async()=>{
 assert.match(new URL(url!).pathname,/finance_test$/);
 const client=new pg.Client({connectionString:url});await client.connect();
 const schema=`finance_${Date.now()}`;
 const query=async(sql:string,p?:unknown[])=>(await client.query(sql,p)).rows;
 try{
 await query(`create schema ${schema};set search_path to ${schema}`);
 await query(`create table communities(id uuid primary key,name text);
 create table community_events(id uuid primary key,community_id uuid);
 create table event_orders(id uuid primary key,event_id uuid,amount_minor bigint,status text);
 create table admin_audit_log(admin_id uuid,action text,target_type text,target_id text,detail jsonb);`);
 const cid='00000000-0000-0000-0000-000000000001',eid='00000000-0000-0000-0000-000000000002';
 await query('insert into communities values($1,$2)',[cid,'Restaurant']);
 await query('insert into community_events values($1,$2)',[eid,cid]);
 await query("insert into event_orders values('00000000-0000-0000-0000-000000000003',$1,100000,'paid')",[eid]);
 await query(readFileSync(resolve('database/migrations/067_community_event_commission.sql'),'utf8'));
 assert.equal((await query('select event_commission_bps from communities'))[0].event_commission_bps,2500);
 assert.equal((await query('select commission_bps from event_orders'))[0].commission_bps,null);
 async function order(n:number,amount:number){return (await query(`insert into event_orders(id,event_id,amount_minor,status,commission_bps,commission_minor,organiser_minor)
 values($1,$2,$3,'pending',0,0,$3) returning *`,[`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`,eid,amount]))[0];}
 const first=await order(4,100001);assert.equal(first.commission_minor,'25000');assert.equal(first.organiser_minor,'75001');
 await assert.rejects(query('update event_orders set commission_bps=0 where id=$1',[first.id]),/immutable/);
 await query("update event_orders set status='paid' where id=$1",[first.id]);
 const exports:any={};
 vm.runInNewContext(ts.transpileModule(readFileSync(resolve('backend/api/src/communityFinance.ts'),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{exports,require:()=>({query,withTransaction:async(fn:Function)=>{await query('begin');try{const r=await fn(query);await query('commit');return r;}catch(e){await query('rollback');throw e;}}})});
 for(const bad of [-1,10001,1.5,'2500',null])assert.equal(exports.validCommission(bad),false);
 for(const good of [0,2500,10000])assert.equal(exports.validCommission(good),true);
 assert.equal(await exports.setCommunityCommission(cid,1000,2500,cid,'Negotiated rate'),'saved');
 assert.equal(await exports.setCommunityCommission(cid,500,2500,cid,'Stale change'),'conflict');
 assert.equal((await order(5,100000)).commission_minor,'10000');
 assert.equal((await query('select commission_bps from event_orders where id=$1',[first.id]))[0].commission_bps,2500);
 assert.equal((await query('select count(*)::int as n from admin_audit_log'))[0].n,1);
 await query("alter table admin_audit_log add constraint reject_audit check(action <> 'community.commission') not valid");
 await assert.rejects(exports.setCommunityCommission(cid,0,1000,cid,'Audit must succeed'));
 assert.equal((await query('select event_commission_bps from communities'))[0].event_commission_bps,1000);
 await query('update communities set event_commission_bps=0');assert.equal((await order(6,100)).organiser_minor,'100');
 await query('update communities set event_commission_bps=10000');assert.equal((await order(7,100)).organiser_minor,'0');
 assert.equal((await order(8,0)).commission_minor,'0');
 }finally{await query(`drop schema ${schema} cascade`);await client.end();}
});
