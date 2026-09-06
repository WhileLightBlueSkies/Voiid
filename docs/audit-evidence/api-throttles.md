# P01/P02 — API throttles

6 September 2026. P01 implemented and locally verified. P02 implemented and locally verified; deployment and sustained load measurements remain open.

- Reproduced: the 31st unrelated community read returned 429 from the host-thread mount.
- Narrowed route limits to matching routes after authentication. Existing route-specific limits retained; global anonymous IP guard retained.
- Atomic Redis fixed window sets count and TTL together, repairs old keys missing TTL, and returns Retry-After.
- Rejections increment process counters without database writes. General Redis outages fail open; auth/recovery/key-fetch limits fail closed. Redis command and connection deadlines are 1.5 seconds, with offline queues disabled.
- Tests: real application mount order checks 31 reads, 20 host-thread creation attempts, independent accounts behind one IP, and anonymous flood protection. Real Redis test checks 60 calls across two connections, TTL repair and expiry rollover. Rejection test checks Retry-After, zero SQL writes and key-fetch outage behavior.
- API suite: 233 passed, 7 database suites skipped in the non-database run. Database suites will be run separately during integration.
- Operational limitation: counters are in-process and not yet scraped; P04 telemetry work remains open. Fixed windows allow boundary bursts by design.
