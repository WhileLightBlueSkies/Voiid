# Community public posts: admin-only authorization audit

> **Date:** 15 Sep 2026  
> **Baseline:** `main` at `9fc79f3`  
> **Required rule:** only the community owner or an active community admin may publish a public Home-feed post.  
> **Scope:** community creation/defaults, Home-feed composer visibility, post API authorization, role/state checks, settings, schema, existing communities, tests, and the separate announcement-channel flow.  
> **Method:** read-only source/history audit. No application code or database data was changed.

---

## Executive summary

The reported behavior is confirmed. Ordinary active members can publish public posts by design in the current implementation.

This is not only a client-side visibility bug. The authorization model is configurable between `members` and `managers`, the database defaults every community to `members`, new-community creation relies on that default, both mobile apps show the post composer to members when that value is present, and the backend accepts their POST requests.

The backend does correctly enforce `managers` when a community is configured that way. It defines a manager as the community owner or an active member whose role is `owner` or `admin`. Therefore the safest change is to remove the public-feed policy choice and make the POST route unconditionally require that manager check. Hiding the composer alone would not secure the endpoint.

**Assessment: P1 authorization/product-policy defect.** There is no authentication bypass: the caller must be an active member. The defect is that the granted role is broader than the required product rule, allowing every member to publish server-readable content to a community’s public-facing feed.

## Current authorization flow

