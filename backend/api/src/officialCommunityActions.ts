// Exact allowlist: no arbitrary URL forwarding, query strings, auth endpoints or MLS access.
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const actions: Record<string, RegExp[]> = {
  GET: [/^(channels|members|invites|posts|announcements|links|rules|stats|moderation-queue)$/],
  PATCH: [/^$/, new RegExp(`^(channels|rules|posts)/${UUID}$`, 'i')],
  POST: [/^(channels|invites|posts|announcements|links|rules)$/,
    new RegExp(`^members/${UUID}/(approve|remove|ban|unban|role)$`, 'i')],
  DELETE: [/^$/, new RegExp(`^(channels|posts|announcements|links|rules)/${UUID}$`, 'i'),
    /^invites\/[A-Za-z0-9_-]{22,64}$/],
};
export function officialCommunityActionAllowed(method: unknown, path: unknown): boolean {
  return typeof method === 'string' && typeof path === 'string'
    && (actions[method]?.some(pattern => pattern.test(path)) ?? false);
}
