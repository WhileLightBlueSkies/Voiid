-- Preserve partially admitted historical bookings; unentered bookings become whole-group entry.
alter table event_orders add column admission_mode text not null default 'individual'
 check (admission_mode in ('individual','group'));
alter table event_orders alter column admission_mode set default 'group';
update event_orders o set admission_mode='group'
 where not exists(select 1 from event_tickets t where t.order_id=o.id and t.checked_in_at is not null);
