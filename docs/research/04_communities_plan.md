# Communities — product + technical plan

**Status: design doc. Nothing of this feature exists in the codebase today.** Every citation below is to a building block that would be reused, or to a precedent that constrains the design — not to community code.

Founder requirements this plan covers:

1. A space someone creates; others join by search or by link.
2. E2EE where feasible.
3. Hosts games tournaments.
4. Community info (name, description, avatar, member list).
5. Owner can host events and sell tickets; future monetization: charge to create/join, event ticketing.
6. **Members can message THE HOST only, privately** — host sees and replies; no other member sees either side.

---

## 1. What exists today (the reusable building blocks)

### 1.1 Groups + MLS — the E2EE room primitive

- `conversations` supports `type = 'group'` with `name`, `photo_url`, `created_by` (`database/migrations/005_conversations.sql:4-13`), and `conversation_members` carries a `role` (`'admin' | 'member'`) per member (`005_conversations.sql:22-30`).
- Group creation makes the creator admin and everyone else member (`backend/api/src/routes/conversations.ts:101-126`). Admin-only member add with a reinstate-on-conflict upsert (`conversations.ts:203-233`, upsert at `conversations.ts:227-229`); admin-remove / self-leave sets `left_at` (`conversations.ts:239-259`).
- Group E2EE is **MLS (RFC 9420)**. The server stores only opaque KeyPackages and Welcome/Commit blobs (`database/migrations/011_mls.sql:1-33`); routes consume one KeyPackage per active device and fan Welcome/Commit out **one row per recipient user** with a Redis push per recipient (`backend/api/src/routes/mls.ts:33-52`, `mls.ts:56-82`). Group application ciphertext rides the ordinary messages relay (`mls.ts:1-3`), and the messages table is ciphertext-only by design (`database/migrations/006_messages.sql:5-23`).
- Both clients have a working MLS engine: iOS `apps/ios/Voiid/Voiid/Networking/GroupEngine.swift` (bridged from ChatEngine — "Groups use MLS, not the 1:1 ratchet — a completely separate engine", `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift:657-661`) and Android `apps/android/app/src/main/java/com/voiid/app/net/GroupEngine.kt`.

### 1.2 Reachability gates — who may open a conversation

- Exactly three paths open a 1:1: mutual contacts, one-way contact (as a request), or @username + 6-digit PIN (as a request) (`database/migrations/020_reachability.sql:9-15`; `backend/api/src/routes/reachability.ts:4-12`). Request state lives **on the membership row** (`request_state`, `opened_via`) precisely so it "generalises to group invites for free" (`020_reachability.sql:39-49`).
- The conversation list filters out `request_state <> 'accepted'` so a stranger's message lands in a Requests inbox, not the chat list (`conversations.ts:146-152`).
- The governing precedent for any new social surface: **"A FOLLOW IS NOT A MESSAGING RIGHT"** — the public graph and the reachability graph must not be joinable, and any code that reads the follow graph to authorize a message "is a bug, not a feature" (`database/migrations/029_creator_profiles.sql:13-23`). Community membership must obey the same rule (§2.3).

### 1.3 The reply/threading feature — the vehicle for host-DM context

Replies are **client-side E2EE envelopes**, invisible to the server:

- iOS: `MessageReplyEnvelope { t: "msg_reply", v, text, quotedId, quotedPreview, quotedSender }` — `quotedId` is the **server message id both sides share**, and the preview renders even if the recipient no longer has the original (`apps/ios/Voiid/Voiid/Networking/MessageActionWire.swift:47-56`). It travels under a `content_type` routing hint the server cannot read into (`MessageActionWire.swift:71-76`).
- Android: `ReplyWire(@EncodeDefault val t: String = "msg_reply", ...)` with `sendReply(...)` (`apps/android/app/src/main/java/com/voiid/app/net/ChatEngine.kt:885`, `913-925`); models carry `replyToSender/replyToText` (`apps/android/app/src/main/java/com/voiid/app/model/Models.kt:71-72`).
- Hazard already documented in-repo: kotlinx `encodeDefaults` is off on the shared `Json`, so the `t` discriminator **must** be `@EncodeDefault` or it silently vanishes from the wire (`ChatEngine.kt:877-878`, and the same class of bug called out at `net/ChatService.kt:60-62`, `net/MapPresenceService.kt:24`).

