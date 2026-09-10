import type { PoolClient } from 'pg';

// Caller holds a transaction and locks the communities first. This deliberately includes the
// backing conversations: deleting only the container leaves functioning orphan groups/DMs.
export async function purgeCommunityData(client: PoolClient, ids: string[]) {
  const convs = (await client.query<{ conversation_id: string }>(`select conversation_id from community_channels where community_id = any($1::uuid[])
    union select conversation_id from community_host_threads where community_id = any($1::uuid[])`, [ids])).rows.map(r => r.conversation_id);
  const queued = await client.query(`insert into erasure_pending_objects(r2_key)
    select distinct key from (
      select avatar_r2_key as key from communities where id = any($1::uuid[])
      union all select media_url from community_posts where community_id = any($1::uuid[])
      union all select media_url from messages where conversation_id = any($2::uuid[])
      union all select photo_url from conversations where id = any($2::uuid[])
    ) k where key like 'media/%'
      and not exists (select 1 from communities c where c.avatar_r2_key = key and not(c.id = any($1::uuid[])))
      and not exists (select 1 from conversations c where c.photo_url = key and not(c.id = any($2::uuid[])))
      and not exists (select 1 from messages m where m.media_url = key and not(m.conversation_id = any($2::uuid[])))
      and not exists (select 1 from community_posts p where p.media_url = key and not(p.community_id = any($1::uuid[])))
      and not exists (select 1 from users u where u.photo_url = key or u.encrypted_photo_url = key)
      and not exists (select 1 from stories s where s.r2_key = key)
      and not exists (select 1 from clips c where key = any(array[c.r2_key,c.thumb_r2_key,c.r2_key_sd,c.r2_key_hd,c.r2_key_fhd]))
      and not exists (select 1 from creator_profiles p where p.avatar_r2_key = key)
    on conflict (r2_key) do nothing`, [ids, convs]);
  await client.query(`delete from content_reports where
    (target_type = 'community' and target_id = any($1::uuid[])) or
    (target_type = 'community_post' and target_id in (select id from community_posts where community_id = any($1::uuid[]))) or
    (target_type = 'event' and target_id in (select id from community_events where community_id = any($1::uuid[]))) or
    context_conversation_id = any($2::uuid[])`, [ids, convs]);
  await client.query(`delete from game_matches where source_conversation_id = any($2::uuid[])
    or tournament_id in (select id from tournaments where community_id = any($1::uuid[]))`, [ids, convs]);
  await client.query(`delete from payment_webhook_events where order_id in
    (select o.id from event_orders o join community_events e on e.id = o.event_id where e.community_id = any($1::uuid[]))`, [ids]);
  // Invites, roster, rules, posts, reactions, announcements, links, events, orders, tickets,
  // tournaments and entitlements cascade from their community/container parents.
  await client.query(`delete from communities where id = any($1::uuid[])`, [ids]);
  await client.query(`delete from conversations where id = any($1::uuid[])`, [convs]);
  return { communities: ids.length, conversations: convs.length, media_queued: queued.rowCount ?? 0 };
}
