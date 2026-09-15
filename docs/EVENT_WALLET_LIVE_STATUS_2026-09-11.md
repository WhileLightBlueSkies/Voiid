# Wallet and event Live Activities — 11 September 2026

## Implemented and verified

- iOS real Add to Apple Wallet flow already existed. The pass-generation endpoint checks ownership and current ticket/order/event availability. Added the correct group admission quantity to the saved pass. The pass links to the authenticated rotating QR, with no permanent admission barcode or attendee identity.
- Local certificate/key signing succeeded; OpenSSL verified the detached signature. This is not a real Wallet save or independent trust-chain verification. Pass certificate expires 10 October 2027 13:18:27 UTC.
- Added WidgetKit target VoiidEventActivity (in.voiid.app.EventActivity), shared ActivityKit attributes and main-app support flag. Confirmed ticket → Follow event starts a private countdown on Lock Screen/Dynamic Island, with a link to the authenticated ticket. Available eight hours before start until one hour after start. No automatic push-to-start or scheduled reminder flow is claimed.
- Stop following and local sign-out end activities. The controller registers current and rotated tokens; token-registration failure ends the activity with a visible error. Disabled Live Activities show a Settings explanation. The widget marks stale updates and clamps the countdown at zero.
- Device-scoped authenticated registration, active-ticket validation, registration rate limiting, bounded subscriptions, server polling and APNs ActivityKit update/end delivery added. Server checks every 30 seconds in bounded batches; larger backlogs may delay processing. Unchanged content is refreshed every three minutes; stale content is marked after five minutes. Cancellation, check-in, refunds, revocation, suspension and expiry end the activity. Device deletion cascades subscriptions; rows are expired and cleaned up. APNs environment fallback handles development versus distribution tokens. Remote delivery is best effort, not a guarantee.
- Migration 072 deployed through the checksummed migration runner. It was first tested in a rollback-only schema for table creation, lease claims and device cascade. Backend backup: /opt/voiid-backups/event-activity-20260911. Feature flag VOIID_EVENT_LIVE_ACTIVITIES enabled.
- Nineteen targeted tests passed: Wallet, push payload routing/privacy and activity lifecycle. Backend TypeScript build and iOS build passed. Startup Firebase bundle verification passed. Final countdown-clamping build installed on Nehal’s iPhone 15.

## Ticket links

The public website’s https://voiid.app/.well-known/apple-app-site-association returns 404 and runs separately from the API. Added the association endpoint on the controlled API domain and added applinks:api-dev.voiid.app to iOS. Wallet link origin is configured as https://api-dev.voiid.app; the ticket router accepts only these explicitly declared hosts and valid UUID paths. The public fallback displays generic instructions and no ticket data. The deployed association endpoint returns the correct app ID/path; unauthenticated activity registration returns 401; backend health reports API/DB/Redis healthy. Apple’s association caching and actual on-device pass links still need verification.

## Remaining blockers and device checks

- User explicitly approved the signing-file transfer. Apple Wallet is now enabled on the backend: files uploaded to /opt/voiid-secrets/wallet (directory 0700, files 0600), all three signing paths configured in the server environment (0600), and API restarted. Private keys were not printed or placed in Git. Backup: /opt/voiid-backups/wallet-enable-20260911. Certificate/key match and issuer signature verified on-server; macOS trust-chain verification succeeded. A server-generated sample pass passed detached-signature and manifest-hash verification, group quantity and secure-link checks. The sample is not a real admission ticket. Wallet issuance without login returns 401. An actual user-confirmed Wallet save and app-link opening remain to be tested on the phone.
- Google Wallet issuer credentials and publishing setup remain incomplete; the issuer ID alone cannot issue passes.
- User has been asked to test Follow event on an eligible confirmed ticket and lock Nehal’s iPhone. Actual APNs delivery, countdown UI, cancellation/check-in ending, permission denial, token rotation and signed-out cleanup need real device validation. Community request/approval FCM/APNs notifications remain implemented but their two-account foreground/background test is also outstanding.
- Scheduled event reminders and automatic activity start are not implemented in this change. No Android equivalent of Dynamic Island is claimed; Android retains the community notification implementation.

References: https://developer.apple.com/documentation/ActivityKit/displaying-live-data-with-live-activities and https://developer.apple.com/help/account/certificates/wwdr-intermediate-certificates .

## Final deployment verification

API health reports database/Redis healthy. Wallet signing configured, ActivityKit push configured and activity worker flag enabled. Activity subscription count was zero at verification, so no real-device APNs delivery is claimed. Certificate expires 10 October 2027; rotate the certificate before expiry while retaining the same pass type identifier.
