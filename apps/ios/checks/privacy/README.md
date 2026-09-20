# Profile & presence wiring checks

The harness compiles the real PrivacySettings model and ProfileService. It substitutes
only account identity, HTTP transport, and the availability enum. No app is built or
launched, and no live account or server is modified.

From repository root:

```sh
xcrun -sdk macosx swiftc -module-cache-path /tmp/voiid-privacy-check-cache \
  apps/ios/Voiid/Voiid/Models/PrivacySettings.swift \
  apps/ios/Voiid/Voiid/Networking/ProfileService.swift \
  apps/ios/checks/privacy/PrivacySettingsCheck.swift \
  -o /tmp/voiid-privacy-check
/tmp/voiid-privacy-check
node --import tsx --test backend/api/test/privacy.test.ts backend/api/test/blocking.test.ts
./node_modules/.bin/tsc -p backend/api/tsconfig.json --noEmit
```

Verified: 24 Swift checks, 20 backend unit checks, API type checking, and Swift UI
source parsing. Full app build and device/server integration have not been run.

Deployment order: deploy the API owner-profile response addition before distributing
the iOS change. The existing `users` privacy columns need no migration. If an older
API omits those fields, the client shows a load error and disables audience edits
instead of assuming Everyone or overwriting account settings.

Device acceptance after deployment:

- Profile & presence loads saved values; reopening/foregrounding refreshes them.
- Changing one audience does not rewrite the other two.
- Offline load/save shows an error. Refresh reconciles a possibly committed save.
- Switching accounts never displays or applies the previous account's settings.
- Nobody hides online, last seen, and availability status from the other account.
- Contacts uses the profile owner's saved contacts; blocking overrides visibility.
- Hidden/unknown presence has no fabricated "last seen recently" label.
- My status → None removes an existing status.
- Show contacts’ activity only changes the local chat display.

## Message privacy regression checks

The Swift harness now also checks persistent, account-scoped private-read boundaries,
queued-receipt suppression when disabling receipts, legacy local-read migration when
re-enabling, and throttled typing with idle/clear/privacy/lifecycle stops (42 checks total).

The real PostgreSQL receipt suite adds off → on → retry coverage: unread counts clear
while private, only newer messages disclose reads, and stale/repeated requests do not
expose private history. Run with a disposable local database:

```sh
RECEIPT_TEST_DATABASE_URL=postgres://localhost:55439/voiid_test_receipts \
node --import tsx --test backend/api/test/receiptPostgres.test.ts \
  backend/api/test/receiptStatus.test.ts backend/api/test/receiptDevice.test.ts \
  backend/api/test/receiptAuthorization.test.ts backend/websocket/test/recipients.test.ts
```

Verified 54 backend checks passed in the combined run. The initially skipped recipient
database suite was then run with `RELAY_TEST_DATABASE_URL` against the same disposable
local database: all 8 additional checks passed (62 backend checks total).
API type checking and Swift source parsing also passed. No app build or launch.

Deploy the API `read_after` support **before** distributing this iOS update. Older
servers ignore that lower bound and cannot provide the private-history guarantee.
No database migration is required. An already transmitted read receipt cannot be
recalled by subsequently turning the toggle off.

Two-device acceptance still required after deployment:
- Read while off, leave/restart, enable, then read a new message: old messages remain private.
- Repeat offline, reconnect, and switch accounts; unread badges still clear correctly.
- Type continuously, pause three seconds, clear/send, disable typing, background, leave chat.
- Two group members type together; one stopping must not hide the other member.
- Background sync must not advance the read position for newly arriving messages.
