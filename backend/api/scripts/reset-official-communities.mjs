#!/usr/bin/env node
// Explicit production maintenance, never invoked automatically by migration/deploy.
// Dry run by default. Reset requires --reset --confirm-all-production-communities.
// Seed requires --owner=<username-or-uuid> --seed --confirm; owner is never guessed.
import pg from 'pg';
import { randomUUID } from 'node:crypto';
import { resolveDatabaseSsl } from '@voiid/common-utils';
import { purgeCommunityData } from '../dist/communityDeletion.js';
const args = process.argv.slice(2);
const owner = args.find(a => a.startsWith('--owner='))?.slice(8).replace(/^@/, '');
const reset = args.includes('--reset');
const seed = args.includes('--seed');
const confirm = reset ? args.includes('--confirm-all-production-communities') : args.includes('--confirm');
const expected = args.find(a => a.startsWith('--expected-count='))?.slice(17);
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, ssl: resolveDatabaseSsl(process.env.DATABASE_URL ?? '') });
const official = [
  { key: 'jobs', handle: 'voiid_jobs', name: 'Voiid Jobs', description: 'Opportunities, openings and career updates from Voiid.', posting: 'managers' },
  { key: 'feedback', handle: 'voiid_feedback', name: 'Voiid Feedback', description: 'Share ideas, report problems and help improve Voiid.', posting: 'members' },
  { key: 'updates', handle: 'voiid_updates', name: 'Voiid Updates', description: 'Official product news, releases and announcements from Voiid.', posting: 'managers' },
];
try {
  if (!process.env.DATABASE_URL || (!reset && !seed)) throw new Error('DATABASE_URL and --reset or --seed required');
  const client = await pool.connect();
  try {
    await client.query('begin');
    await client.query("set local lock_timeout = '10s'");
    await client.query('lock table communities in share row exclusive mode');
    const ids = (await client.query('select id from communities order by id for update')).rows.map(r => r.id);
    const counts = (await client.query(`select
      (select count(*) from communities)::int as communities,
      (select count(*) from community_channels)::int as channels,
      (select count(*) from community_host_threads)::int as host_threads,
      (select count(*) from community_posts)::int as posts,
      (select count(*) from community_members)::int as memberships,
      (select count(*) from event_orders)::int as event_orders`)).rows[0];
    console.log(JSON.stringify({ mode: confirm ? 'execute' : 'dry-run', reset, seed, counts }));
    if (expected !== undefined && ids.length !== Number(expected)) throw new Error('Community count changed; run a fresh dry-run before reset');
    let ownerId;
    if (seed) {
      if (!owner) throw new Error('Explicit --owner=username-or-uuid is required; no default account');
      const rows = (await client.query(`select id from users where deleted_at is null and (id::text = $1 or lower(username) = lower($1))`, [owner])).rows;
      if (rows.length !== 1) throw new Error('Owner must resolve to exactly one active account');
      ownerId = rows[0].id;
      console.log(JSON.stringify({ official_names: official.map(c => c.name), owner_resolved: true }));
    }
    if (!confirm) { await client.query('rollback'); continueExit(); }
    else {
      if (reset) console.log(JSON.stringify({ removed: await purgeCommunityData(client, ids) }));
      if (seed) for (const c of official) {
        if ((await client.query('select id from communities where official_key = $1', [c.key])).rowCount) continue;
        const id = randomUUID();
        await client.query(`insert into communities (id,owner_id,handle,name,description,discoverable,join_policy,members_can_invite,official_key,posting_policy)
          values ($1,$2,$3,$4,$5,true,'open',true,$6,$7)`, [id,ownerId,c.handle,c.name,c.description,c.key,c.posting]);
        await client.query(`insert into community_members (community_id,user_id,role,state) values ($1,$2,'owner','active')`, [id,ownerId]);
        for (const [position, name, kind] of [[0,'Announcements','announcement'], [1,'General','chat']]) {
          const conv = (await client.query(`insert into conversations(type,name,created_by) values ('group',$1,$2) returning id`,[name,ownerId])).rows[0].id;
          await client.query(`insert into community_channels(conversation_id,community_id,kind,position) values($1,$2,$3,$4)`,[conv,id,kind,position]);
          await client.query(`insert into conversation_members(conversation_id,user_id,role) values($1,$2,'admin')`,[conv,ownerId]);
        }
        await client.query(`insert into community_rules(community_id,title,detail,position) values ($1,'Be respectful','Keep conversations constructive. Do not share private information or spam.',0)`, [id]);
      }
      await client.query('commit');
      console.log(JSON.stringify({ completed: true, official_communities: seed ? official.length : undefined }));
    }
  } catch (error) { await client.query('rollback'); throw error; }
  finally { client.release(); }
} catch (error) { console.error(error.message); process.exitCode = 1; }
finally { await pool.end(); }
function continueExit() { console.log('Dry run complete; no data changed.'); }
