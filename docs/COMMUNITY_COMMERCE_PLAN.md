# Community commerce — audit and plan

*Written 2026-08-28. Audit is of the code as it stands, not of intent.*

## 1. What actually exists today

### Events and ticketing — built, and better than expected

`routes/events.ts` (13 routes) is complete for **free** events:

- `community_events` holds `title, description, starts_at, ends_at, location_text, capacity, price_minor, currency, status, created_by`. Status is `draft | published | cancelled`; only `published` takes orders.
- `event_orders` carries `status` (`pending | paid | refunded | cancelled | failed`), `provider`, `provider_ref`, `failure_reason`.
- `event_tickets` are minted on payment, with **HMAC-signed rotating QR codes** (`payments/tickets.ts`) and a check-in path.
- Authorisation is correct: event creation goes through `communityAccess(communityId, userId, true)`, so only managers can host.

**The gap is one thing: no payment provider.** `payments/provider.ts` defines a clean `PaymentProvider` interface (`createCheckout`, `verifyWebhook`, refund support) and an **empty registry**. Every paid path returns `501 "paid events are not available yet"` — `events.ts:183`, `:373`, `:492`. This is deliberate and well-documented, not an oversight.

`routes/payments.ts` has the full webhook fulfilment path already written: signature verification over raw bytes, idempotency on `(provider, provider_ref)`, order → `paid` → mint tickets, correct 200-vs-retry semantics.

**So: ticketing is ~90% done and blocked on a single integration.**

### What does NOT exist — at all

| Concept | Status |
|---|---|
| Ticket **tiers / passes** (VIP, early-bird, day pass) | **Absent.** One `price_minor` per event, nothing else. |
| **E-commerce** (products, cart, inventory, SKU, fulfilment) | **Absent.** No tables, no routes. |
| **Paid communities** / subscription tiers | **Absent.** No `is_paid`, `plan`, or `tier` on `communities`. |
| **Entitlements / billing state** | **Absent.** `feature_flags` in `config.ts` is global per-build, not per-community. |
| Tournament entry fees / prize pools | **Absent.** Zero monetisation in `tournaments.ts`. |
| Creator monetisation (tips, subs, payouts) | **Absent.** Zero in `creators.ts`. |
| **Payouts to community owners** | **Absent.** Money can come in; nothing sends it out. |

### Moderation of other communities — done this session

`/admin/communities` (list, detail, suspend, restore, posts) plus ban/unban/role. That half of your ask is already live.

---

## 2. The shape of what you described

Three distinct businesses, and they should not be built as one:

1. **Voiid hosts its own community**, managed from the admin panel.
2. **Voiid moderates other communities** — platform-level oversight. *Done.*
3. **Paid-only features** (e-commerce, richer events) that other communities buy.

(3) is the one that changes the architecture, because it makes Voiid a **marketplace operator** rather than a messaging app: taking money on behalf of third parties, holding it, paying it out, and being liable when an event is cancelled or a product never ships.

---

## 3. Decisions needed before any code

These are business decisions, not technical ones, and each blocks real work.

**A. Who is the merchant of record?**
- *Platform-as-merchant* — Voiid takes the money, owes payouts to hosts. Simple checkout, but Voiid is liable for refunds and chargebacks, needs settlement/reconciliation, and in India this attracts payment-aggregator scrutiny (RBI PA/PG rules).
- *Host-as-merchant* (Razorpay Route / Stripe Connect) — money goes to the host's own account, Voiid takes a commission. Far less liability; onboarding each host requires KYC.

**Recommendation: host-as-merchant via Razorpay Route.** Voiid is an Indian company with rupee-denominated events; Route settles to the host and handles the split, which keeps Voiid out of the money-holding business.

**B. What is actually paid-only?** Charging per-transaction (a % of ticket/product sales) is cleaner than a subscription tier: it needs no entitlement system, aligns Voiid's revenue with the host's, and nobody pays for a month they didn't sell in.

**C. GST and invoicing.** Ticket sales in India need a GST-compliant invoice. This is not optional and is usually underestimated.

---

## 4. Proposed build order

Each phase ships something usable and is independently valuable.

### Phase 1 — Turn on payments (unblocks everything)
- Implement `RazorpayProvider` against the existing interface. One class, one `register()` line.
- Set `VOIID_PAYMENT_PROVIDER=razorpay`, wire webhook secret.
- Remove the three 501s; add the price field to the iOS create screen (`EventService.swift` already documents where).
- **Result: paid events work.** No schema change. This is days, not weeks, because everything else is built.

**Two bugs MUST be fixed in the same phase.** Both are unreachable today only because no
provider is registered — the moment one is, they become live defects that cost real money:

1. **The paid order branch oversells.** `events.ts:489-540` performs no capacity check and
   takes no row lock, unlike the free branch at `events.ts:552-577` which does
   `select capacity ... for update` and sums pending+paid quantities. Register a provider and
   a sold-out event keeps selling. This is the single most expensive bug in the codebase
   right now, because the failure mode is refunding strangers at the door.

2. **Abandoned pending orders hold seats forever.** Acknowledged in-code at
   `events.ts:617-621`: there is no scheduled sweep expiring `pending` orders, and pending
   orders count against capacity. A dozen abandoned checkouts silently close a venue.
   Needs a TTL on pending orders plus a sweeper.

Also worth closing here: there is **no organiser- or admin-initiated refund route**. Paid
orders return `409 'a paid order must be refunded through the payment provider'`
(`events.ts:687`), and the provider refund path only fires from a webhook. Cancelling an
event deliberately does not refund. So today, cancelling a paid event would leave every
buyer charged with no in-product way to make them whole — which is a support and legal
problem, not merely a missing feature.

### Phase 2 — Ticket tiers / passes
- New `event_ticket_tiers` (event_id, name, price_minor, capacity, sale window, sort).
- `event_orders` gains `tier_id`; capacity moves from event to tier with the event cap as a ceiling.
- Admin + app UI for managing tiers.

### Phase 3 — Platform commission + payouts
- `platform_fee_bps` on the community or globally; Route split at checkout.
- Admin views: revenue by community, settlement status, refund handling.
- Host-facing earnings view in-app.

### Phase 4 — E-commerce (the largest piece; a real product, not a feature)
- `community_products`, `product_variants`, `product_orders`, inventory, fulfilment status, shipping address capture.
- Reuses the same provider/webhook path as tickets — that reuse is why Phase 1 comes first.
- Needs a returns/refunds policy and a dispute path before launch.

### Phase 5 — Voiid's own community
- Nothing special required: it is a community whose owner is a Voiid account, managed through the same admin panel. Worth doing **after** Phase 1 so we dogfood paid events ourselves before selling them.

---

## 5. What I would not do

- **Do not build a subscription/entitlement system first.** Per-transaction commission needs no entitlements, and building billing state before there is anything to bill is the most common way this goes wrong.
- **Do not let Voiid hold funds** unless there is a deliberate decision to become a payment aggregator, with the compliance that implies.
- **Do not start with e-commerce.** It is the biggest surface, the most operational burden (shipping, returns, disputes), and it depends on the same payment rails Phase 1 delivers.

---

## 6. Immediate next step

Confirm **A** (merchant of record) and **B** (commission vs subscription). Phase 1 can start the moment A is answered, and it makes the existing, already-built ticketing system real.
