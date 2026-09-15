import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sweepMissedCallNotifications } from '../src/missedCallNotifications';
import type { query } from '../src/db';
import { buildFcmData, wakeTtlSeconds } from '../src/pushPayload';

test('missed calls have a day-long delivery window and call routing, not ring TTL', () => {
  assert.equal(wakeTtlSeconds({type:'missed_call'}), 86400);
  assert.deepEqual(buildFcmData({type:'missed_call',call_id:'call',conversation_id:'chat',caller_id:'caller',call_kind:'voice'}), {
    type:'missed_call',call_id:'call',conversation_id:'chat',caller_id:'caller',call_kind:'voice',
  });
});

test('a provider failure preserves the leased call for retry; success settles it', async () => {
  for (const fail of [true,false]) {
    let settled=false;
    let step=0;
    const execute = (async () => {
      if (step++ === 0) return [{id:'call',conversation_id:'chat',caller_user_id:'caller',call_kind:'voice'}];
      if (step===2) return [{push_token:'device'}];
      settled=true; return [];
    }) as typeof query;
    await sweepMissedCallNotifications({query:execute,send:async(tokens,meta,retryable)=>{
      assert.deepEqual(tokens,['device']); assert.equal(meta?.type,'missed_call'); assert.equal(retryable,true);
      if(fail) throw new Error('provider temporarily unavailable');
    }});
    assert.equal(settled,!fail);
  }
});

test('large device sets respect FCM multicast limits', async () => {
  let step=0; const batches:number[]=[];
  await sweepMissedCallNotifications({query:(async()=>{
    if(step++===0)return [{id:'call',conversation_id:'chat',caller_user_id:'caller',call_kind:'video'}];
    if(step===2)return Array.from({length:501},(_,i)=>({push_token:String(i)}));
    return [];
  }) as typeof query,send:async tokens=>{batches.push(tokens.length);}});
  assert.deepEqual(batches,[500,1]);
});
