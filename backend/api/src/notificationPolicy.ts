export const COMMUNITY_NOTIFICATION_MODES = ['all', 'important', 'none'] as const;
export type CommunityNotificationMode = typeof COMMUNITY_NOTIFICATION_MODES[number];
export type CommunityNotificationKind = 'post' | 'announcement' | 'event' | 'mention' | 'reply';

export function isCommunityNotificationMode(value: unknown): value is CommunityNotificationMode {
  return typeof value === 'string' && COMMUNITY_NOTIFICATION_MODES.includes(value as CommunityNotificationMode);
}

export function shouldNotifyCommunity(mode: CommunityNotificationMode, kind: CommunityNotificationKind): boolean {
  return mode === 'all' || (mode === 'important' && kind !== 'post');
}

/** Public community text only. Never pass decrypted channel content to the server. */
export function mentionedUsernames(body: string): string[] {
  return [...new Set(Array.from(body.matchAll(/(?:^|[^\w@])@([a-zA-Z0-9_]{3,32})\b/g), m => m[1].toLowerCase()))].slice(0, 50);
}
