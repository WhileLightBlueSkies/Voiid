import { query } from './db';
import { sendWakePush } from './push';
import { mentionedUsernames, shouldNotifyCommunity, type CommunityNotificationKind } from './notificationPolicy';

/** Routing metadata only; author names, post text and mentions stay out of push payloads. */
export async function notifyCommunity(args: {
  communityId: string; actorId: string; kind: CommunityNotificationKind;
  publicBody?: string; recipientIds?: string[];
}): Promise<void> {
  const handles = mentionedUsernames(args.publicBody ?? '');
  const targets = await query<{push_token:string;push_provider:string;handle:string}>(
    `select distinct d.push_token, d.push_provider, c.handle
       from community_members m join communities c on c.id=m.community_id
       join users u on u.id=m.user_id join devices d on d.user_id=m.user_id
      where m.community_id=$1 and m.state='active' and m.user_id<>$2
        and d.revoked_at is null and d.push_token is not null and d.push_provider is not null
        and (m.notification_mode='all' or (m.notification_mode='important'
             and ($3::boolean or lower(u.username)=any($4::text[]))))
        and ($5::uuid[] is null or m.user_id=any($5::uuid[]))
        and not exists(select 1 from user_blocks b where
          (b.blocker_user_id=m.user_id and b.blocked_user_id=$2) or
          (b.blocked_user_id=m.user_id and b.blocker_user_id=$2))`,
    [args.communityId,args.actorId,shouldNotifyCommunity('important',args.kind),handles,args.recipientIds ?? null]);
  for (let i=0;i<targets.length;i+=500) {
    await sendWakePush(targets.slice(i,i+500), {type:'community_update',community_id:args.communityId,
      community_handle:targets[i].handle});
  }
}

export function scheduleCommunityNotification(args: Parameters<typeof notifyCommunity>[0]): void {
  void notifyCommunity(args).catch(error => console.warn('[community-notifications] send failed:', error.message));
}
