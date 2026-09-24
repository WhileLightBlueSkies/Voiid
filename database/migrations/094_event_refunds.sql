-- Refunds for paid event orders.
--
-- An order stays 'paid' until the provider CONFIRMS the refund by signed webhook, which moves it
-- to 'refunded' and voids its tickets (payments/inbox.ts refundOrder). These columns record the
-- request in between, so the host, the buyer and admin can all see "refund on the way", and a
-- failed request shows why instead of vanishing.
--
-- split_vendor_id: the host payout account the order's share settled to (Easy Split). A refund
-- must take that share back from the same account; reading the host's CURRENT vendor at refund
-- time would be wrong if they re-verified in between. Null on orders from before this column,
-- and on orders with no split — the refund then comes entirely from Voiid's settlement.
alter table event_orders add column if not exists split_vendor_id     text;
alter table event_orders add column if not exists refund_requested_at timestamptz;
alter table event_orders add column if not exists refund_requested_by uuid references users(id) on delete set null;
alter table event_orders add column if not exists refund_error        text;

-- Why the refund was made — shown to the buyer and in admin. And which attempt this is: a
-- refund the provider cancels is retried under a NEW refund id (`rf_<order>_<attempt>`), since
-- the provider will never accept the same id twice.
alter table event_orders add column if not exists refund_reason   text;
alter table event_orders add column if not exists refund_attempts int not null default 0;
