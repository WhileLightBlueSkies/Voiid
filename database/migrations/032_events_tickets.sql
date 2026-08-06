-- 032_events_tickets.sql — community events, orders and tickets. THE FIRST MONEY IN THIS REPO.
--
-- ==================== NOT END-TO-END ENCRYPTED — A SCOPED EXCEPTION ====================
-- Stated in the same voice, and with the same limits, as 022_clips.sql and 024_games.sql,
-- because it is the same kind of statement: a narrow, reasoned carve-out, never a precedent.
--
-- WHY THESE ROWS CANNOT BE CIPHERTEXT. Every one of these has a counterparty who is not the
-- user and who must be able to read the row:
--
--   an order .... a payment provider settles it, a bank reverses it, an accountant reconciles
--                 it, and a chargeback is decided months later by somebody who was never in
--                 the conversation. A payment the server cannot read is a payment nobody can
--                 refund and nobody can dispute.
--   a ticket .... someone on a door has to be told yes or no, in under a second, offline-ish,
--                 for a person they have never met. A ticket the server cannot read cannot be
--                 validated at the door.
--   an event .... it is an ADVERTISEMENT. Its whole purpose is to be shown to people who have
--                 not joined yet. Encrypting a poster to an audience you are trying to
--                 recruit is a contradiction, not a safeguard.
--
-- WHAT DOES NOT CHANGE, AND WILL NOT: messages, calls, location shares and moments stay
-- end-to-end encrypted and the server still cannot read any of them. Nothing in this file
-- touches the message pipe, the MLS tables, or any key. If a later change cites this file as
-- a reason to weaken any of those, the citation is wrong.
--
-- ONE SPECIFIC TRAP, NAMED SO IT IS NOT WALKED INTO: `community_events.location_text` IS FREE
-- TEXT AND IS NOT AN E2EE LOCATION SHARE. 018_location_shares.sql holds the encrypted kind,
-- and this column must never be wired to it, populated from it, or presented as it. A venue
-- address on a public poster and a live fix of where a person is standing are different facts
-- with different consequences, and the only thing stopping them being confused is that
-- somebody wrote this paragraph.
-- =====================================================================================
--
-- ── NO PAYMENT PROVIDER IS CHOSEN, AND THIS FILE DOES NOT CHOOSE ONE ─────────────
--
-- The founder has not picked a processor. So `provider` is a TEXT LABEL, not an enum and not
-- a check constraint listing vendors: adding Razorpay, Stripe or anything else must be a
-- config change and a class implementing the interface in backend/api/src/payments/, never a
-- migration. The only value this file knows by name is 'free', which is what a zero-price RSVP
-- records — free RSVP is the surface that ships first (04_communities_plan.md §4 Phase 2), and
-- it exercises the whole order/ticket path with no money in it.
--
-- ── TWO IDEMPOTENCY KEYS, NOT ONE. THIS IS THE MOST IMPORTANT PARAGRAPH HERE ─────
--
-- A payment webhook WILL be delivered twice. Every provider retries on a slow or failed
-- acknowledgement, and at-least-once is the only delivery guarantee any of them offers. If a
-- second delivery mints a second ticket, a customer holds two tickets for one payment and the
-- door lets in two people. So there are two distinct unique keys, doing two distinct jobs:
--
--   1. event_orders  UNIQUE (provider, provider_ref)
--      Identifies the ORDER at the provider. One order, one payment reference, forever.
--
--   2. payment_webhook_events  UNIQUE (provider, provider_event_id)
--      Identifies one DELIVERY. This is the key the webhook handler inserts against, and the
--      insert succeeding is what grants permission to act.
--
-- KEY 1 CANNOT DO KEY 2'S JOB, which is the mistake the plan sketch invites by naming only
-- (provider, provider_ref) as "the webhook idempotency key". A provider sends SEVERAL events
-- about one order — authorized, captured, failed, later refunded — all carrying the same
-- provider_ref. Deduplicating on provider_ref would either drop the legitimate refund event or,
-- if it did not, would let a replayed capture through. The delivery key has to be the event id.
--
-- BOTH KEYS ARE NULL-FREE, and both columns of both are NOT NULL. A NULL anywhere in a unique
-- key makes ON CONFLICT never match — the conflict target simply does not fire — which turns
-- an upsert into a silent second INSERT. That bug has already shipped in this repo once;
-- 027_receipt_null_device.sql exists to undo it. Here the failure mode is a duplicate webhook
-- minting a second paid ticket, which is money.
--
-- ── A TICKET IS NOT A MEMBERSHIP ─────────────────────────────────────────────────
--
-- 030_communities.sql's PHASE-2 HOOKS block says this and it is repeated here because it is the
-- kind of shortcut that looks helpful at 2am: holding a ticket puts NO row in
-- community_members, and therefore does NOT grant the member->host messaging exception in
-- 020_reachability.sql. Buying entry to one evening is not joining a space, and it is certainly
-- not a right to message anybody. A FOLLOW, A JOIN AND A TICKET ALL GRANT NO MESSAGING RIGHT.
--
-- ── RETENTION IS AN OPEN LEGAL QUESTION AND IS LEFT OPEN ─────────────────────────
--
-- [COUNSEL] Financial records are the first data in this schema that may have a statutory
-- retention FLOOR — tax and accounting law can require an order to be KEPT for years — which
-- points the opposite way from a DPDP erasure request. Nothing in this file picks a number,
-- and the retention sweep must not pick one for these tables either. This is the same open
-- question docs/research/11_admin_dpdp.md §6 item 3 records as "defensible retention numbers",
-- still an engineering placeholder there, not a legal answer. Carried forward, not resolved.
--
-- [COUNSEL] A payment provider is a PROCESSOR under DPDP s.8(2), which the same document's §6
-- item 5 flags as needing processor-contract review alongside R2, Firebase and LiveKit. Choosing
-- a provider is therefore a legal step as well as a technical one. Nothing here asserts that
-- Voiid complies with anything; this file implements controls.

