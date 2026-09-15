import {test} from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import type {AddressInfo} from 'node:net';

process.env.BASK_AGENT_TOKEN='test-only-agent-token-0123456789';
const {default:router,applyEnvChanges,renderValue}: typeof import('../src/routes/baskAgent')=require('../src/routes/baskAgent');

test('real agent router rejects unauthorized requests and invalid operations before executing anything',async()=>{
 const app=express();app.use(express.json());app.use('/agent',router);
 const server=app.listen(0,'127.0.0.1');
 await new Promise<void>(resolve=>server.once('listening',resolve));
 const base=`http://127.0.0.1:${(server.address() as AddressInfo).port}/agent`;
 const request=(path:string,body:unknown,authorized=true)=>fetch(base+path,{method:'POST',headers:{'Content-Type':'application/json',...(authorized?{Authorization:`Bearer ${process.env.BASK_AGENT_TOKEN}`}:{})},body:JSON.stringify(body)});
 try {
  assert.equal((await request('/command',{command:'status'},false)).status,401);
  for(const body of [{command:'exec',service:'voiid-api'},{command:'restart_service',service:'all'},{command:'stop_service',service:'voiid-api;touch /tmp/evil'},{command:'tail_logs',service:'voiid-api',lines:501}])assert.equal((await request('/command',body)).status,400);
  for(const changes of [[{key:'BASK_AGENT_TOKEN',value:null}],[{key:'X',value:'a'},{key:'X',value:'b'}],[{key:'INVALID-KEY',value:'a'}],[{key:'X',value:'a\nB=evil'}]])assert.equal((await request('/env',{changes})).status,400);
 } finally {server.closeAllConnections();await new Promise<void>(resolve=>server.close(()=>resolve()));}
});
test('actual env editor preserves comments and reports key names without values',()=>{
 const result=applyEnvChanges('# Keep this note\nPORT=4000\nOLD=old\n', [{key:'PORT',value:'5000'},{key:'OLD',value:null},{key:'NEW_SECRET',value:'private-value-123'}]);
 assert.ok(result.text.startsWith('# Keep this note\nPORT=5000\n'));
 assert.deepEqual(result.updated,['PORT']);assert.deepEqual(result.added,['NEW_SECRET']);assert.deepEqual(result.removed,['OLD']);
 const {text,...summary}=result;assert.ok(!JSON.stringify(summary).includes('private-value'));
 assert.throws(()=>renderValue('a\0b'));
});
