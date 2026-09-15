import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { recordUsage } from '../src/usageAnalytics';
import type { query } from '../src/db';

test('activity deduplicates a device day and does not store device credentials', async () => {
 const user=randomUUID(),device=randomUUID();const inserts:unknown[][]=[];
 const execute=(async (sql:string,args:unknown[])=>{if(sql.startsWith('insert'))inserts.push(args);return [];}) as typeof query;
 await Promise.all([recordUsage(user,device,execute),recordUsage(user,device,execute)]);
 await recordUsage(user,device,execute);
 assert.equal(inserts.length,1);
 assert.deepEqual(inserts[0],[new Date().toISOString().slice(0,10),device,user]);
});
test('failed analytics writes do not reject user work and are retried',async()=>{
 const user=randomUUID(),device=randomUUID();let attempts=0;
 const execute=(async()=>{attempts++;throw Error('unavailable');}) as typeof query;
 await assert.doesNotReject(recordUsage(user,device,execute));
 await assert.doesNotReject(recordUsage(user,device,execute));
 assert.equal(attempts,2);
});
