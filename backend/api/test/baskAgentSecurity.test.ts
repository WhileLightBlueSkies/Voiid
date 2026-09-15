import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {parseEnv} from 'node:util';

const dir=mkdtempSync(join(tmpdir(),'bask-security-'));
const envFile=join(dir,'.env');
const pm2=join(dir,'pm2');
process.env.VOIID_ENV_FILE=envFile;
process.env.VOIID_PM2_BIN=pm2;
writeFileSync(envFile,'NEW_PRIVATE_KEY=new-private-value-123\n');
process.env.OLD_PRIVATE_KEY='old-private-value-456';
const agent: typeof import('../src/routes/baskAgent') = require('../src/routes/baskAgent');

test('actual PM2 status parses large JSON without exposing environment; malformed output is withheld',async()=>{
 const secret='pm2-only-secret-do-not-return';
 const processes=['voiid-api','voiid-ws','voiid-games','voiid-workers'].map(name=>({name,pm2_env:{status:'online',secret,padding:'x'.repeat(12000)},monit:{cpu:0,memory:1024}}));
 writeFileSync(pm2,`#!/usr/bin/env node\nprocess.stdout.write(${JSON.stringify(JSON.stringify(processes))});`,{mode:0o700});
 const good=await agent.serviceStatus();assert.equal(good.exitCode,0);assert.ok(good.output.includes('voiid-api'));assert.ok(!good.output.includes(secret));
 writeFileSync(pm2,`#!/usr/bin/env node\nprocess.stdout.write(${JSON.stringify(secret)});`);
 const bad=await agent.serviceStatus();assert.equal(bad.exitCode,1);assert.ok(!bad.output.includes(secret));
});
test('actual command output redacts old/new env credentials and withholds oversized captures',async()=>{
 const output=await agent.run([process.execPath,'-e','console.log("old-private-value-456 new-private-value-123 Bearer random-private-token")']);
 assert.ok(!output.output.includes('private'));assert.ok(output.output.includes('[REDACTED]'));
 const huge=await agent.run([process.execPath,'-e','process.stdout.write("s".repeat(1100000))']);
 assert.equal(huge.exitCode,1);assert.match(huge.output,/withheld/);
});
test('migration polling does not kill or duplicate an in-flight runner',async()=>{
 let finish!:(value:{exitCode:number,output:string})=>void;let starts=0;
 const poll=agent.createMigrationRunner(()=>{starts++;return new Promise(resolve=>{finish=resolve;});},5);
 const pending=await poll();assert.match(pending.output,/still running/);
 await poll();assert.equal(starts,1);
 finish({exitCode:0,output:'completed'});
 assert.deepEqual(await poll(),{exitCode:0,output:'completed'});
});
test('environment rendering round trips through the actual Node parser; unsupported newlines are refused',()=>{
 for(const value of ['plain','has#hash','two words','say "hi"',"both' and\"",'a\\nB=not-a-new-key','']) {
  assert.equal(parseEnv(`KEY=${agent.renderValue(value)}`).KEY,value);
 }
 assert.throws(()=>agent.renderValue('x\nINJECTED=y'));
 const result=agent.applyEnvChanges('A=old\nB=keep\n',[{key:'A',value:'new'},{key:'B',value:null}]);
 assert.deepEqual(parseEnv(result.text),{A:'new'});
});
test.after(()=>{rmSync(dir,{recursive:true,force:true});delete process.env.OLD_PRIVATE_KEY;});
