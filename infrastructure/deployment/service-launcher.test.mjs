import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

test('service startup uses current env file, removes stale keys, and reloads rotated credentials',()=>{
 const root=mkdtempSync(join(tmpdir(),'bask-start-'));
 try {
  mkdirSync(join(root,'backend/api/dist'),{recursive:true});
  writeFileSync(join(root,'backend/api/dist/index.js'),`console.log(JSON.stringify({token:process.env.BASK_AGENT_TOKEN,removed:process.env.REMOVED_SETTING,nodeOptions:process.env.NODE_OPTIONS}));`);
  const run=()=>spawnSync(process.execPath,[fileURLToPath(new URL('./service-launcher.mjs',import.meta.url)),'api'],{
   env:{...process.env,VOIID_APP_DIR:root,BASK_AGENT_TOKEN:'stale-token',REMOVED_SETTING:'stale-value'},encoding:'utf8',timeout:10000,
  });
  writeFileSync(join(root,'.env'),'BASK_AGENT_TOKEN=fresh-token\n');
  let result=run();assert.equal(result.status,0,result.stderr);assert.deepEqual(JSON.parse(result.stdout),{token:'fresh-token'});
  writeFileSync(join(root,'.env'),'BASK_AGENT_TOKEN=rotated-token\n');
  result=run();assert.equal(result.status,0,result.stderr);assert.deepEqual(JSON.parse(result.stdout),{token:'rotated-token'});
 } finally {rmSync(root,{recursive:true,force:true});}
});
