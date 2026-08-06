// Announcement-channel posting rights — the SERVER-SIDE half of a restriction MLS cannot express.
//
// ── WHY THIS FILE EXISTS AT ALL ──────────────────────────────────────────────────
//
// An MLS group (RFC 9420) has exactly one capability model: every member holds the group
// secret, so every member can both decrypt AND encrypt. There is no "read-only member" in
// the protocol. A community announcement channel — where the host broadcasts and 5,000
// people listen — is therefore a policy the cryptography does not enforce and cannot be made
// to enforce without abandoning MLS.
//
// So it is enforced here, in the send path, before the ciphertext is accepted. A client that
// hides the composer is decoration: anyone can post to an announcement channel with curl and
// a valid token unless the server refuses the row. This is the refusal.
//
// ── WHY IT IS NOT IN routes/communities.ts ───────────────────────────────────────
//
// The check has to run where messages are accepted (routes/messages.ts), and that router must
// not have to import a whole Express router to ask one question. Keeping it in its own module
// means the send path takes a dependency on a function, not on the communities feature.
//
// ── COST ─────────────────────────────────────────────────────────────────────────
//
// ONE primary-key probe on community_channels for every send, ordinary 1:1 and group included.
// `community_channels.conversation_id` IS the primary key (030_communities.sql), so the probe
// returns zero or one row and an ordinary chat pays a single index lookup and nothing more.
// The second query — the role check — runs ONLY for the rare send into an announcement channel.
//
// ── FAILURE POSTURE: CLOSED ──────────────────────────────────────────────────────
//
// This function does not catch database errors. A thrown error propagates to the caller's
// asyncHandler and becomes a 500, which REJECTS the send. That is deliberate: a posting
// restriction that silently stops applying when the database hiccups is not a restriction.
// The one input it tolerates quietly is a non-uuid conversation_id — see below.
import { query } from './db';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Why this sender may NOT post into this conversation, or null if they may.
 *
 * Returns a human-readable reason string so the caller can put it straight in the 403 body;
 * null is the fast, overwhelmingly common answer ("not an announcement channel").
 *
 * A non-uuid `conversationId` returns null rather than throwing: binding it to Postgres would
 * raise a cast error that the global handler would report as an outage, and the send path's
 * own INSERT will reject the value a moment later with a proper 400. Refusing to answer a
 * question about a conversation that cannot exist is not a hole — no announcement channel has
 * a malformed id.
 */
export async function announcementPostDeniedReason(
  conversationId: unknown,
  senderUserId: string
): Promise<string | null> {
  if (typeof conversationId !== 'string' || !UUID_RE.test(conversationId)) return null;

  // Probe 1 (every send): is this conversation a community channel, and of what kind?
  const channel = (
    await query<{ community_id: string; kind: string }>(
      `select community_id, kind from community_channels where conversation_id = $1`,
      [conversationId]
    )
  )[0];
  if (!channel || channel.kind !== 'announcement') return null;

  // Probe 2 (announcement sends only): may this person broadcast?
  //
  // `communities.owner_id` is the AUTHORITY on who the host is — 030_communities.sql says so,
  // and the host-DM exception reads the same column. The roster role is checked as well so
  // appointed admins can post, but the owner is allowed even if their mirror row on
  // community_members were somehow missing or wrong. Two sources, and the container wins.
  //
  // `state = 'active'` matters: an admin who has been banned or has left keeps a roster row
  // (rows are retained so bans survive a leave) and must not keep broadcast rights with it.
  const verdict = (
    await query<{ allowed: boolean }>(
      `select (
                c.owner_id = $2
                or exists (
                     select 1 from community_members m
                      where m.community_id = c.id
                        and m.user_id = $2
                        and m.state = 'active'
                        and m.role in ('owner', 'admin')
                   )
              ) as allowed
         from communities c
        where c.id = $1`,
      [channel.community_id, senderUserId]
    )
  )[0];

  // No community row for a channel that references one means the FK was violated, which the
  // schema makes impossible — but "row missing" must deny, never allow.
  if (verdict?.allowed) return null;
  return 'only the community owner or an admin may post to an announcement channel';
}
