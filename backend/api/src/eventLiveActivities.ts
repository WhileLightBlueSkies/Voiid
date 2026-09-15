import { eventActivityState } from './eventActivityState';
import { query } from './db';
import { sendEventActivityPush } from './push';

// One bounded sweep per process. SQL leases also prevent concurrent API replicas
// from continuously updating the same activity. Failed deliveries retry next minute.
let running = false;
export async function sweepEventLiveActivities() {
  if (running) return;
  running = true;
  try {
    const rows = await query(`with due as (
      select device_id,ticket_id from event_live_activities where next_check_at <= now()
      order by next_check_at limit 40 for update skip locked
    ) update event_live_activities a set next_check_at=now()+interval '30 seconds'
      from due where a.device_id=due.device_id and a.ticket_id=due.ticket_id returning a.*`);
    for (let i=0;i<rows.length;i+=4) await Promise.all(rows.slice(i,i+4).map(async a => {
      try {
        const t = (await query(`select e.starts_at,e.ends_at,t.state,t.checked_in_at,o.status as order_status,
          e.status as event_status,e.suspended_at,c.suspended_at as community_suspended,d.revoked_at,
          t.holder_id=d.user_id as owned
          from event_tickets t join event_orders o on o.id=t.order_id
          join community_events e on e.id=t.event_id join communities c on c.id=e.community_id
          join devices d on d.id=$2 where t.id=$1`,[a.ticket_id,a.device_id]))[0];
        const now=Math.floor(Date.now()/1000);
        const state=eventActivityState(t,a.expires_at,now);
        const ended=state.status==='ended';
        const payload=JSON.stringify(state);
        if (!ended && a.last_payload===payload && a.last_sent_at && Date.now()-new Date(a.last_sent_at).getTime()<180_000) return;
        const result=await sendEventActivityPush(a.token,a.sandbox,{
          timestamp:now,event:ended?'end':'update','content-state':state,
          ...(ended?{'dismissal-date':now}:{'stale-date':now+300}),
        });
        if ((result>=200 && result<300 && ended) || result===410) {
          await query('delete from event_live_activities where device_id=$1 and ticket_id=$2 and token=$3',[a.device_id,a.ticket_id,a.token]);
        } else if(result>=200 && result<300) {
          await query('update event_live_activities set last_payload=$4,last_sent_at=now() where device_id=$1 and ticket_id=$2 and token=$3',[a.device_id,a.ticket_id,a.token,payload]);
        }
      } catch { console.warn('[event-activity] delivery retry scheduled'); }
    }));
    await query("delete from event_live_activities where expires_at < now()-interval '1 hour'");
  } finally { running=false; }
}
