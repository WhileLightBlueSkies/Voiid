import { query } from './db';

// Bounded process-local deduplication. Cross-process duplicates are handled by the PK.
// No token, IP, content, route or device identifier is retained in the activity table.
const recorded = new Map<string, string>();
const pending = new Set<string>();
let cleanedDay = '';
export async function recordUsage(userId: string, deviceId: string, execute: typeof query = query): Promise<void> {
  const day = new Date().toISOString().slice(0, 10);
  const key = `${userId}:${deviceId}`;
  if (recorded.get(key) === day || pending.has(key) || pending.size >= 100) return;
  pending.add(key);
  try {
    await execute(`insert into user_daily_activity(day,user_id,platform)
      select $1::date,d.user_id,case when d.platform in ('ios','android','web') then d.platform else 'unknown' end
      from devices d join users u on u.id=d.user_id
      where d.id=$2 and d.user_id=$3 and d.revoked_at is null and u.deleted_at is null
      on conflict do nothing`, [day, deviceId, userId]);
    if (recorded.size >= 20000) recorded.clear();
    recorded.set(key, day);
    if (cleanedDay !== day) {
      cleanedDay = day;
      await execute(`delete from user_daily_activity where day < $1::date - 89`, [day]);
    }
  } catch {
    // Analytics must never prevent a user request from succeeding. Retry on later usage.
    recorded.delete(key);
  } finally { pending.delete(key); }
}

export async function usageAnalytics(days: number, execute: typeof query = query) {
  const [coverage, summary, platforms, series] = await Promise.all([
    execute(`select started_at from admin_usage_collection where id=true`),
    execute(`select
      count(distinct a.user_id) filter(where a.day=(now() at time zone 'UTC')::date)::int as dau,
      count(distinct a.user_id) filter(where a.day >= (now() at time zone 'UTC')::date-6)::int as wau,
      count(distinct a.user_id)::int as mau
      from user_daily_activity a join users u on u.id=a.user_id and u.deleted_at is null
      where a.day >= (now() at time zone 'UTC')::date-29`),
    execute(`with p(platform) as (values ('ios'),('android'),('web'),('unknown'))
      select p.platform,
      (select count(*)::int from devices d join users u on u.id=d.user_id where u.deleted_at is null and d.revoked_at is null and
        case when d.platform in ('ios','android','web') then d.platform else 'unknown' end=p.platform) as devices,
      (select count(distinct d.user_id)::int from devices d join users u on u.id=d.user_id where u.deleted_at is null and d.revoked_at is null and
        case when d.platform in ('ios','android','web') then d.platform else 'unknown' end=p.platform) as registered_users,
      (select count(distinct a.user_id)::int from user_daily_activity a join users u on u.id=a.user_id where u.deleted_at is null and a.platform=p.platform and a.day=(now() at time zone 'UTC')::date) as dau,
      (select count(distinct a.user_id)::int from user_daily_activity a join users u on u.id=a.user_id where u.deleted_at is null and a.platform=p.platform and a.day >= (now() at time zone 'UTC')::date-29) as mau
      from p`),
    execute(`with days as (select generate_series((now() at time zone 'UTC')::date-($1::int-1),(now() at time zone 'UTC')::date,'1 day')::date as day),
      activity as (select a.day,count(distinct a.user_id)::int dau,
        count(distinct a.user_id) filter(where platform='ios')::int ios,
        count(distinct a.user_id) filter(where platform='android')::int android,
        count(distinct a.user_id) filter(where platform='web')::int web
        from user_daily_activity a join users u on u.id=a.user_id where u.deleted_at is null
        and a.day >= (now() at time zone 'UTC')::date-($1::int-1) group by a.day),
      signups as (select (created_at at time zone 'UTC')::date as day,count(*)::int signups from users where deleted_at is null
        and created_at >= ((now() at time zone 'UTC')::date-($1::int-1)) at time zone 'UTC' group by 1)
      select to_char(d.day,'YYYY-MM-DD') as day,
        case when d.day >= (select (started_at at time zone 'UTC')::date from admin_usage_collection where id=true) then coalesce(a.dau,0) end dau,
        coalesce(a.ios,0) ios,coalesce(a.android,0) android,coalesce(a.web,0) web,coalesce(s.signups,0) signups
      from days d left join activity a on a.day=d.day left join signups s on s.day=d.day order by d.day`, [days]),
  ]);
  return { collected_since: coverage[0]?.started_at, timezone: 'UTC', days, summary: summary[0], platforms, series };
}
