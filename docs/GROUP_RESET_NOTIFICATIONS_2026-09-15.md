# Group reset and notification work — 2026-09-15

## Production reset completed

The user approved deleting only the four standalone groups. A transaction verified the exact standalone group IDs and absence of community channel associations before deleting them. Four groups and their 14 messages were removed; four communities, ten community channels, and six direct conversations were preserved. There were no associated calls, games, or media references in the reset set.

## Notification changes prepared locally

- Per-member community preferences: All, Important, None; default Important. Authenticated GET/PATCH endpoints require active membership, with controls in both mobile apps.
- Public posts, announcements, and published event updates send generic community alerts without content in push payloads. Important includes public post mentions, announcements, and event updates. None suppresses these alerts. Blocked users and the actor are excluded.
- Community channel message pushes respect membership preferences; Important currently permits announcement channels. Message storage and outbox delivery remain unchanged.
- Android handles FCM missed-call alerts with call-ID deduplication and conversation navigation. The API sweeper leases pending direct missed calls, retries transient FCM failures, and suppresses historical calls through migration backfill. Enable with `VOIID_MISSED_CALL_PUSH=1` after migration 074.

## Remaining work and limits

- Important mentions/replies inside encrypted channels are not implemented. Public community posts currently have no reply creation/thread flow; the policy defines reply alerts but no producer emits them yet. These must not be described as complete.
- The new missed-call backstop covers direct calls, not conference/group calls. iOS retains its existing local missed-call path.
- Community pushes are best effort. The missed-call path has persisted leases and retries; public community alerts do not yet have a durable notification outbox.
- Group reset does not establish that every new-group flow works. Group creation, invitations, offline membership sync, message alerts, and notification taps still need two-account device validation.
- Production staging was rejected by automatic approval review, which requires explicit authorization to transfer the notification files and deploy. A deployment approval question is pending. No notification migration, source deployment, or API restart has been performed for these changes.

## Validation

API TypeScript build passed. The focused notification, payload, conference, and group membership regression run passed 67 tests with no failures or cancellations. The isolated iOS notification routing harness passed 14 checks, including community update navigation. Android `:app:compileDebugKotlin` and the iOS Debug device build passed. Live APNs/FCM delivery has not been tested for these changes; the new app build has not been installed on a device.
