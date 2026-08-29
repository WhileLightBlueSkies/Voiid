# Spaces, membership, feed and identity — audit and plan

*Written 2026-08-29, against the code as it stands.*

## 1. What you asked for, and what is actually there

| Ask | Today |
|---|---|
| Members shows who joined **this Space** | Membership is per-COMMUNITY. Joining adds you to every channel at once. |
| Content visible only to joiners | True already — channels are E2EE group conversations, gated on membership. |
| Per-Space gating | **Absent.** `community_channels` has no visibility column. |
| Spaces as a feed with comments | **Absent.** The feed is per-community; there is no comments table at all. |
| Community photo + cover | **Neither is uploadable.** Details below. |
| Discover sheet with trending + search | Search works; **trending does not exist** and an empty query returns nothing. |
| Admin panel connection | Panel exists; none of the above is wired to it. |

### The three findings that shape everything

**1. A Space is a group conversation, not a feed.**
Joining a community runs one statement that inserts the member into *every* channel
(`communities.ts:827`). There is no per-channel join, no per-channel roster, and
`community_channels` carries only `conversation_id, community_id, kind, position` — no
visibility, no description, no member count. So "who joined this Space" currently has the same
answer as "who joined the community", by construction.

**2. The feed and the Spaces are two unrelated systems.**
`community_posts` has `community_id` and no `channel_id` — one feed per community, sitting on
the Home tab. Spaces are E2EE chat. They share nothing. Making a Space "like a feed with
comments" means deciding which of the two a Space *is*, because they cannot be both:

- A chat channel is **end-to-end encrypted**; the server cannot read it, cannot count
  reactions on it, and cannot render it anywhere else.
- A feed post is **server-readable** by design (047), which is what allows counts, moderation,
  and the admin panel to work at all.

**3. `comment_count` is a counter with nothing to increment it.**
Posts carry `comment_count` and the client renders it (`communities.ts:1734`), but there is no
comments table and no route that writes one. It is always zero, and always will be until
comments exist.

### Discover

`GET /communities/search` works and already orders by `member_count desc`, filtered to
`discoverable and suspended_at is null`. Two things stop it backing a discover sheet:

- **An empty query returns `[]`** (`communities.ts:552`: `if (q.length < 2) return ...`), so a
  sheet would open blank until the user types. A discover surface has to have something in it
  before anyone types.
- **`member_count desc` is "biggest", not "trending".** The largest communities are permanently
  the largest; a list ordered that way never changes and stops being worth opening. Trending
  needs recent movement — joins in the last N days over the existing base — which nothing
  currently computes.

`community_members.joined_at` exists, so recent-join velocity is computable today without new
columns.

### Community photo and cover

`communities.avatar_r2_key` exists, is presigned into every card (`communities.ts:171`), and
**can only be set at creation** — there is no presign route for communities and PATCH does not
accept the column. `CommunitySettingsView.swift:34` documents this deliberately: the picker was
left out rather than shipped pointing at a column nothing could fill.

**There is no cover column at all.** Every "cover" match in `communities.ts` is the word
*discover*.

`POST /media/presign-upload` already exists and is the thing to reuse — this is a small piece
of work, not a new subsystem.

---

## 2. The decision that has to come first

**What is a Space?** Everything else follows from this, and the two answers build different
products.

### Option A — Space stays a chat channel *(cheapest, matches what is built)*
Add per-Space visibility and a real roster. Spaces remain E2EE chat; the feed stays on Home.

- Membership: `community_channel_members`, and joining a community stops auto-joining
  restricted channels.
- Gating: `visibility` on `community_channels` — `open` (all members auto-join) /
  `request` / `invite`.
- **Cost:** moderate. No encryption change. The client already renders chat.
- **Loses:** no comments, no reactions, no admin visibility into Space content — that is the
  price of E2EE, and it is the right price.

### Option B — Space becomes a feed *(what "feed and comments" literally asks for)*
Give `community_posts` a nullable `channel_id`, add a comments table, and render a Space as a
post list.

- **Cost:** high. New comments table, moderation for comments, notification fan-out, a second
  content surface in the app, and admin tooling for both.
- **Gains:** comments, reactions, real counts, moderation, admin visibility.
- **Loses:** Space content stops being end-to-end encrypted. That is a product promise being
  changed, not a feature being added.

### Recommendation
**Option A, plus comments on the existing Home feed.**

The two asks are separable, and separating them is what makes both affordable: Spaces get real
per-Space membership and gating without touching encryption, and "feed with comments" gets
built once, on the feed that already exists and is already server-readable. A community then
has both — an encrypted place to talk, and a public place to post — instead of one confused
surface that is neither.

---

## 3. Build order

### Phase 1 — Community identity *(smallest, independent, ship first)*
1. `cover_r2_key` on `communities` (migration).
2. `POST /communities/:id/avatar-presign` and `/cover-presign`, manager-gated, mirroring
   `creators.ts:264`.
3. PATCH accepts both keys; `publicCard()` presigns cover alongside avatar.
4. iOS: picker in `CommunitySettingsView` — the header there already describes the shape.
5. Admin panel: show both on community detail; allow clearing one that breaches guidelines.

### Phase 1b — Discover sheet *(small, and it makes the browse surface real)*
1. Let `/communities/search` answer an empty `q` with a trending list rather than `[]`, or add
   `?sort=trending` — one route either way, since the filter and shape are identical.
2. Trending = joins in the last 7 days, weighted against size so a large community does not
   permanently own the list. Falls back to `member_count desc` when there is no recent
   activity, which is the honest answer for a young platform.
3. iOS: a discover sheet — trending on open, search as you type, the existing card row reused.
4. Admin panel: nothing new needed; suspended communities are already excluded by the same
   filter.

### Phase 2 — Per-Space membership and gating
1. `visibility` on `community_channels` (`open` | `request` | `invite`), default `open` so
   every existing Space behaves exactly as it does today.
2. `community_channel_members` — or reuse `conversation_members`, which already holds the
   roster; the honest answer is that a separate table is only needed for *pending* requests.
3. Community join auto-joins `open` channels only.
4. Routes: join / leave / request / approve per Space, manager-gated where it matters.
5. iOS: Members tab gains a per-Space roster; Spaces list shows locked Spaces with a Request
   button.
6. Admin panel: per-Space roster and visibility on community detail.

### Phase 3 — Comments on the community feed
1. `community_post_comments` (post_id, author_id, body, created_at, deleted_at).
2. `comment_count` maintained by trigger — the column already exists and is already rendered.
3. Routes: list / add / delete, with the author-or-manager delete gate the posts already use.
4. Reports extend to `community_comment` as a target type (053 already has the shape).
5. iOS: comment sheet on a post.
6. Admin panel: comments in the moderation queue.

---

## 4. What I would not do

- **Do not put posts inside E2EE Spaces.** It reads as one small feature and quietly removes
  encryption from community content, which is a promise rather than a default.
- **Do not build a second roster table** if `conversation_members` already answers "who is in
  this Space". Add the pending-request table only when requests actually ship.
- **Do not ship per-Space gating without a default.** Every existing Space must keep behaving
  exactly as it does today, or every community silently changes shape on deploy.
