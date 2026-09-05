-- =================================================================================
-- 058 — the payment delivery ledger becomes an inbox
--
-- 032 gave payment_webhook_events one bit of state: `processed_at`, null or not. That was
-- enough to deduplicate and not enough to RECOVER, and the difference is money.
--
-- ── THE FAILURE THIS FIXES ───────────────────────────────────────────────────────
--
-- The route claimed a delivery by inserting the row, and only then settled the order and
-- minted tickets. If anything between those two points failed — a dropped connection, a
-- deploy, a constraint violation — the claim was already committed. The provider retried, as
-- every provider does, and the retry hit the unique index on (provider, provider_event_id),
-- was read as a duplicate, and answered 200. The buyer's money had moved, no ticket existed,
-- and the ledger said the delivery had been handled. Nothing would ever try again.
--
-- The row was left with a null processed_at as "the alerting signal", which is a way of
-- saying a person had to notice and fix it by hand.
--
-- ── STATUS, NOT A TIMESTAMP ──────────────────────────────────────────────────────
--
--   received   -> written but not yet claimed (no writer produces this today; it is the
--                 honest default for a row that exists before anything has acted on it)
--   processing -> a handler holds it, until `lease_until`
--   processed  -> its effect is committed, in the SAME transaction that made the effect
--   failed     -> it was attempted and did not finish. RETRYABLE: the next delivery or sweep
--                 re-claims it. This is the state that turns a lost payment into a retried one.
--   unmatched  -> verified, but names an order reference we have never seen. Held, NOT marked
--                 done, so it can be reconciled when the order appears.
--
-- `lease_until` is what makes a claim safe without a lock held across a network call: a
-- handler that dies takes its lease with it, and the row becomes claimable again when the
-- lease expires rather than being stuck in 'processing' forever.
--
-- ── WHY THE VERDICT IS STORED COLUMN BY COLUMN ───────────────────────────────────
--
-- An unmatched delivery has to be replayable LATER, against an order that did not exist when
-- it arrived. Replaying it means knowing what it said — paid or refunded, how much, in what
-- currency — and the raw `payload` cannot answer that without re-running provider-specific
-- parsing outside the provider. These four columns are the provider's already-normalised
-- verdict, which is exactly what the handler acts on. They are also the columns an operator
-- reconciling a bank statement will actually query.
--
-- ── BACKFILL ─────────────────────────────────────────────────────────────────────
--
-- Existing rows: a processed_at means it finished, so 'processed'. A null one is the failure
-- described above — a delivery that was claimed and abandoned — so 'failed', which makes it
-- retryable rather than leaving it silently done. That is the correct direction to be wrong
-- in: re-applying is idempotent (settlement is guarded by `status = 'pending'`), while
-- wrongly marking one processed loses a payment permanently.
--
-- The column is added nullable and filled before being made NOT NULL, so re-running this
-- file cannot re-map rows that are legitimately 'received'.
-- =================================================================================

alter table payment_webhook_events
    add column if not exists status         text,
    add column if not exists attempts       int not null default 0,
    add column if not exists lease_until    timestamptz,
    add column if not exists last_error     text,
    -- The order reference this delivery names, kept even when no order matches it — without
    -- it an unmatched delivery cannot be found again once the order finally arrives.
    add column if not exists provider_ref   text,
    add column if not exists outcome        text,
    add column if not exists outcome_reason text,
    add column if not exists amount_minor   bigint,
    add column if not exists currency       text;

update payment_webhook_events
   set status = case when processed_at is not null then 'processed' else 'failed' end
 where status is null;

alter table payment_webhook_events alter column status set default 'received';
alter table payment_webhook_events alter column status set not null;

-- Existing rows can recover their reference from the order they were matched to. Rows that
-- never matched one have no reference to recover and stay null; they were already marked
-- processed by the old code, so nothing is waiting on them.
update payment_webhook_events e
   set provider_ref = o.provider_ref
  from event_orders o
 where o.id = e.order_id
   and e.provider_ref is null;

do $$ begin
    alter table payment_webhook_events
        add constraint payment_webhook_status_check
        check (status in ('received', 'processing', 'processed', 'failed', 'unmatched'));
exception when duplicate_object then null;
end $$;

do $$ begin
    alter table payment_webhook_events
        add constraint payment_webhook_outcome_check
        check (outcome is null or outcome in ('paid', 'failed', 'refunded'));
exception when duplicate_object then null;
end $$;

-- Reconciliation: "did anything arrive for this reference before its order existed?", asked
-- once per paid order creation. Partial, because the answer is almost always no rows.
create index if not exists idx_payment_webhook_unmatched
    on payment_webhook_events (provider, provider_ref)
 where status = 'unmatched';

-- The recovery sweep: claimed-and-abandoned deliveries, and expired leases.
create index if not exists idx_payment_webhook_retryable
    on payment_webhook_events (status, lease_until)
 where status in ('processing', 'failed');

-- ─────────────────────────────────────────────────────────────────────────────────
-- THE REFUND ORDERING POLICY, MADE EXPLICIT: A REFUND IS TERMINAL WHENEVER IT LANDS.
--
-- 032's state machine allowed only 'paid' -> 'refunded', and its own comment names the reason
-- the gap matters: providers deliver out of order, and "a captured arriving after a refunded
-- is not hypothetical; it is Tuesday". It handled that direction and not the other one. A
-- refund arriving BEFORE its payment matched no rows, was marked processed, and was lost —
-- and the payment then landed, minted tickets, and left the buyer holding a live ticket for
-- money that had already been returned. That is strictly worse than the case the trigger was
-- written to prevent.
--
-- 'pending' -> 'refunded' is therefore legal. This does not weaken the invariant the trigger
-- exists for, which is that an order cannot walk BACKWARDS: 'refunded' stays terminal, and a
-- late 'paid' delivery still cannot move an order out of it. It adds one forward edge to a
-- terminal state.
--
-- A refund implies a payment happened at the provider — that is what there is to refund — so
-- an order refunded from 'pending' means our payment event was lost or delayed, not that no
-- money moved. `settled_at` is stamped by the handler for exactly that reason, which also
-- satisfies 032's settled-coherence constraint.
--
-- 'failed' and 'cancelled' remain untouchable: no money was taken, so there is nothing to
-- return, and rewriting a terminal state on a stray event would destroy the audit trail.
-- ─────────────────────────────────────────────────────────────────────────────────
create or replace function event_order_transition() returns trigger as $$
begin
    if new.status = old.status then
        return new;
    end if;

    if not (
        (old.status = 'pending' and new.status in ('paid', 'failed', 'cancelled', 'refunded'))
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
