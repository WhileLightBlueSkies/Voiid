# What is pending

Audit date: **2 September 2026**. Method: every backend route extracted from
`backend/api/src/routes/*.ts` and diffed against the paths each client actually calls
(iOS `*.swift`, Android `*.kt`, admin panel `app/`). Findings below were confirmed by
reading the code, not inferred from file names.

Backend surface: **225 app routes + 31 admin routes**.

---

## 1. Admin panel — complete

All **31/31** admin routes now have a caller. Closed this session:

| Route | Was | Now |
|---|---|---|
| `GET /admin/clips/:id/playback` | no caller | Watch button → in-page player |
| `DELETE /admin/clips/:id` | no caller | inside the player only |
| `GET /admin/communities/:id/posts` | no caller | feed on community detail |
| `GET /admin/users/:id` | no caller | full account page |
| `GET /admin/events` | **did not exist** | Events & revenue list |
| `GET /admin/events/:id` | **did not exist** | event detail + order ledger |

### Pricing was not "hidden" — it did not exist

The panel could show a *count* of events and orders on the dashboard
([admin.ts:251](../backend/api/src/routes/admin.ts#L251)) and nothing else. There was no
route exposing ticket price, order amounts, settlement state, or refunds. Two routes were
added, plus the two pages that consume them.

Decisions worth knowing:

- **Revenue counts `paid` orders only.** Pending money is not money; counting it would
  overstate every figure an operator acts on. Pending is surfaced as its own line to chase.
- **Refunds sit beside the take, never netted into it.** "Collected" and "refunded" answer
  different questions, and a single net number hides both.
- **Money stays in minor units server-side.** The decimal point is placed once, in
  `money()` in the panel. A float rupee is a rounding bug waiting for a reconciliation.

> **Not yet runtime-verified.** There is no local database in this checkout, and
> `api-dev` deploys from the `dev` branch while this work is on `main`. Every column was
> checked by hand against `database/migrations/032_events_tickets.sql` and `030_communities.sql`
> — one real error was caught that way (`event_tickets` has `state`, not `revoked_at`) —
> but the SQL has not been executed. **Run these two routes once against dev before relying
> on the numbers.**

---

## 2. iOS — community and events flow

The flow is otherwise complete: create, discover, join, post, moderate, roster, roles, bans,
rules, announcements, links, host threads, tournaments. Event hosting (create, publish,
cancel, orders, check-in) and the attendee ticket wallet all work.

Four routes have no iOS caller:

| Route | What is missing | Impact |
|---|---|---|
| `POST /communities/:id/invites` | minting an invite link | A host cannot create one in-app. iOS can *redeem* a token ([CommunityService.swift:187](../apps/ios/Voiid/Voiid/Networking/CommunityService.swift#L187)) but never issue one — so invite links must come from elsewhere. |
| `DELETE /communities/:id/invites/:token` | revoking one | The backend comment calls a server-side capability "the one that can actually be REVOKED". Nothing in the app can revoke it. |
| `GET /events/:id` | single-event fetch | Events are only ever read from the community list, so a deep link to one event cannot resolve. |
| `POST /events/:id/orders/:orderId/cancel` | refund / cancel an order | A host can see orders but cannot cancel one. Refunds have no client on any platform. |

**Invite mint + revoke is the most valuable pair here** — together they are a whole feature
that exists on the server and is unreachable by any user.

### Also unreachable from iOS (outside the community flow)

`/profile-keys/*` (publish, pending, photo, for/:id) has **no HTTP caller at all**. The Rust
core generates profile keys ([voiid.swift:2360](../apps/ios/Voiid/Voiid/voiid.swift#L2360))
but nothing distributes them. Encrypted profile distribution is built on both ends and not
connected. Same for `POST /prekeys/refresh`, `POST /media/confirm`, `POST /auth/logout`,
and `GET /calls/metrics/summary`.

---

## 3. Android — the real gap

Android has `EventService.kt` with exactly **two** functions: `list` and `rsvp`.

There is **no event UI beyond a read-only list**. iOS has five event screens; Android has
none of them:

| iOS | Android |
|---|---|
| `EventCreateFlow.swift` | — |
| `EventHostView.swift` | — |
| `EventCheckInView.swift` | — |
| `EventTicketsView.swift` | — |
| `CommunityEventsSection.swift` (full) | `CommunityEventsSection.kt` (read-only) |

The Android section says so itself, in the file
([CommunityEventsSection.kt:47](../apps/android/app/src/main/java/com/voiid/app/main/CommunityEventsSection.kt#L47)):
a paid event renders **"Ticketing soon"**.

So on Android today: you can see that an event exists and RSVP. You cannot buy a ticket,
hold a ticket, create an event, publish one, or check anyone in.

Other missing Android screens against iOS: `CommunityAdminPanel`, `CommunityDetailView`,
`CommunityDiscoverSheet`, `CommunityAuthoring`. Composables 141 vs 173 iOS views.

---

## Suggested order

1. **Verify the two new admin routes against dev.** They are unexecuted SQL; everything
   else here depends on the numbers being right.
2. **iOS invite mint + revoke.** Smallest work, completes a server feature that is currently
   dead for every user.
3. **Android ticketing.** The largest gap in the product — a paid event is unsellable on
   half the install base. Needs order placement, the wallet, and the QR sheet at minimum.
4. **Order cancel / refund**, on both platforms. Money can go in and cannot come back
   without database access.
5. `GET /events/:id`, so event deep links resolve.
