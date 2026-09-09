import test from 'node:test';
import assert from 'node:assert/strict';
import { redeemWebTicket } from '../src/webTicket';
const ticket = 'a'.repeat(43), origin = 'https://messages.example.test';
test('only an exact configured origin may consume a ticket, once', async () => {
  const values = new Map([[`web:socket-ticket:${ticket}`, 'session-token']]);
  const store = { getdel: async (key: string) => { const value = values.get(key) || null; values.delete(key); return value; } };
  for (const candidate of [undefined, 'https://evil.example.test', origin + '.evil.test', 'null']) assert.equal(await redeemWebTicket(ticket, candidate, origin, store), null);
  assert.equal(await redeemWebTicket(ticket + '\n', origin, origin, store), null);
  assert.equal(await redeemWebTicket(ticket, origin, undefined, store), null);
  assert.deepEqual((await Promise.all([redeemWebTicket(ticket, origin, origin, store), redeemWebTicket(ticket, origin, origin, store)])).sort(), ['session-token', null].sort());
  assert.equal(await redeemWebTicket(ticket, origin, origin, store), null);
});
test('a cache outage cannot yield a credential', async () => {
  await assert.rejects(redeemWebTicket(ticket, origin, origin, { getdel: async () => { throw new Error('unavailable'); } }));
});
