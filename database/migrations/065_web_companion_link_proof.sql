-- QR approval is public to anyone who sees the screen. Redemption additionally
-- requires a separate secret retained by the requesting browser, never in the QR.
alter table device_link_requests add column if not exists poll_secret_hash bytea;
-- Guarded: `add constraint` has no IF NOT EXISTS, so a second replay of the migration set
-- aborts here. The migration-replay CI job runs the whole set against a live database, which
-- is where that surfaces.
do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'device_link_poll_hash_length') then
        alter table device_link_requests add constraint device_link_poll_hash_length
            check (poll_secret_hash is null or octet_length(poll_secret_hash) = 32);
    end if;
end $$;
-- Existing, short-lived requests without a hash fail closed and must be recreated.
