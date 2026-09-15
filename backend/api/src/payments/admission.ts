import { withTransaction } from '../db';

/** Serialise admission with moderation, role removal, refunds and ticket rotation. */
export async function admitTicket(eventId: string, ticketId: string, nonce: string, userId: string, group = false) {
  return withTransaction(async query => {
    const event = (await query(`select community_id from community_events where id=$1`, [eventId]))[0];
    if (!event) return { ok:false, reason:'not_found' };
    const community = (await query(`select owner_id,suspended_at from communities where id=$1 for share`, [event.community_id]))[0];
    if (!community || community.suspended_at) return { ok:false, reason:'event_unavailable' };
    const member = (await query(`select role,state from community_members where community_id=$1 and user_id=$2 for share`, [event.community_id,userId]))[0];
    if (!member || member.state !== 'active') return { ok:false, reason:'access_removed' };
    if (!(community.owner_id===userId || ['owner','admin'].includes(member.role))) {
      const staff=(await query(`select role from event_staff where event_id=$1 and user_id=$2 and state='active' and expires_at>now() for share`,[eventId,userId]))[0];
      if (!staff) return {ok:false,reason:'access_removed'};
    }
    const live = (await query(`select status,suspended_at from community_events where id=$1 for share`, [eventId]))[0];
    if (!live || live.status !== 'published' || live.suspended_at) return { ok:false, reason:'event_unavailable' };
    const ref = (await query(`select order_id from event_tickets where id=$1 and event_id=$2`, [ticketId,eventId]))[0];
    if (!ref) return { ok:false, reason:'not_found' };
    // Refund handling locks orders before tickets; use the same order here.
    const order = (await query(`select status,quantity,admission_mode from event_orders where id=$1 for update`, [ref.order_id]))[0];
    if (group) {
      if (order?.admission_mode !== 'group') return {ok:false,reason:'group_unavailable'};
      const all = await query(`select id,state,qr_nonce,checked_in_at from event_tickets where order_id=$1 order by id for update`, [ref.order_id]);
      if (all.length !== order.quantity || all[0]?.id !== ticketId) return {ok:false,reason:'group_unavailable'};
      if (all[0].qr_nonce !== nonce) return {ok:false,reason:'superseded'};
      if (all.some(t=>t.state!=='valid')) return {ok:false,reason:'void'};
      if (order.status !== 'paid') return {ok:false,reason:'unpaid'};
      const entered=all.find(t=>t.checked_in_at);
      if (entered) return {ok:false,reason:'already_checked_in',checked_in_at:entered.checked_in_at};
      const claimed=await query(`update event_tickets set checked_in_at=now(),checked_in_by=$2 where order_id=$1 returning checked_in_at`,[ref.order_id,userId]);
      return {ok:true,ticket_id:ticketId,people:order.quantity,checked_in_at:claimed[0].checked_in_at};
    }
    if (order?.admission_mode==='group' && order.quantity>1) return {ok:false,reason:'group_code_required'};
    const ticket = (await query(`select state,qr_nonce,checked_in_at,holder_id from event_tickets where id=$1 and event_id=$2 for update`, [ticketId,eventId]))[0];
    if (!ticket) return { ok:false, reason:'not_found' };
    if (ticket.qr_nonce !== nonce) return { ok:false, reason:'superseded' };
    if (ticket.state !== 'valid') return { ok:false, reason:'void' };
    if (order?.status !== 'paid') return { ok:false, reason:'unpaid' };
    if (ticket.checked_in_at) return { ok:false, reason:'already_checked_in',checked_in_at:ticket.checked_in_at };
    const claimed = (await query(`update event_tickets set checked_in_at=now(),checked_in_by=$2 where id=$1 returning checked_in_at`, [ticketId,userId]))[0];
    const holder = (await query(`select full_name,username from users where id=$1`,[ticket.holder_id]))[0];
    return {ok:true,ticket_id:ticketId,holder_id:ticket.holder_id,holder_name:holder?.full_name ?? holder?.username ?? null,checked_in_at:claimed.checked_in_at};
  });
}
