import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';

test('group QR signs its version, carries no identity or editable party size, and expires', async () => {
  process.env.VOIID_TICKET_SIGNING_KEY = randomBytes(32).toString('base64');
  const {signTicketCode,verifyTicketCode}=await import('../src/payments/tickets');
  const code=signTicketCode('booking-ticket','event','nonce',true)!;
  assert.equal(verifyTicketCode(code.code).ok,true);
  assert.deepEqual(verifyTicketCode(code.code),{ok:true,ticketId:'booking-ticket',eventId:'event',nonce:'nonce',group:true});
  const parts=code.code.split('.');
  assert.deepEqual(Object.keys(JSON.parse(Buffer.from(parts[1],'base64url').toString())).sort(),['e','n','t','x']);
  assert.deepEqual(verifyTicketCode(code.code.replace(/^g1\./,'t1.')),{ok:false,reason:'bad_signature'});
  const original=Date.now;
  try { Date.now=()=>code.expiresAt+61_000; assert.deepEqual(verifyTicketCode(code.code),{ok:false,reason:'expired'}); }
  finally { Date.now=original; }
  const legacy=signTicketCode('ticket','event','nonce')!;
  assert.deepEqual(verifyTicketCode(legacy.code),{ok:true,ticketId:'ticket',eventId:'event',nonce:'nonce'});
});
