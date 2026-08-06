// "May this person do this inside this community?" — asked once, in one place.
//
// ── WHY THIS IS A MODULE AND NOT A FUNCTION IN EACH ROUTER ───────────────────────
//
// Three routers now need the same answer (tournaments, events, and whatever Phase 3 adds), and
// each of them writing its own version is how one of them ends up accepting a `pending`
// applicant, or forgetting that a suspended community is frozen. The roster is the single
// authority on roles — 030_communities.sql says so and gives this feature no role column of
// its own — and this is the single reader of it.
//
// ── THE RULES IT ENFORCES, AND WHY EACH ONE ──────────────────────────────────────
//
//   * SUSPENDED IS FROZEN. A suspended community accepts no new anything. It does not destroy
//     what already exists, the same posture the host-thread route takes.
//   * 'pending' IS NOT A MEMBER. An applicant to an approval-gated community has not been let
//     in. Treating them as one would make the approval queue a formality — the same rule
//     communityHostThreads.ts applies to the host-DM exception.
//   * ONE FAILURE MESSAGE for "never joined", "still pending", "left" and "banned". Telling
//     them apart would turn any endpoint using this into an oracle for moderation state the
//     caller is not entitled to read; in particular a banned account must not be able to
//     confirm its ban from an unrelated endpoint.
//   * THE OWNER COLUMN WINS. `communities.owner_id` is checked alongside the roster role, so
//     the host keeps their powers even if their mirror row on community_members is somehow
//     missing or wrong. Two sources, and the container is the tiebreak.
//
// ── WHAT THIS DOES NOT DO, AND MUST NEVER DO ─────────────────────────────────────
//
// It does not authorise a MESSAGE. Membership is a social graph; a social graph quietly
// becoming a messaging graph is the exact failure 020_reachability.sql and
// communityHostThreads.ts exist to prevent. If you find this function being consulted to
// decide whether A may message B, that is the bug 029_creator_profiles.sql forbids for follows,
// wearing a new hat.
import { query } from './db';

export type CommunityAccess =
  | { ok: true; isOrganiser: boolean }
  | { ok: false; status: number; error: string };

/**
 * @param needsAdmin require owner or admin, not merely membership.
 */
export async function communityAccess(
  communityId: string,
  userId: string,
  needsAdmin: boolean
): Promise<CommunityAccess> {
  const row = (
    await query<{ suspended: boolean; role: string | null; state: string | null; is_owner: boolean }>(
      `select c.suspended_at is not null as suspended,
              m.role,
              m.state,
              (c.owner_id = $2) as is_owner
         from communities c
         left join community_members m
                on m.community_id = c.id and m.user_id = $2
        where c.id = $1`,
      [communityId, userId]
    )
  )[0];

  if (!row) return { ok: false, status: 404, error: 'no such community' };
  if (row.suspended) return { ok: false, status: 403, error: 'this community is suspended' };
  if (row.state !== 'active') {
    return { ok: false, status: 403, error: 'only active members of this community can do that' };
  }

  const isOrganiser = row.is_owner || row.role === 'owner' || row.role === 'admin';
  if (needsAdmin && !isOrganiser) {
    return { ok: false, status: 403, error: 'only the community owner or an admin can do that' };
  }
  return { ok: true, isOrganiser };
}
