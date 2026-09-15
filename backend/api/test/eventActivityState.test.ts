import test from 'node:test';
import assert from 'node:assert/strict';
import {eventActivityState} from '../src/eventActivityState';
const now=1800000000;
const iso=(seconds:number)=>new Date(seconds*1000).toISOString();
const valid={starts_at:iso(now+3600),owned:true,state:'valid',order_status:'paid',event_status:'published'};
const state=(changes:any={},expiry=iso(now+8*3600))=>eventActivityState({...valid,...changes},expiry,now);
test('activity changes from countdown to started and expires',()=>{
 assert.equal(state().status,'upcoming');
 assert.equal(state({starts_at:iso(now)}).status,'started');
 assert.equal(state({starts_at:iso(now-3600)}).status,'ended');
 assert.equal(state({},iso(now)).status,'ended');
 assert.equal(state({starts_at:iso(now+8*3600+1)}).status,'ended');
});
test('revoked, checked-in, refunded, cancelled and suspended tickets end immediately',()=>{
 for(const patch of [{owned:false},{revoked_at:iso(now)},{checked_in_at:iso(now)},{state:'void'},
  {order_status:'refunded'},{event_status:'cancelled'},{suspended_at:iso(now)},{community_suspended:iso(now)}]) {
  assert.equal(state(patch).status,'ended',JSON.stringify(patch));
 }
 assert.equal(eventActivityState(null,iso(now+3600),now).status,'ended');
});
test('activity content excludes attendee, payment and admission data',()=>{
 assert.deepEqual(Object.keys(state({phone:'private',qr_nonce:'secret'})).sort(),['startsAt','status']);
 assert.equal(state({starts_at:'invalid'}).status,'ended');
});
