//
// Paid capabilities, granted per community by a Voiid admin (055_community_entitlements.sql).
//
// Creating and running a community is FREE. Home, Spaces, Events, Members and About are the
// product and nothing here gates them. This module answers one narrower question: may THIS
// community use a capability we sell separately, such as e-commerce.
//
// It is not a subscription system. There is no billing state, no renewal and no plan. A row
// is granted by a human from the admin panel and revoked by one.
//

import { query } from './db';

/**
 * Capabilities the server recognises.
 *
 * The column is free text so adding one needs no migration, but the CHECK here is exhaustive
 * on purpose: an unrecognised name must never grant anything. Fail closed, always.
 */
export const CAPABILITIES = ['ecommerce'] as const;
export type Capability = (typeof CAPABILITIES)[number];

export function isCapability(v: unknown): v is Capability {
  return typeof v === 'string' && (CAPABILITIES as readonly string[]).includes(v);
}

/**
 * Does this community currently hold this capability?
 *
 * Expiry is evaluated in SQL against now() rather than in JS against a parsed date: the
 * database is the only clock every caller shares, and a grant that expires differently
 * depending on which process asked is not an entitlement.
 */
export async function hasCapability(
  communityId: string,
  capability: Capability,
): Promise<boolean> {
  const rows = await query<{ ok: boolean }>(
    `select true as ok
       from community_entitlements
      where community_id = $1
        and capability = $2
        and revoked_at is null
        and (expires_at is null or expires_at > now())
      limit 1`,
    [communityId, capability],
  );
  return rows.length > 0;
}

/**
 * Express guard for a capability-gated route.
 *
 * Answers 402 Payment Required, not 403. The distinction is the whole point: 403 tells a host
 * they are not allowed, which is wrong and unactionable — they ARE allowed, once this is
 * switched on for them. 402 plus a capability name is something the client can turn into
 * "ask us to enable this".
 */
export function requireCapability(capability: Capability) {
  return async (req: any, res: any, next: any) => {
    const communityId = String(req.params.id ?? req.params.communityId ?? '');
    if (!communityId) {
      return res.status(400).json({ error: 'community id is required' });
    }
    if (await hasCapability(communityId, capability)) return next();
    return res.status(402).json({
      error: 'this community does not have that capability yet',
      capability,
    });
  };
}

/** Every live capability for a community, for the client to draw its UI from. */
export async function capabilitiesOf(communityId: string): Promise<Capability[]> {
  const rows = await query<{ capability: string }>(
    `select capability
       from community_entitlements
      where community_id = $1
        and revoked_at is null
        and (expires_at is null or expires_at > now())`,
    [communityId],
  );
  // Filtered through isCapability so a value the server no longer recognises cannot reach a
  // client as though it were live.
  return rows.map((r) => r.capability).filter(isCapability);
}
