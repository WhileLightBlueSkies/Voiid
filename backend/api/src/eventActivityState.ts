export function eventActivityState(t: any, expiresAt: string | Date, now: number) {
  const startsAt=t ? Math.floor(new Date(t.starts_at).getTime()/1000) : now;
  const endsAt=t?.ends_at ? Math.floor(new Date(t.ends_at).getTime()/1000) : startsAt+3600;
  const ended=Boolean(!t || !t.owned || t.revoked_at || t.checked_in_at || t.state!=='valid' ||
    t.order_status!=='paid' || t.event_status!=='published' || t.suspended_at || t.community_suspended ||
    !Number.isFinite(startsAt) || !Number.isFinite(endsAt) || endsAt<=now ||
    new Date(expiresAt).getTime()<=now*1000 || startsAt>now+8*3600);
  return { startsAt: Number.isFinite(startsAt)?startsAt:now,
    status: ended ? 'ended' : startsAt>now ? 'upcoming' : 'started' };
}
