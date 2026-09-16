import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import vm from 'node:vm';
import ts from 'typescript';

// Execute the actual relay replay functions with Redis/socket seams replaced.
const source = readFileSync(resolve('src/index.ts'), 'utf8');
const fragment = source.slice(source.indexOf('const conferenceFramesKey ='), source.indexOf('// Trickle ICE needs'));
function harness() {
  const rows: string[] = [], sent: string[] = [], operations: unknown[][] = [];
  let authorized = true, direct = false;
  const transaction: any = {};
  for (const op of ['rpush','ltrim','expire']) transaction[op] = (...args: unknown[]) => { operations.push([op,...args]); return transaction; };
  transaction.exec = async () => [];
  const context = vm.createContext({
    pub: { lrange: async () => rows, get: async () => JSON.stringify({ direct }), multi: () => transaction },
    callPairAuthorized: async () => authorized,
    ringGrantKey: (id: string) => id,
    callGrantNeedsDeviceClaim: (grant: any) => grant.direct,
    WebSocket: { OPEN: 1 }, boundedSend: (_ws: any, frame: string) => sent.push(frame), console,
  });
  vm.runInContext(ts.transpileModule(fragment, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText, context);
  return { rows, sent, operations,
    authorize: (value: boolean) => { authorized = value; },
    direct: (value: boolean) => { direct = value; },
    park: (frame: string) => context.parkConferenceFrame('recipient', frame),
    flush: () => context.flushConferenceFrames('recipient','device',{readyState:1}),
    add: (frame: object, expires = Date.now()+60000) => rows.push(JSON.stringify({expires, frame:JSON.stringify(frame)})),
  };
}
test('conference replay keeps device isolation, expiry and current authorization',async()=>{
  const h=harness(), frame={type:'call_key',call_id:'call',from_user_id:'sender',device_id:'device',ciphertext:'opaque'};
  h.add(frame); h.add({...frame,device_id:'sibling'}); h.add(frame,Date.now()-1);
  await h.flush(); assert.equal(h.sent.length,1);
  assert.equal(JSON.parse(h.sent[0]).ciphertext,'opaque');
  h.authorize(false); await h.flush(); assert.equal(h.sent.length,1);
});
test('rolled-back conferences cannot replay migration into a direct call',async()=>{
  const h=harness(); h.add({type:'call_migrate',call_id:'call',from_user_id:'sender'});
  h.direct(true); await h.flush(); assert.equal(h.sent.length,0);
  h.direct(false); await h.flush(); assert.equal(h.sent.length,1);
});
test('conference buffering is bounded and stores opaque frames with a deadline',async()=>{
  const h=harness(); await h.park('opaque frame');
  assert.deepEqual(h.operations.map(o=>o[0]),['rpush','ltrim','expire']);
  const stored=JSON.parse(h.operations[0][2] as string);
  assert.equal(stored.frame,'opaque frame'); assert.ok(stored.expires>Date.now());
  assert.deepEqual(h.operations[1].slice(2),[-128,-1]);
  assert.equal(h.operations[2][2],60);
});
