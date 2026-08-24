// Per-viewer identity projection (LUDO_GAME_SPEC.md §6, §11.2).
//
// REAL USERNAME DISCLOSURE IS DECIDED ON THE SERVER. A viewer sees a real username only for
// themselves or when chat/contact policy allows it inside the source conversation; otherwise
// the frame says `Player 1`, `Player 2`, and so on — stable for the match. A client must never
// RECEIVE an unauthorized real username and then hide it locally, so this runs on every
// broadcast path before serialization, never in a renderer.
//
// CACHED WITH THE LIVE MATCH (§11.2): usernames and the entitlement matrix are read once per
// process lifetime of the record, so moves never query Postgres. Resolution to a specific
// viewer's name map is pure arithmetic on the cache.
import { query } from './db';

export interface ProjectionBase {
    /** userId -> social username (or full-name fallback), as Voiid would display it. */
    usernames: Map<string, string>;
    /** userId -> userId -> true when the row user MAY see the column user's real name. */
    reveal: Map<string, Map<string, boolean>>;
    players: (string | null)[];
}

const cache = new Map<string, ProjectionBase>();

export function invalidateProjection(matchId: string): void {
    cache.delete(matchId);
}

/** Load and cache usernames + entitlements for one match. */
export async function projectionFor(
    matchId: string,
    players: (string | null)[],
    sourceConversationId: string | null,
): Promise<ProjectionBase> {
    const hit = cache.get(matchId);
    if (hit && hit.players.length === players.length) return hit;

    const ids = players.filter((p): p is string => p !== null);
    const usernames = new Map<string, string>();
    const reveal = new Map<string, Map<string, boolean>>();
    ids.forEach((id) => reveal.set(id, new Map()));

    try {
        const rows = await query<{ id: string; username: string | null; full_name: string | null }>(
            `select id, username, full_name from users where id = any($1::uuid[])`,
            [ids],
        );
        for (const r of rows) {
            usernames.set(r.id, r.username ? `@${r.username}` : (r.full_name ?? ''));
        }

        // Entitlement: accepted co-membership within the SOURCE conversation only.
        let entitled = new Set<string>();
        if (sourceConversationId) {
            const members = await query<{ user_id: string }>(
                `select user_id from conversation_members
                  where conversation_id = $1::uuid
                    and left_at is null
                    and request_state = 'accepted'`,
                [sourceConversationId],
            );
            entitled = new Set(members.map((r) => r.user_id));
        }
        for (const a of ids) {
            for (const b of ids) {
                if (a !== b && entitled.has(a) && entitled.has(b)) reveal.get(a)!.set(b, true);
            }
        }

        // A block in either direction kills the reveal. Fail closed on any error.
        const blocks = await query<{ blocker: string; blocked: string }>(
            `select blocker_user_id as blocker, blocked_user_id as blocked from user_blocks
              where blocker_user_id = any($1::uuid[]) and blocked_user_id = any($1::uuid[])`,
            [ids],
        );
        for (const b of blocks) {
            reveal.get(b.blocker)?.set(b.blocked, false);
            reveal.get(b.blocked)?.set(b.blocker, false);
        }
    } catch {
        // A failed entitlement check degrades to NEUTRAL LABELS, never raw ids or guessed
        // usernames (§16). Self keeps its own name so the viewer still recognises their pod.
    }

    const base: ProjectionBase = { usernames, reveal, players: [...players] };
    cache.set(matchId, base);
    return base;
}

/**
 * Resolve the display-name map for ONE viewer's frame: target userId -> label.
 * Unauthorized targets collapse to `Player N` keyed by SEAT so labels are stable per match.
 */
export function namesForViewer(base: ProjectionBase, viewerId: string): Record<string, string> {
    const names: Record<string, string> = {};
    base.players.forEach((uid, seat) => {
        if (uid === null) return;
        if (uid === viewerId || base.reveal.get(viewerId)?.get(uid)) {
            names[uid] = base.usernames.get(uid) || `Player ${seat + 1}`;
        } else {
            names[uid] = `Player ${seat + 1}`;
        }
    });
    return names;
}
