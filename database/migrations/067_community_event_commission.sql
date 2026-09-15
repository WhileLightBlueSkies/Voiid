-- Rates are basis points: 2500 = 25%. Existing orders remain unpriced historically.
alter table communities add column event_commission_bps integer not null default 2500
  check (event_commission_bps between 0 and 10000);
alter table event_orders add column commission_bps integer check (commission_bps between 0 and 10000);
alter table event_orders add column commission_minor bigint;
alter table event_orders add column organiser_minor bigint;
alter table event_orders add constraint event_order_commission_balanced check (
  (commission_bps is null and commission_minor is null and organiser_minor is null) or
  (commission_bps is not null and commission_minor is not null and organiser_minor is not null
   and commission_minor >= 0 and organiser_minor >= 0
   and commission_minor + organiser_minor = amount_minor));

create function snapshot_event_commission() returns trigger language plpgsql as $$
declare rate integer;
begin
  if TG_OP = 'UPDATE' then
    if (new.commission_bps, new.commission_minor, new.organiser_minor, new.amount_minor)
       is distinct from (old.commission_bps, old.commission_minor, old.organiser_minor, old.amount_minor) then
      raise exception 'order financial snapshot is immutable';
    end if;
    return new;
  end if;
  select c.event_commission_bps into strict rate from communities c
    join community_events e on e.community_id = c.id where e.id = new.event_id;
  new.commission_bps := rate;
  new.commission_minor := floor(new.amount_minor::numeric * rate / 10000)::bigint;
  new.organiser_minor := new.amount_minor - new.commission_minor;
  return new;
end $$;
create trigger event_order_commission_snapshot before insert or update on event_orders
  for each row execute function snapshot_event_commission();
