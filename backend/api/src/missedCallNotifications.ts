import { query } from './db';
import { sendFcmWake } from './push';
import { redis } from './redis';

/** Server-owned backstop: it works even if Android never received the original ring. */
export async function sweepMissedCallNotifications(deps: {
  query: typeof query; send: typeof sendFcmWake; answered?: (id: string) => Promise<string | null>
} = { query, send: sendFcmWake, answered: id => redis.get(`call:answered:${id}`) }): Promise<void> {
  const calls = await deps.query<{id:string;conversation_id:string;caller_user_id:string;call_kind:string}>(
    `with due as (
      select c.id from calls c join conversations cv on cv.id=c.conversation_id
      where cv.type='direct' and c.answered_at is null and c.missed_push_sent_at is null
        and c.started_at > now()-interval '1 day'
        and (c.missed_push_lease_until is null or c.missed_push_lease_until < now())
        and (c.status='missed' or (c.status='ringing' and c.started_at < now()-interval '75 seconds')
          or (c.status='ended' and coalesce(c.end_reason,'') not in ('declined','busy','failed','cancelled','canceled')))
        and not exists(select 1 from call_participants p where p.call_id=c.id)
      order by c.started_at limit 50 for update of c skip locked
    ) update calls c set missed_push_lease_until=now()+interval '2 minutes'
      from due where c.id=due.id returning c.id,c.conversation_id,c.caller_user_id,c.call_kind`);
  for (const call of calls) {
    try {
      const answered = await deps.answered?.(call.id);
      if (answered) {
        await deps.query(`update calls set answered_at=coalesce(answered_at,$2::timestamptz),
          status=case when status='ringing' then 'connected' else status end,
          missed_push_lease_until=null where id=$1`, [call.id,answered]);
        continue;
      }
      await deps.query(`update calls set status=case when status='ringing' then 'missed' else status end,
        ended_at=coalesce(ended_at,now()) where id=$1 and answered_at is null`, [call.id]);
      const devices = await deps.query<{push_token:string}>(
        `select distinct d.push_token from devices d join conversation_members m on m.user_id=d.user_id
          where m.conversation_id=$1 and m.left_at is null and m.request_state='accepted' and m.user_id<>$2
            and d.revoked_at is null and d.push_provider='fcm' and d.push_token is not null
            and not exists(select 1 from user_blocks b where
              (b.blocker_user_id=m.user_id and b.blocked_user_id=$2) or
              (b.blocked_user_id=m.user_id and b.blocker_user_id=$2))`, [call.conversation_id,call.caller_user_id]);
      for (let i=0;i<devices.length;i+=500) await deps.send(devices.slice(i,i+500).map(d=>d.push_token), {
        type:'missed_call',call_id:call.id,conversation_id:call.conversation_id,
        caller_id:call.caller_user_id,call_kind:call.call_kind,
      }, true);
      await deps.query(`update calls set missed_push_sent_at=now(),missed_push_lease_until=null where id=$1`,[call.id]);
    } catch (error) {
      // Lease expiry retries provider/network failures after restarts or across API replicas.
      console.warn('[missed-call-push] retry scheduled:',(error as Error).message);
    }
  }
}

/** Classify unanswered rings even when push delivery is disabled on a deployment. */
export async function sweepUnansweredCalls(): Promise<void> {
  const due = await query<{ id: string }>(`select c.id from calls c
    join conversations cv on cv.id=c.conversation_id
    where cv.type='direct' and c.status='ringing' and c.answered_at is null
      and c.started_at<now()-interval '75 seconds'
      and not exists(select 1 from call_participants p where p.call_id=c.id)
    order by c.started_at limit 100`);
  for (const call of due) {
    const answered = await redis.get(`call:answered:${call.id}`);
    if (answered) {
      await query(`update calls set status='connected',answered_at=$2::timestamptz
        where id=$1 and status='ringing' and answered_at is null`, [call.id,answered]);
    } else {
      await query(`update calls set status='missed',ended_at=coalesce(ended_at,now())
        where id=$1 and status='ringing' and answered_at is null`, [call.id]);
    }
  }
}