-- ─────────────────────────────────────────────────────────────────────────────────
-- The event
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists community_events (
    id            uuid primary key default gen_random_uuid(),

    -- Events only exist inside a community, exactly as tournaments do (031). The container is
    -- what makes an audience and an organiser both well-defined.
    community_id  uuid not null references communities(id) on delete cascade,

    title         text not null,
    description   text,

    starts_at     timestamptz not null,
    ends_at       timestamptz,

    -- FREE TEXT. Read the trap paragraph in the header before touching this column.
    location_text text,

    -- Null means unlimited. Enforced in the route under a row lock, NOT by a constraint: "how
    -- many tickets point at this event" is a question about other rows, which a CHECK cannot
    -- ask. See the note on event_tickets.
    capacity      int,

    -- MINOR UNITS, and integer. Never a float — 0.1 + 0.2 is not 0.3 in binary floating point
    -- and money that does not add up is the one bug nobody forgives. bigint because a minor
    -- unit is small: ₹50,00,000 is 500000000 paise, which is comfortable here and would not be
    -- in an int.
    price_minor   bigint not null default 0,
    currency      text not null default 'INR',

    -- draft     -> only the organisers can see it
    -- published -> visible to the community; orders may be created
    -- cancelled -> no new orders; existing tickets are left alone (see below)
    status        text not null default 'draft',

    created_by    uuid not null references users(id) on delete cascade,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),

    constraint community_events_title_len
        check (char_length(title) between 1 and 120),
    constraint community_events_description_len
        check (description is null or char_length(description) <= 4000),
    constraint community_events_location_len
        check (location_text is null or char_length(location_text) <= 300),
    constraint community_events_status_check
        check (status in ('draft', 'published', 'cancelled')),
    constraint community_events_capacity_positive
        check (capacity is null or capacity > 0),
    constraint community_events_price_nonneg
        check (price_minor >= 0),
    -- ISO-4217 shape only. Not a list of currencies: a list would be a migration every time a
    -- new market opens, and the provider is the authority on what it can actually settle.
    constraint community_events_currency_format
        check (currency ~ '^[A-Z]{3}$'),
    constraint community_events_ends_after_starts
        check (ends_at is null or ends_at > starts_at)
);

-- The community's event tab: upcoming first. Partial on published because that is the only
-- listing anyone but an organiser ever asks for.
create index if not exists idx_community_events_upcoming
    on community_events (community_id, starts_at)
    where status = 'published';

