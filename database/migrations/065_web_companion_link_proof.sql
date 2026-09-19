-- QR approval is public to anyone who sees the screen. Redemption additionally
-- requires a separate secret retained by the requesting browser, never in the QR.
alter table device_link_requests add column if not exists poll_secret_hash bytea;
alter table device_link_requests add constraint device_link_poll_hash_length
    check (poll_secret_hash is null or octet_length(poll_secret_hash) = 32);
-- Existing, short-lived requests without a hash fail closed and must be recreated.
