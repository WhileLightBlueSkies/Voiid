import { query, withTransaction } from './db';

export function validCommission(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 && value <= 10000;
}

export async function setCommunityCommission(id: string, bps: number, expected: number, adminId: string, reason: string) {
  return withTransaction(async execute => {
    const old = (await execute(`select event_commission_bps from communities where id=$1 for update`, [id]))[0];
    if (!old) return 'missing';
    if (old.event_commission_bps !== expected) return 'conflict';
    await execute(`update communities set event_commission_bps=$2 where id=$1`, [id, bps]);
    // Financial overrides must not commit without their audit record.
    await execute(`insert into admin_audit_log(admin_id,action,target_type,target_id,detail)
      values($1,'community.commission','community',$2,$3)`,
      [adminId, id, JSON.stringify({ previous_bps: old.event_commission_bps, commission_bps: bps, reason })]);
    return 'saved';
  });
}

export async function communityFinance(id: string, offset: number) {
  const community = (await query(`select id,name,event_commission_bps from communities where id=$1`, [id]))[0];
  if (!community) return null;
  const [totals, orders, events, history] = await Promise.all([
    query(`select o.currency, o.status, count(*)::int as orders, sum(o.quantity)::text as tickets,
      sum(o.amount_minor)::text as gross_minor,
      sum(o.commission_minor)::text as commission_minor, sum(o.organiser_minor)::text as organiser_minor,
      count(*) filter(where o.commission_bps is null)::int as unpriced_orders
      from event_orders o join community_events e on e.id=o.event_id
      where e.community_id=$1 group by o.currency,o.status order by o.currency,o.status`, [id]),
    query(`select o.id,o.event_id,e.title as event_title,o.status,o.quantity,o.currency,
      o.amount_minor::text,o.commission_bps,o.commission_minor::text,o.organiser_minor::text,
      o.provider,o.created_at,o.settled_at,
      (select count(*)::int from event_tickets t where t.order_id=o.id and t.checked_in_at is not null) as checked_in
      from event_orders o join community_events e on e.id=o.event_id where e.community_id=$1
      order by o.created_at desc,o.id desc limit 51 offset $2`, [id, offset]),
    query(`select e.id,e.title,e.status,e.starts_at,e.currency,e.price_minor::text,
      (select count(*)::int from event_orders o where o.event_id=e.id) as orders,
      (select count(*)::int from event_tickets t where t.event_id=e.id and t.checked_in_at is not null) as checked_in
      from community_events e where e.community_id=$1 order by e.created_at desc,e.id desc limit 101`, [id]),
    query(`select a.created_at,a.detail,u.email as admin_email from admin_audit_log a
      left join admin_users u on u.id=a.admin_id where a.target_id=$1 and a.action='community.commission'
      order by a.created_at desc limit 20`, [id]),
  ]);
  return { community, totals, orders: orders.slice(0,50), has_more: orders.length>50,
    events: events.slice(0,100), events_truncated: events.length>100, history,
    settlement_status: 'not_integrated', refunds_status: 'provider_reconciliation_required' };
}