1. Migration 066 adds `posting_policy` with allowed values `members` or `managers`, defaulting to `members` ([066_official_communities.sql:4](../../database/migrations/066_official_communities.sql#L4)).
2. Community creation does not write a posting policy, so every new community inherits `members` ([communities.ts:457](../../backend/api/src/routes/communities.ts#L457)).
3. The community card returns that policy to clients.
4. iOS shows the composer when the policy is not `managers`, or when the viewer is a manager ([CommunityDetailView.swift:462](../../apps/ios/Voiid/Voiid/Main/CommunityDetailView.swift#L462)). Android uses the same rule ([CommunitiesHomeView.kt:557](../../apps/android/app/src/main/java/com/voiid/app/main/CommunitiesHomeView.kt#L557)).
5. `POST /communities/:id/posts` first requires active membership, then rejects a non-manager only when `posting_policy === 'managers'` ([communities.ts:1961](../../backend/api/src/routes/communities.ts#L1961)). With the default `members` value, an ordinary member is authorized.

## Findings

| ID | Severity | Finding |
|---|---:|---|
| CP-01 | P1 | The backend expressly authorizes ordinary members under the default policy |
| CP-02 | P1 | Every new and pre-existing migrated community defaults to member posting |
| CP-03 | P2 | Both mobile apps expose the public-post composer to ordinary members |
| CP-04 | P2 | Managers can re-enable member posting after it is disabled |
| CP-05 | P2 | iOS and Android do not expose the same policy-management experience |
| CP-06 | P2 | Existing member-authored posts require an explicit product/migration decision |
| CP-07 | P2 | Test coverage validates optional manager-only behavior, not the required invariant |
| CP-08 | P3 | Public Home posts and encrypted announcement-channel messages are separate controls |

## Detailed findings

### CP-01 · P1 · Backend authorization permits ordinary members

**Evidence.** The post route calls `communityAccess(..., false)`, which checks active membership without requiring an admin role. It then performs the manager check only when the community policy happens to equal `managers` ([communities.ts:1949](../../backend/api/src/routes/communities.ts#L1949)).

This means a modified client, older app, or direct API request from any active member succeeds for the normal/default policy. Client UI changes alone cannot enforce the requested rule.

**Required correction.** Make the server route unconditionally require owner/admin authorization. Reuse the existing centralized manager helper or call `communityAccess(..., true)` so suspended, left, and banned admins remain denied. Keep authorization immediately before the insert and fail closed on database errors.

### CP-02 · P1 · The schema and creation path default to the wrong policy

**Evidence.** `posting_policy` is `NOT NULL DEFAULT 'members'` ([066_official_communities.sql:4](../../database/migrations/066_official_communities.sql#L4)). The create route’s INSERT omits the column, guaranteeing that default for new communities ([communities.ts:457](../../backend/api/src/routes/communities.ts#L457)). When migration 066 was applied, existing communities also received that non-null default.

**Impact.** The vulnerable/broader permission is not an edge configuration. It is the default population-wide state unless a manager manually changed it.

**Required correction.** If the product rule is universal, remove the policy distinction rather than merely changing the default. At minimum, migrate every community to `managers`, change the default, and make the write route unconditional. Retaining `members` as a valid value creates a dormant path that can re-enable the defect.

### CP-03 · P2 · Both clients intentionally show member authoring

**Evidence.** iOS computes `canPost` as policy-is-not-managers OR viewer-is-manager ([CommunityDetailView.swift:462](../../apps/ios/Voiid/Voiid/Main/CommunityDetailView.swift#L462)), and renders the compose bar when true ([CommunityHomeTab.swift:118](../../apps/ios/Voiid/Voiid/Main/CommunityHomeTab.swift#L118)). Android mirrors the same calculation and render guard ([CommunitiesHomeView.kt:557](../../apps/android/app/src/main/java/com/voiid/app/main/CommunitiesHomeView.kt#L557), [CommunityHomeTab.kt:210](../../apps/android/app/src/main/java/com/voiid/app/main/CommunityHomeTab.kt#L210)).

**Required correction.** Derive composer visibility only from the authoritative owner/admin role. Also dismiss or disable an already-open composer if a live role refresh demotes the user; regardless, the server remains the security boundary.

### CP-04 · P2 · Managers can re-enable ordinary-member posting

**Evidence.** The general community PATCH route permits a manager to set either `members` or `managers` ([communities.ts:1401](../../backend/api/src/routes/communities.ts#L1401)). Android exposes this directly as an “Only managers can post” toggle ([CommunitySettingsScreen.kt:213](../../apps/android/app/src/main/java/com/voiid/app/main/CommunitySettingsScreen.kt#L213)).

**Required correction.** Remove `posting_policy` from the public PATCH contract, or accept only `managers` during a compatibility window and later remove the field. Remove the toggle from clients. Silently ignoring `members` is not recommended; return a clear validation error to reveal stale clients and attempted policy regression.

### CP-05 · P2 · Policy-management UI differs by platform

Android exposes the managers-only toggle and writes `posting_policy`. The audited iOS settings view contains no equivalent control, although iOS consumes the returned value to decide whether a member can compose. This creates cross-platform administration drift: an Android manager can change behavior that an iOS manager can observe but cannot manage.

The universal admin-only rule removes this inconsistency rather than requiring feature parity for a setting that should no longer exist.

### CP-06 · P2 · Existing member-authored posts need a deliberate decision

Changing authorization prevents future posts; it does not alter existing `community_posts` rows. Those rows are server-readable public-feed content and remain visible until removed.

**Decision required before implementation:**

- **Recommended:** grandfather existing posts and enforce admin-only prospectively. This preserves community history and avoids surprising data loss.
- If policy requires removing historical member posts, soft-remove them using the existing moderation columns, record an auditable actor/reason, and notify affected communities. Do not hard-delete rows in a blanket migration.

### CP-07 · P2 · Tests prove a configuration, not the product invariant

The PostgreSQL community suite manually changes one fixture to `posting_policy='managers'` and confirms an ordinary member receives 403 ([communitiesPostgres.test.ts:77](../../backend/api/test/communitiesPostgres.test.ts#L77)). That proves the optional branch works. It does not prove that:

- a default/new community denies an ordinary member;
- an existing community whose stored value is `members` denies an ordinary member;
- a PATCH cannot restore `members`;
- an active admin and owner can still post;
- a pending, left, banned, or demoted admin cannot post;
- both clients hide authoring immediately after demotion or policy removal.

**Required tests.** Add an authorization matrix at the API boundary for owner, active admin, ordinary member, pending member, left/banned admin, and outsider. Test both newly created and migrated legacy rows. Add one client/store test per platform for role-driven composer visibility.

### CP-08 · P3 · Do not confuse Home-feed posts with announcement-channel messages

There are two different publishing surfaces:

- `community_posts`: server-readable public Home-feed posts, handled by `/communities/:id/posts`—the subject of this audit.
- announcement-channel messages: MLS-encrypted channel messages. These already have a server-side owner/admin restriction in the general message-send path ([communityGuard.ts:50](../../backend/api/src/communityGuard.ts#L50)).

Changing only the announcement guard will not fix public posts. Conversely, the public-post change should not accidentally restrict ordinary members from participating in normal non-announcement community channels.

## Root-cause conclusion

The root cause is a product-policy mismatch encoded consistently across the stack. The implementation treats public posting as a per-community option and deliberately defaults it to every active member. The requested behavior treats admin-only posting as a global invariant.

Because the current stack is internally consistent, the fix must also be cross-layer: backend invariant, schema/default cleanup, API contract cleanup, client composer gating, settings removal, migration strategy, and regression tests. Fixing only one layer will leave either a security bypass or a confusing UI.

## Recommended implementation order

1. Make `POST /communities/:id/posts` unconditionally owner/admin-only.
2. Add the complete role/state authorization matrix tests.
3. Migrate all stored policies to `managers`; change/remove the `members` default and value.
4. Stop accepting `posting_policy='members'` through PATCH.
5. Gate iOS and Android composers only on owner/admin role and remove Android’s toggle.
6. Grandfather existing posts unless a separate moderation decision requires soft-removal.
7. Verify with two accounts: owner/admin succeeds; ordinary member sees no composer and receives 403 from a direct request.

## Verification notes

- Confirmed the behavior in schema, create route, update route, post route, centralized role helper, iOS Home screen, Android Home screen/settings, service clients, and PostgreSQL tests.
- Confirmed owner/admin semantics are already centralized: owner, or an active roster member with `owner`/`admin`; ordinary, pending, left, banned, and demoted members do not qualify ([communityRoles.ts:42](../../backend/api/src/communityRoles.ts#L42)).
- No application code, migration, test, or database row was changed as part of this audit.