-- The organiser's own view, which must include drafts and cancellations.
create index if not exists idx_community_events_all
    on community_events (community_id, starts_at desc);

drop trigger if exists trg_community_events_updated_at on community_events;
create trigger trg_community_events_updated_at before update on community_events
    for each row execute function set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────────
-- The order
--
-- An ORDER, not a column on the event and not a column on the community. 030's PHASE-2 HOOKS
-- block sets that rule for a community join price and it holds here for the same reason: a
-- price is a fact about the container, but a PURCHASE is an event in time with a counterparty,
-- a currency, a provider reference and a life of its own. Phase 3's paid community join becomes
-- a `kind` column on this table, not a second table.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists event_orders (
    id              uuid primary key default gen_random_uuid(),

    event_id        uuid not null references community_events(id) on delete cascade,
    buyer_id        uuid not null references users(id) on delete cascade,

    -- How many tickets this order mints when it is paid. Capped low deliberately: a group
    -- booking is a real need, a hundred-ticket order from one account at an MVP door is not.
    quantity        int not null default 1,

    -- PRICE IS SNAPSHOTTED, not read back from the event at settlement time. An organiser who
    -- raises the price on Tuesday must not retroactively change what Monday's buyer owed, and a
    -- refund has to return what was actually taken.
    unit_price_minor bigint not null,
    amount_minor     bigint not null,
    currency         text not null,

    -- BOTH NOT NULL — see the header's two-keys paragraph. 'free' is the provider for a
    -- zero-price RSVP and its provider_ref is the order's own id, which keeps the pair unique
    -- without inventing a nullable column.
    provider        text not null,
    provider_ref    text not null,

    -- pending   -> created, not settled. The only state a client can put an order into.
    -- paid      -> the provider says the money moved. Tickets exist from here.
    -- failed    -> the provider says it did not.
    -- cancelled -> abandoned before settlement, by the buyer or by a sweep.
    -- refunded  -> money returned after having been taken.
    status          text not null default 'pending',

    -- Why an order stopped, in the provider's words. Diagnostic only; never shown as-is to a
    -- buyer, because a processor's decline reason is frequently either meaningless or a hint
    -- about somebody's bank that is not ours to relay.
    failure_reason  text,

    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    settled_at      timestamptz,

    constraint event_orders_quantity_range
        check (quantity between 1 and 10),
    constraint event_orders_amounts_nonneg
        check (unit_price_minor >= 0 and amount_minor >= 0),
    -- The line total has to be the line total. Cheap, and it catches the whole family of bugs
    -- where a quantity change updates one column and not the other.
    constraint event_orders_amount_matches
        check (amount_minor = unit_price_minor * quantity),
    constraint event_orders_currency_format
        check (currency ~ '^[A-Z]{3}$'),
    constraint event_orders_status_check
        check (status in ('pending', 'paid', 'failed', 'cancelled', 'refunded')),
    constraint event_orders_provider_len
        check (char_length(provider) between 1 and 40),
    constraint event_orders_provider_ref_len
        check (char_length(provider_ref) between 1 and 200),
    -- Settled and unsettled are not opinions that can disagree with the status column.
    constraint event_orders_settled_coherent
        check ((status in ('paid', 'refunded')) = (settled_at is not null))
);

-- THE ORDER-LEVEL IDEMPOTENCY KEY. NULL-free by construction: both columns are NOT NULL.
create unique index if not exists idx_event_orders_provider_ref
    on event_orders (provider, provider_ref);

-- ONE LIVE ORDER PER BUYER PER EVENT.
--
-- This is what makes "RSVP" idempotent and paid checkout retry-safe in the same stroke: a
-- double-tapped RSVP lands on the row that already exists, and a buyer who abandons a checkout
-- and comes back is handed their own pending order rather than a second one to pay twice.
--
-- It is also a deliberate MVP restriction, and it is the reason `quantity` lives on the order:
-- a group booking is one order for several tickets, not several orders. A cancelled, failed or
-- refunded order falls out of the index, so a buyer whose card was declined can try again.
create unique index if not exists idx_event_orders_live_buyer
    on event_orders (event_id, buyer_id)
    where status in ('pending', 'paid');

-- The organiser's order list.
create index if not exists idx_event_orders_event
    on event_orders (event_id, created_at desc);