### 1.4 Games backend — the tournament substrate

- Catalog + matches + per-player results in Postgres (`database/migrations/024_games.sql:21-65`); `game_matches.player_ids` is a jsonb array supporting 2–4+ players (`024_games.sql:41`). Live match state is Redis-only, server-refereed (`024_games.sql:14-17`; rules engines in `backend/games/src/engine/`, lifecycle in `backend/games/src/index.ts`, `backend/games/src/matches.ts`).
- The E2EE stance is already settled: game **state** is server-readable ("the server is the referee"), scoped to game state and nothing else; the **invite** stays E2EE on the message pipe (`024_games.sql:3-12`; `backend/api/src/routes/games.ts:14-17`).
- Match creation validates seat count against the catalog and returns a match id the client invites people to over E2EE (`games.ts:55-107`); join authorizes once over HTTP then hands off to the WS relay (`games.ts:117-148`). The leaderboard is deliberately scoped to people you've played, never global (`games.ts:284-291`) — a community leaderboard is a *new, consented* scope (everyone in the community opted into the same space).
- **No tournament concept exists anywhere** (`grep -ri tournament backend/ docs/` returns nothing).

### 1.5 Public-identity plane — the pattern for community info

- `creator_profiles` is the template for a public, non-E2EE identity: handle grammar + `reserved_handles` + a cross-table uniqueness trigger so one name means one entity app-wide (`029_creator_profiles.sql:47-60`, `159-202`); denormalised counters maintained by triggers (`029_creator_profiles.sql:272-294`); suspension columns for reversible moderation (`029_creator_profiles.sql:110-111`); handle-rename history for rate limiting + 301s (`029_creator_profiles.sql:218-231`). Admin anchor exists (`database/migrations/028_admin_users.sql`).
- The clips header is the canonical statement of *why* broadcast/discovery surfaces cannot be E2EE (`database/migrations/022_clips.sql:3-17`), reiterated for creator identity (`029_creator_profiles.sql:3-11`).
- Discovery today is **exact-handle lookup only** — `GET /creators/:handle` (`backend/api/src/routes/creators.ts:254`); there is no text-search endpoint anywhere. "Join by search" needs one built (§4, Phase 1).

### 1.6 Payments — nothing exists

`grep -riE 'stripe|razorpay|payment|billing|checkout'` across `backend/api/src` and `database/migrations` finds nothing (the only hit is the word "checkout" in a comment about git in `backend/api/src/secretbox.ts:38`). Tickets and monetization require a payments module from zero (§4, Phase 2).

### 1.7 Stories fan-out — the per-device envelope pattern

One ciphertext blob + N ~400-byte per-recipient-device key envelopes; the key-envelope rows ARE the routing set (`database/migrations/017_stories.sql:2-19`). Relevant if community announcements ever need media fan-out outside MLS; MVP does not need it (announcements are just MLS group messages).

---

## 2. What is weak / what constrains the design (root causes)

