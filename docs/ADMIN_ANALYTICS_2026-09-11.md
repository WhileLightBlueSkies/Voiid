# Admin analytics release — 11 September 2026

Available locally at http://localhost:3100/analytics; platform admin role required.
Backend deployed; migration 071 applied at 2026-09-11 07:57:10 UTC.

## Included

- DAU: unique account IDs with authenticated device API usage today, UTC.
- WAU/MAU: distinct accounts over 7/30 calendar days including today.
- DAU/MAU ratio, provisional until 30 days have accumulated.
- 7/30/90-day daily activity and account creation charts and daily table.
- iOS, Android, web and unknown registered device and user counts, DAU and MAU.
- Existing product totals: accounts, communities, conversations, calls, events, orders, tickets and clips.
- Admin-only server permission and no-store response; moderators have no Analytics navigation.

Overall active users are deduplicated across platforms. Platform rows overlap for multi-platform accounts. Registered devices are non-revoked devices of non-deleted users, not downloads or installations inferred from push tokens. Account creation history excludes deleted accounts.

Activity means authenticated API usage, including background traffic. It does not mean foreground app sessions. WebSocket-only and offline activity are not included. Collection does not read message content or store IP addresses, tokens or phone numbers. Daily records contain account ID, UTC date and platform; daily cleanup on usage removes records older than the 90-day window. Hard account deletion cascades to activity; soft-deleted accounts are excluded from queries.

Recording is best-effort, asynchronous, deduplicated per device/day in each process and by database primary key. It does not delay or fail user requests when analytics writes fail. History before collection is unavailable, not backfilled from last-seen or registration dates.

## Validation

- API TypeScript build and admin TypeScript check passed.
- Unit tests passed: repeated/concurrent usage deduplication and failure isolation/retry.
- Real PostgreSQL tests used temporary tables in a rolled-back transaction: cross-platform deduplication, UTC windows, deleted-account exclusion and pre-collection nulls passed.
- Browser test using synthetic responses passed rendering, date-range selection and no runtime errors; desktop screenshot inspected. This is UI validation, not an authenticated production browser session.
- Live database aggregate query passed; unauthorized endpoint returned 401; API health checked after restart.
- Deployment backups: /opt/voiid-backups/analytics-20260911 and analytics-20260911-retry.
- Deployment initially rejected a SQL alias and then a macOS ._ migration sidecar. Both corrected; the real migration subsequently applied through the checksummed runner.

## Not yet instrumented

Foreground session duration, app/OS versions, crash-free users, retention cohorts, notification conversion, event discovery views and provider settlement analytics. These must not be inferred from daily API counts. Mobile builds are not required for the current API-based measurement.