-- "My tickets" starts here.
create index if not exists idx_event_orders_buyer
    on event_orders (buyer_id, created_at desc);

drop trigger if exists trg_event_orders_updated_at on event_orders;
create trigger trg_event_orders_updated_at before update on event_orders
    for each row execute function set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────────
-- THE ORDER STATE MACHINE, ENFORCED BY THE DATABASE
--
-- A CHECK constraint cannot see the old row, so "pending may become paid, but paid may never
-- become pending" is not expressible as one. It is expressible as a trigger, and it is written
-- as one HERE rather than as a convention in the route because the whole point of the money
-- path is that a late, duplicated or out-of-order webhook cannot walk an order backwards.
--
-- Providers deliver events out of order. A `captured` arriving after a `refunded` is not
-- hypothetical; it is Tuesday. Without this trigger that sequence silently un-refunds a
-- customer, and the row would give no sign it had ever happened.
-- ─────────────────────────────────────────────────────────────────────────────────
create or replace function event_order_transition() returns trigger as $$
begin
    if new.status = old.status then
        return new;
    end if;

    if not (
        (old.status = 'pending' and new.status in ('paid', 'failed', 'cancelled'))
        or (old.status = 'paid' and new.status = 'refunded')
    ) then
        raise exception 'illegal order transition % -> %', old.status, new.status
            using errcode = 'check_violation';
    end if;

    -- The buyer, the event, the amount and the payment reference are the ORDER. Letting an
    -- update move any of them would make the audit trail fiction: a refund dispute is settled
    -- by what the row says, so what the row says must be what it always said.
    if new.event_id <> old.event_id
       or new.buyer_id <> old.buyer_id
       or new.amount_minor <> old.amount_minor
       or new.currency <> old.currency
       or new.provider <> old.provider
       or new.provider_ref <> old.provider_ref
       or new.quantity <> old.quantity then
        raise exception 'an order''s terms are immutable once created'
            using errcode = 'check_violation';
    end if;

    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_event_orders_transition on event_orders;
create trigger trg_event_orders_transition before update on event_orders
    for each row execute function event_order_transition();

-- ─────────────────────────────────────────────────────────────────────────────────
-- The ticket
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists event_tickets (
    id            uuid primary key default gen_random_uuid(),

    order_id      uuid not null references event_orders(id) on delete cascade,
    -- Denormalised from the order on purpose: the door scanner asks "is this ticket for THIS
    -- event", and making that question a join through orders would put an avoidable table in
    -- the one query that has to answer while somebody stands in a queue.
    event_id      uuid not null references community_events(id) on delete cascade,

    -- Who may use it. Defaults to the buyer; a transfer flow later changes this column and
    -- nothing else, which is why it is not just "the order's buyer".
    holder_id     uuid not null references users(id) on delete cascade,

    -- The rotating half of the QR code.
    --
    -- The code the phone displays is an HMAC over {ticket_id, event_id, nonce, exp} — the
    -- signature is what makes it unforgeable, and the nonce is what makes it REVOCABLE. A
    -- screenshotted ticket forwarded to a friend is defeated by regenerating the nonce, which
    -- invalidates every code minted before it. Without a stored nonce the only revocation
    -- available would be rotating the server key for everybody at once.
    qr_nonce      text not null,

    -- Single check-in is enforced by a conditional UPDATE (... where checked_in_at is null),
    -- not by a scanner reading and then writing. Two scanners at two doors is exactly the race
    -- that turns one ticket into two entries.
    checked_in_at timestamptz,
    checked_in_by uuid references users(id) on delete set null,

    -- void       -> the ticket is dead (order refunded, or the organiser voided it)
    -- valid      -> admits its holder
    state         text not null default 'valid',

    created_at    timestamptz not null default now(),

    constraint event_tickets_state_check
        check (state in ('valid', 'void')),
    constraint event_tickets_nonce_len
        check (char_length(qr_nonce) between 16 and 64),
    -- A check-in has a time and a person, or it has neither.
    constraint event_tickets_checkin_coherent
        check ((checked_in_at is null) = (checked_in_by is null))
);

-- The nonce is a lookup key for the scan path as well as a revocation handle, so it is unique
-- across every ticket rather than just within an event. NOT NULL, so ON CONFLICT on it works.
create unique index if not exists idx_event_tickets_nonce
    on event_tickets (qr_nonce);

