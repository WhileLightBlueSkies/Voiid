import test from 'node:test';
import assert from 'node:assert/strict';
import {ticketPass} from '../src/payments/appleWallet';
const ticket={id:'00000000-0000-0000-0000-000000000001',title:'Dinner',starts_at:'2026-10-01T12:00:00Z',location_text:'Restaurant'};
test('Wallet pass contains only an authenticated ticket link, not an admission credential',()=>{
 const pass=ticketPass(ticket);
 assert.equal(pass.passTypeIdentifier,'pass.in.voiid.events');
 assert.equal(pass.serialNumber,ticket.id);
 assert.equal(pass.eventTicket.backFields[0].value,`https://voiid.app/tickets/${ticket.id}`);
 assert.equal('barcodes' in pass,false);assert.equal('authenticationToken' in pass,false);
 assert.equal(pass.eventTicket.primaryFields[0].value,'Dinner');
 assert.throws(()=>ticketPass({...ticket,id:'../file'}));
});

test('group Wallet ticket displays the number of admissions without guest identities',()=>{
 const pass=ticketPass({...ticket,people:10});
 assert.equal(pass.eventTicket.auxiliaryFields.find(f=>f.key==='people')?.value,'10');
 assert.equal('barcodes' in pass,false);
});
