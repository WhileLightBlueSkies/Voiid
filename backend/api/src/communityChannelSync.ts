import type { Request, Response } from 'express';
import { pool, query } from './db';
import { publisher } from './redis';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function ownDevice(req: Request): Promise<string | null> {
  const { user_id, device_id } = (req as any).auth;
  const claimed = req.body?.device_id;
  if (typeof claimed !== 'string' || !UUID.test(claimed) || (device_id && device_id !== claimed)) return null;
  return (await query(`select id from devices where id = $1 and user_id = $2 and revoked_at is null`, [claimed, user_id])).length ? claimed : null;
}

export async function communityChannelSync(req: Request, res: Response) {
  const device = await ownDevice(req);
  if (!device) return res.status(403).json({ error: 'active device required' });
  const { user_id } = (req as any).auth;
  // The first owner device takes responsibility. Only an uninitialised channel is claimable.
  await query(`update community_channels ch set mls_coordinator_device_id = $2
    from communities c where ch.community_id = c.id and c.owner_id = $1
      and c.suspended_at is null and ch.mls_coordinator_device_id is null and ch.mls_group_id is null`, [user_id, device]);
  const channels = await query(`select ch.conversation_id, ch.mls_group_id,
      coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'device_id', d.id,
          'key_packages_available', exists (select 1 from mls_key_packages kp where kp.device_id = d.id and kp.user_id = d.user_id and kp.consumed_at is null)) order by m.user_id, d.id)
        from community_members m join devices d on d.user_id = m.user_id and d.revoked_at is null
        where m.community_id = c.id and m.state = 'active'), '[]'::jsonb) as devices
    from community_channels ch join communities c on c.id = ch.community_id
    where c.owner_id = $1 and c.suspended_at is null and ch.mls_coordinator_device_id = $2
    order by ch.created_at limit 200`, [user_id, device]);
  res.json({ channels });
}

export async function communityChannelEvents(req: Request, res: Response) {
  const device = await ownDevice(req);
  if (!device) return res.status(403).json({ error: 'active device required' });
  const { conversation_id: cid, batch_id: bid, group_id: gid, events } = req.body ?? {};
  if (!UUID.test(cid ?? '') || !UUID.test(bid ?? '') || typeof gid !== 'string' || gid.length < 8 || gid.length > 256
      || !Array.isArray(events) || events.length > 1024
      || events.some(e => !UUID.test(e?.recipient_user_id ?? '') || !UUID.test(e?.recipient_device_id ?? '') || !['welcome', 'commit'].includes(e?.kind)
        || typeof e?.payload !== 'string' || e.payload.length < 1 || e.payload.length > 2000000
        || !/^[A-Za-z0-9+/]+={0,2}$/.test(e.payload)
        || (e.kind === 'welcome' && (typeof e.ratchet_tree !== 'string' || e.ratchet_tree.length > 2000000)))) {
    return res.status(400).json({ error: 'invalid channel update' });
  }
  const client = await pool.connect();
  const recipients = new Set<string>();
  try {
    await client.query('begin');
    const channel = (await client.query(`select ch.community_id, ch.mls_group_id from community_channels ch
      join communities c on c.id = ch.community_id where ch.conversation_id = $1
      and ch.mls_coordinator_device_id = $2 and c.owner_id = $3 and c.suspended_at is null for update of ch`,
      [cid, device, (req as any).auth.user_id])).rows[0];
    if (!channel) { await client.query('rollback'); return res.status(403).json({ error: 'only the Space coordinator can update encryption' }); }
    if (channel.mls_group_id && channel.mls_group_id !== gid) { await client.query('rollback'); return res.status(409).json({ error: 'Space already has different encryption state; recovery is required' }); }
    const inserted = await client.query(`insert into community_mls_batches (id, conversation_id, sender_device_id)
      values ($1,$2,$3) on conflict do nothing returning id`, [bid, cid, device]);
    if (!inserted.rowCount) {
      const same = (await client.query(`select id from community_mls_batches where id = $1 and conversation_id = $2 and sender_device_id = $3`, [bid,cid,device])).rowCount;
      await client.query('rollback'); return res.status(same ? 200 : 409).json(same ? { stored: 0, existed: true } : { error: 'batch id already used' });
    }
    await client.query(`update community_channels set mls_group_id = $2 where conversation_id = $1`, [cid, gid]);
    // A membership can change while a device is offline with a pending outbox. Do not deliver
    // a stale Welcome to someone who has since left/been banned. Remaining commits still land.
    const active = new Set((await client.query(`select user_id from community_members where community_id = $1 and state = 'active'`, [channel.community_id])).rows.map(r => r.user_id));
    for (const e of events) {
      if (!active.has(e.recipient_user_id)) continue;
      const row = (await client.query(`insert into mls_group_events (conversation_id, sender_user_id, recipient_user_id, kind, payload, ratchet_tree)
        values ($1,$2,$3,$4,$5,$6) returning id`, [cid, (req as any).auth.user_id, e.recipient_user_id, e.kind,
          Buffer.from(e.payload, 'base64'), e.ratchet_tree ? Buffer.from(e.ratchet_tree, 'base64') : null])).rows[0];
      await client.query(`insert into mls_event_deliveries (event_id, device_id, recipient_user_id)
        select $1, id, user_id from devices where user_id = $2 and revoked_at is null and id <> $3 and id = $4`, [row.id, e.recipient_user_id, device, e.recipient_device_id]);
      recipients.add(e.recipient_user_id);
    }
    await client.query('commit');
  } catch (error) { await client.query('rollback'); throw error; }
  finally { client.release(); }
  for (const user of recipients) {
    void publisher.publish(`channel:user:${user}`, JSON.stringify({ type: 'mls_event', conversation_id: cid })).catch(() => {});
  }
  res.json({ stored: events.length });
}