-- "How many tickets does this event have" — the capacity count, taken under a lock on the
-- event row by the order route. The count is a question about these rows, which is precisely
-- why capacity is not a CHECK on community_events.
create index if not exists idx_event_tickets_event
    on event_tickets (event_id, state);

-- "My tickets".
create index if not exists idx_event_tickets_holder
    on event_tickets (holder_id, created_at desc);

create index if not exists idx_event_tickets_order
    on event_tickets (order_id);

-- ─────────────────────────────────────────────────────────────────────────────────
-- THE WEBHOOK DELIVERY LEDGER — the second idempotency key from the header.
--
-- A row here means "this exact delivery has been seen". The handler INSERTs first and only
-- acts if the insert produced a row; a duplicate delivery conflicts, produces nothing, and is
-- acknowledged with a 200 so the provider stops retrying. That ordering matters: checking for
-- the row and then inserting it is not idempotent under concurrency, and providers do retry
-- concurrently.
--
-- It also doubles as the payment audit trail. When an order's history is disputed months later,
-- this is the record of what the provider actually said and when, which is not something that
-- can be reconstructed from the order's current status.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists payment_webhook_events (
    id                uuid primary key default gen_random_uuid(),

    -- BOTH NOT NULL. This pair is the delivery key; a NULL in it would make ON CONFLICT never
    -- match and every retry would be processed as if it were new.
    provider          text not null,
    provider_event_id text not null,

    -- The provider's own event name, verbatim ('payment.captured'). Not normalised into our
    -- vocabulary here: the raw label is what a support ticket will quote.
    event_type        text not null,

    -- Null when the delivery does not correspond to an order we know — an event for a
    -- different integration, or one that arrived before its order was committed. The row is
    -- still recorded, because "we received something we could not place" is exactly the fact
    -- an operator needs and exactly the fact that is otherwise lost.
    order_id          uuid references event_orders(id) on delete set null,

    -- The verified payload, kept for reconciliation. Stored only AFTER signature verification,
    -- so this is not an unauthenticated blob store: an unverified body is rejected before any
    -- row is written.
    payload           jsonb,

    received_at       timestamptz not null default now(),
    -- Set when the handler finished acting on it. A row with a null here is a delivery that was
    -- accepted and then died mid-processing, which is the only shape worth alerting on.
    processed_at      timestamptz,

    constraint payment_webhook_provider_len
        check (char_length(provider) between 1 and 40),
    constraint payment_webhook_event_id_len
        check (char_length(provider_event_id) between 1 and 200)
);

create unique index if not exists idx_payment_webhook_delivery
    on payment_webhook_events (provider, provider_event_id);

create index if not exists idx_payment_webhook_order
    on payment_webhook_events (order_id, received_at desc);

-- ─────────────────────────────────────────────────────────────────────────────────
-- WHAT THE ROUTES MUST DO THAT THIS SCHEMA CANNOT ENFORCE
--
-- Written here, not only in the route, because a route gets rewritten and a migration header is
-- read by whoever rewrites it:
--
--   * CAPACITY IS ENFORCED UNDER A ROW LOCK. `select ... from community_events where id = $1
--     for update`, then count tickets, then insert. Counting without the lock lets two buyers
--     both see the last seat. No constraint can express this.
--   * ORGANISER CHECK. Creating, publishing, cancelling an event and scanning at the door is
--     owner/admin only, read from community_members.role. There is no column here that encodes
--     it, deliberately: 030 makes the roster the single authority.
--   * ORDERS ARE NOT CREATED BY THE CLIENT SAYING WHAT THEY COST. The price comes from the
--     event row inside the same transaction. A client-supplied amount is the oldest bug in
--     e-commerce.
--   * THE WEBHOOK VERIFIES A SIGNATURE OVER THE RAW BODY. Re-serialised JSON is a different
--     byte string and will not verify; an endpoint that "verifies" a re-encoded body is
--     verifying nothing.
--   * FREE RSVP SHIPS FIRST. price_minor = 0 exercises this whole path with no provider
--     attached, which is how the calendar and door flows get de-risked before money exists.
-- ─────────────────────────────────────────────────────────────────────────────────
