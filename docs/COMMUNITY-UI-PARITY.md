# Community flow vs the Voiid UI reference

Audit date: **4 September 2026**. Compared `/Users/devacc/Voiid Ui` (the reference Xcode
project, 90 Swift files) against the shipped iOS app screen by screen.

**Verdict: structurally complete, with one hole — the attendee cannot buy a ticket.**

---

## Where the shipped app matches the reference

| Reference screen | Shipped | State |
|---|---|---|
| `CommunitiesScreen` | `CommunitiesHomeView` | ✅ + discover sheet |
| `CommunityHomeScreen` | `CommunityDetailView` + `CommunityHomeTab` | ✅ |
| `CommunityTabs` (Home/Spaces/Events/Members/About) | `CommunityTabs` | ✅ same five |
| `CommunitySpacesTab` → `SpaceDetailScreen` | `CommunitySpacesTab` → real conversation | ✅ better — opens the actual chat |
| `CommunityMembersTab` | `CommunityMembersTab` | ✅ |
| `CommunityAboutTab` | `CommunityAboutTab` | ✅ |
| `CreateCommunityFlow` | `CommunityCreateFlow` | ✅ |
| `CommunitySettingsScreen` | `CommunitySettingsView` | ✅ |
| `CommunityInboxScreen` / `CommunityThreadScreen` | `CommunityInboxView` / `CommunityHostThread` | ✅ |
| `CommunityAdminScreens` / `ManageAdminsScreen` | `CommunityAdminPanel` | ✅ roles, bans, approve, remove, queue |
| `CreateEventSheet` | `Hosting/EventCreateFlow` | ✅ |
| — | `Hosting/EventHostView`, `Hosting/EventCheckInView` | ✅ beyond reference |
| — | `EventTicketsView` (wallet + QR) | ✅ beyond reference |

The admin dashboard, announcements, pinning, moderation queue, post composer, likes, links
and tournaments are all present and wired to real endpoints.

---

## The hole: no attendee purchase path

The reference has two screens the app does not:

**`EventDetailScreen`** (524 lines) — tapping an event opens it in full: seats left, waitlist,
price, and a footer whose label is the state machine:

```
if store.hasTicket(event.id) { return "View ticket" }
return event.price == .zero ? "RSVP" : "Book · \(event.price.text)"
```

**`EventBookingSheet`** (413 lines) — the purchase: price + booking fee on separate lines,
payment method (UPI / wallet / card), and the wallet row disables itself when short, with
top-up offered in place. Its header states the rule:

> A payment method that will fail is worse than one that is missing: the buyer picks it,
> commits, and is bounced.

### What the app does instead

In [CommunityEventsSection.swift](../apps/ios/Voiid/Voiid/Main/CommunityEventsSection.swift),
a member's event row renders one of four things, and a paid event gets:

```swift
} else if !e.free {
    // The one honest thing to render: the server answers 501 here.
    Text("Ticketing soon")
```

That comment is accurate — `activeProvider()` returns `null` because no payment provider is
registered, so the server refuses paid events with a 501. The UI is telling the truth.

Also: **a member's event row is not tappable at all.** Only a host gets a tap target
(`row(_:)` branches on `isHost`). So there is no event detail screen for anyone who is not
running the event — no description, no seats left, no waitlist.

---

## What this means in practice

| Path | Works today |
|---|---|
| Free event → RSVP → ticket in wallet → QR at door | ✅ end to end |
| Paid event → book → pay → ticket | ❌ "Ticketing soon" |
| Any event → tap to see full detail | ❌ hosts only |

So the community flow is complete **for free events**. The paid path is blocked at the
payment provider, not at the UI — and that is the correct order, since a booking sheet
wired to a 501 would be worse than the honest label.

---

## To reach parity

1. **Register a payment provider.** [`payments/provider.ts`](../backend/api/src/payments/provider.ts)
   is a finished seam with an empty registry — a class, one `register()` line, an env var.
   Nothing else unblocks the paid path.
2. **`EventDetailScreen` for everyone**, not just hosts. This is worth doing *before*
   payments: description, seats left and location have nowhere to display today.
3. **`EventBookingSheet`** once (1) lands. Keep the reference's two rules: fee on its own
   line, and never offer a method that will fail.
4. Waitlist — in the reference, absent from the schema. Needs a migration, so it is a
   separate piece of work rather than a UI job.

### Not in the reference at all
`facePile` on the community header. Minor, but it is the one visual element in
`CommunityHomeScreen` with no shipped counterpart.
