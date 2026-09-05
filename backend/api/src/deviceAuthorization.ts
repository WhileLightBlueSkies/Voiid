import type { Request } from 'express';

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type AuthorizationQuery = (sql: string, params: any[]) => Promise<{ rows: any[] }>;

// Signed device claims take precedence, but still require a live database row.
// undefined means an invalid claim; null means a genuinely device-less legacy client.
export async function resolveActiveDevice(
  req: Request,
  userId: string,
  query: AuthorizationQuery,
  fallback: unknown,
  lock = false,
): Promise<string | null | undefined> {
  const claimed = (req as any).auth?.device_id ?? fallback;
  if (claimed == null) return null;
  if (typeof claimed !== 'string' || !UUID_RE.test(claimed)) return undefined;
  const id = claimed.toLowerCase();
  const { rows } = await query(
    `select 1 as one from devices
      where id = $1 and user_id = $2 and revoked_at is null
      limit 1 ${lock ? 'for share' : ''}`,
    [id, userId],
  );
  return rows.length ? id : undefined;
}