1. **MLS event fan-out is O(members) rows per membership change.** Every Commit inserts one `mls_group_events` row per recipient in a per-event loop (`mls.ts:69-80`), and every join consumes a KeyPackage per device via a per-device query loop (`mls.ts:39-49`). A 5,000-member open community with link-joins would generate thousands of rows + Redis publishes *per join*. Root cause: the plumbing was built for chat-sized groups. **Consequence: cap E2EE community channels (512 members at MVP, WhatsApp-order 1024 later) and batch the inserts; do not promise "E2EE megagroups."**
2. **No conversation ↔ community linkage and no non-member-visible metadata.** `conversations` has only `name`/`photo_url` (`005_conversations.sql:8-9`) and `GET /conversations/:id` is member-only (`conversations.ts:174-180`). A community needs an *outsider-visible* info card (name, description, member count) before joining — that cannot hang off `conversations`. Root cause of the two-table design in §3.
3. **Reachability has no community path.** `opened_via` is constrained to `('contact','username')` (`020_reachability.sql:57-61`), so a member cannot open the host DM at all today without knowing the host's PIN. The gate needs a fourth, *narrowly scoped* path (member → owner of a community both belong to), designed against the 029 rule that social membership must not become general reachability (`029_creator_profiles.sql:13-23`).
4. **`game_matches` has no grouping key.** Tournament standings would require joining matches by nothing (`024_games.sql:35-50`). Needs a nullable `tournament_id`.
5. **Known bug classes to design around** (all previously shipped bugs in this repo):
   - kotlinx `encodeDefaults=false` dropping the `t` discriminator on any new Android wire envelope (`ChatEngine.kt:877-878`) — every new community envelope needs `@EncodeDefault`.
   - Swift `Codable` `keyNotFound` on absent keys — new response fields must be optionals on iOS (the pattern MessageActionWire's probe already follows, `MessageActionWire.swift:88`).
   - Postgres NULL in unique constraints breaking upserts (cf. `database/migrations/027_receipt_null_device.sql`) — the schema in §3 keeps every upsert-target unique key NULL-free (`primary key (community_id, user_id)`, `unique (event_id, provider, provider_ref)` with `provider_ref not null`).

---

## 3. How WhatsApp, Signal, and Discord do it

**WhatsApp Communities** = an umbrella object linking multiple E2EE groups. The community itself is a server-side container: a name, description, icon, an admin-only **Announcement Group** (auto-created, up to ~2k members) that every member is in, plus linked member groups people join selectively. Message content stays Signal-protocol E2EE per group; the community *structure* (which groups are linked, who is a member, the directory card) is server-visible metadata. Discovery is invite-link/QR only — no global search. This maps almost 1:1 onto Voiid's pieces: container row + N MLS conversations.

**Signal** has no communities, but its group **invite links** are the E2EE-preserving join mechanism worth copying in spirit: the URL is `https://signal.group/#<base64(GroupInviteLink{groupMasterKey, inviteLinkPassword})>` — the group key material and the join password ride the **URL fragment**, which never reaches the server; the server checks only a presented password credential ("/Users/devacc/Signal stack/Signal-Android/app/src/main/java/org/thoughtcrime/securesms/groups/v2/GroupInviteLinkUrl.java:20-27, 56-73"). Signal can do this because group *state* is also encrypted (zkgroup). Voiid's community roster is deliberately server-visible (joins are gated and fanned out server-side, like WhatsApp), so Voiid's link token can be a plain server-side capability — simpler, honestly non-E2EE, and revocable (§3 schema: `community_invites`). What we keep from Signal: unguessable token, revocation, expiry, and the *join-via-link → pending-approval* option.

**Discord** is the structural model for the non-E2EE surfaces: server → channels → roles; public server directory with text search; scheduled events; ticketed/paid access — all server-plaintext. Discord proves the product shape (spaces with channels, events, discovery) but is the anti-model for privacy: Voiid takes Discord's *container/discovery/events* shape and WhatsApp's *E2EE-groups-inside* shape.

**The member→host private line** exists in none of the three as designed (Discord DMs are unencrypted and unscoped; WhatsApp "message admin" is a plain 1:1). Voiid's version is genuinely better: an ordinary Double-Ratchet 1:1 (`006_messages.sql:5-23` — server never sees content), opened through a scoped gate, with the **existing reply envelope** carrying announcement context: the member long-presses an announcement in the (MLS) announcement channel and "asks the host about this" — the client opens/reuses the host DM and sends a `msg_reply` envelope whose `quotedId` is the announcement's **server message id**, which resolves for the host too because both are members of the announcement conversation (`MessageActionWire.swift:47-56`; `ChatEngine.kt:913-925`). Zero new cryptography; the quote renders from `quotedPreview` even if the host cleared the original — exactly the degraded-gracefully behavior the envelope was designed for.

---

## 4. What CANNOT be E2EE, stated up front (the 022 precedent applied)

Mirroring `022_clips.sql:3-17` ("you cannot encrypt to 'everyone, some of whom have not signed up yet', and a server that cannot read the row cannot count it"), the migration header for communities must declare, before any code exists:

| Surface | E2EE? | Why not |
|---|---|---|
| Channel messages (incl. announcements) | **Yes — MLS** | Known member set at send time; existing engines. |
| Member ↔ host DM | **Yes — Double Ratchet** | Ordinary 1:1. |
| Community name/description/avatar/handle | No | Shown to non-members and search; broadcast identity, same as `029_creator_profiles.sql:3-11`. |
| Search / discovery index | No | The server must match queries against names it can read. |
| Member roster + roles | No | The server gates joins, enforces admin-only endpoints, and fans out MLS events per member (`mls.ts:56-82`) — it necessarily knows who is in. (Audience-as-metadata, same stance as `017_stories.sql:5-8`.) |
| Invite-link tokens | No | Server-side capability, revocable; unlike Signal we have no encrypted group state to protect (§3). |
| Tournaments / matches | No | Server is the referee — the exception already made and scoped in `024_games.sql:3-12`. |
| Events, tickets, payments | No | Money: an external processor, webhooks, refunds, disputes, and tax records all require server-readable rows. A ticket the server cannot read cannot be validated at the door or refunded. |

---

## 5. Recommended plan (phased, with schema sketches)

### Phase 0 — decisions locked before code
Community = **container table + N MLS group conversations** (WhatsApp shape). Every community auto-creates one **announcement channel** (posting restricted to owner/admins — enforced server-side at send time via role, and stated in UI) and one general channel. Channel membership cap 512 at MVP (per §2.1). Community handles share the one namespace: extend the existing `assert_handle_available()` trigger (`029_creator_profiles.sql:159-202`) to a third table.

### Phase 1 — MVP (create / discover / join / channels / host DM / tournaments)

**Migration `030_communities.sql`** (header block per §4):

```sql
create table communities (
  id            uuid primary key,                    -- client-supplied, like clips (022:20-23)
  owner_id      uuid not null references users(id) on delete cascade,
  handle        text not null,                       -- 029 grammar; cross-table trigger extended
  name          text not null,
  description   text,
  avatar_r2_key text,                                -- plaintext R2, like creator avatars (029:90)
  discoverable  boolean not null default false,      -- opt-IN to search, like 029's not-at-signup stance
  join_policy   text not null default 'open'
                check (join_policy in ('open','approval','invite_only')),
  member_count  int not null default 0,              -- trigger-maintained (029:272-294 pattern)
  suspended_at  timestamptz, suspended_reason text,  -- reversible moderation (029:110-111)
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index on communities (lower(handle));

create table community_members (
  community_id uuid not null references communities(id) on delete cascade,
  user_id      uuid not null references users(id) on delete cascade,
  role         text not null default 'member' check (role in ('owner','admin','member')),
  state        text not null default 'active' check (state in ('active','pending','banned')),
  joined_at    timestamptz not null default now(),
  left_at      timestamptz,
  primary key (community_id, user_id)                -- NULL-free upsert target (§2.5)
);

create table community_channels (
  conversation_id uuid primary key references conversations(id) on delete cascade,
  community_id    uuid not null references communities(id) on delete cascade,
  kind            text not null default 'chat' check (kind in ('announcement','chat')),
  position        int not null default 0
);

create table community_invites (
  token        text primary key,                     -- 32 bytes crypto-random, base64url
  community_id uuid not null references communities(id) on delete cascade,
  created_by   uuid not null references users(id) on delete cascade,
  expires_at   timestamptz, max_uses int, use_count int not null default 0,
  revoked_at   timestamptz
);

-- The member->host private line: one 1:1 per (community, member).
create table community_host_threads (
  community_id    uuid not null references communities(id) on delete cascade,
  member_user_id  uuid not null references users(id) on delete cascade,
  conversation_id uuid not null references conversations(id) on delete cascade,
  primary key (community_id, member_user_id)
);

alter table conversation_members
  drop constraint conversation_members_opened_via_check,
  add constraint conversation_members_opened_via_check
  check (opened_via is null or opened_via in ('contact','username','community'));
```

**Backend `backend/api/src/routes/communities.ts`** (mount in `backend/api/src/index.ts`):
- `POST /communities` — create; auto-create the two group conversations (reuse the transaction shape of `conversations.ts:104-125`) + `community_channels` rows; owner row in `community_members`.
- `GET /communities/search?q=` — `discoverable = true and suspended_at is null`, ILIKE (pg_trgm later) on handle+name; returns the public card only.
- `GET /communities/:handle` — public info card (works for non-members; this is why the container is not a conversation, §2.2).
- `POST /communities/:id/join` (+ body `invite_token?`) — open → active; approval → `state='pending'`; invite_only → valid token required (check expiry/uses/revoked, bump `use_count`). On active: insert `conversation_members` rows for the community's channels; the **client** then completes MLS adds via the existing `/mls` routes (`mls.ts:33-82`) — same division of labor as `conversations.ts:199-202` documents.
- `POST /communities/:id/leave`, admin approve/ban/remove, `POST /communities/:id/invites` (owner/admin), `DELETE /communities/:id/invites/:token`.
- `POST /communities/:id/host-thread` — **the scoped reachability exception**: caller must be an `active` member and target is the owner; idempotently create/reuse a `type='direct'` conversation (shape of `conversations.ts:62-98`) with `opened_via='community'`, `request_state='accepted'` on both rows (joining a community IS consent to being asked questions by members — but rate-limit thread creation, and give the host a per-community "close inbox" toggle later). Record it in `community_host_threads`. **This grants member→owner only; nothing member→member. Any code path reading `community_members` to authorize a member→member conversation repeats the bug 029:13-23 forbids.**
- Announcement-channel enforcement: `messages/send` (or a guard in the send route) rejects sends to a `kind='announcement'` conversation from non-admin members — server-enforced because MLS cannot enforce posting rights, only membership.

**Invite links**: `https://voiid.app/c/<handle>?i=<token>` — plain capability URL (per §3, deliberately not Signal's fragment scheme). Android: extend `apps/android/app/src/main/java/com/voiid/app/net/DeepLinkRouter.kt` + manifest intent filter; iOS: universal-link handling in the App delegate/scene.

**Tournaments** (server-side, in `backend/api/src/routes/games.ts` or new `tournaments.ts`):

```sql
create table tournaments (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id) on delete cascade,
  game_id      uuid not null references games(id) on delete restrict,
  name         text not null,
  format       text not null default 'single_elim' check (format in ('single_elim','round_robin')),
  status       text not null default 'open' check (status in ('open','active','finished','cancelled')),
  created_by   uuid not null references users(id) on delete cascade,
  starts_at    timestamptz, created_at timestamptz not null default now()
);
create table tournament_players (
  tournament_id uuid not null references tournaments(id) on delete cascade,
  user_id       uuid not null references users(id) on delete cascade,
  seed          int, eliminated_in_round int,
  primary key (tournament_id, user_id)
);
alter table game_matches add column tournament_id uuid references tournaments(id) on delete set null,
                         add column tournament_round int;
```

Bracket advance runs off the existing finish path: when `backend/games/src/matches.ts` finalizes a match that has `tournament_id`, the API (or a small worker) pairs winners into the next round's `game_matches` rows (created exactly as `games.ts:98-106` does) and E2EE match invites flow client-side as they already do (`games.ts:50-53`). Standings = SQL over `game_match_results` (`024_games.sql:57-65`) scoped by `tournament_id` — a community-wide leaderboard is acceptable here because the audience consented by joining (contrast `games.ts:284-291`).

**Clients (both platforms)**: Communities tab — create flow, search, info card, join, channel list (channels are ordinary MLS group chats the existing `GroupEngine` already renders), "Message host" button on the info card + long-press "Ask host about this" on announcement messages (send via the existing reply path: `ChatEngine.kt:913-925` / iOS `MessageReplyEnvelope`, into the host-thread conversation). Host side: a "Community inbox" section grouping conversations whose membership row has `opened_via='community'`. Android wire structs: every new envelope/discriminator field marked `@EncodeDefault` (§2.5). iOS: all new response fields optional.

### Phase 2 — Events + tickets (free RSVP first, then paid)

```sql
create table community_events (
  id uuid primary key, community_id uuid not null references communities(id) on delete cascade,
  title text not null, description text, starts_at timestamptz not null, ends_at timestamptz,
  location_text text,                       -- free text; NOT an E2EE location share
  capacity int, price_minor bigint not null default 0, currency text not null default 'INR',
  status text not null default 'published' check (status in ('draft','published','cancelled')),
  created_by uuid not null references users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table event_orders (
  id uuid primary key, event_id uuid not null references community_events(id) on delete cascade,
  buyer_id uuid not null references users(id) on delete cascade,
  amount_minor bigint not null, currency text not null,
  provider text not null, provider_ref text not null,        -- NOT NULL: §2.5 upsert hazard
  status text not null default 'pending'
         check (status in ('pending','paid','failed','refunded')),
  created_at timestamptz not null default now(),
  unique (provider, provider_ref)                            -- webhook idempotency key
);
create table event_tickets (
  id uuid primary key, order_id uuid not null references event_orders(id) on delete cascade,
  event_id uuid not null references community_events(id) on delete cascade,
  holder_id uuid not null references users(id) on delete cascade,
  qr_nonce text not null unique,            -- server-signed at render time; single check-in
  checked_in_at timestamptz
);
```

New `backend/api/src/routes/payments.ts` + `backend/api/src/routes/events.ts`: provider-agnostic order flow (create pending order → provider checkout → **webhook** flips to `paid` and mints tickets, idempotent on `(provider, provider_ref)`). Razorpay first (INR default) with Stripe behind the same interface. Ticket QR = HMAC-signed `{ticket_id, event_id, exp}` verified by a host-side scan endpoint. Free-RSVP ships first (capacity + `price_minor = 0`) to de-risk the calendar/UX before money exists.

### Phase 3 — Monetization
- Paid create/join: `communities.join_price_minor` + `create` paywall reusing the Phase-2 order tables (an order with `kind='community_join'` — add a `kind` column to `event_orders` and rename it `orders` in that migration).
- Platform fee: `fee_minor` column on orders; payouts/KYC in their own table with a different access profile, exactly as `029_creator_profiles.sql:104-107` already reserved.
- Larger channels: raise the member cap only after batching `mls_key_packages` consumption and `mls_group_events` inserts (multi-row VALUES + single Redis pipeline) — §2.1.

### Risks, ranked
1. **Host-DM gate scope creep** — the `opened_via='community'` path must stay member→owner; reviewed against `029_creator_profiles.sql:13-23`.
2. **MLS churn at scale** — mitigated by member cap + batching (§2.1); do not ship open discovery without the cap.
3. **Payments correctness** — webhook idempotency + NULL-free unique keys designed in from the first migration (§2.5).
4. **Announcement posting rights** — server-side role check, since MLS grants decrypt rights to all members regardless.
