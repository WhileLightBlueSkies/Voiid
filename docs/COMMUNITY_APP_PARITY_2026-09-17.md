# Community Home and Spaces: app parity handoff

## Task resumed

Continued the local Claude conversation titled **Voiid UI iPhone** (session `3ecca5f5-c0f0-4ef4-b348-f2ae735c20cc`). Its latest instruction was to finish Community app parity on iOS and Android before returning to infrastructure/admin work.

Claude's uncommitted server changes were retained and completed. The remaining identity-less channel-list call was real: it returned `can_post: false` to everyone. Existing-owner joins also needed to retain manager capability.

## Implemented

- **Home and each Space have four posting options:** Everyone, Managers only, Selected members, Nobody. Nobody includes the owner/admins; Selected includes managers plus explicitly chosen active members.
- Both apps consume the server's `can_post` response. Missing capability data does not grant posting. Feed refresh reads the current capability again; write authorization remains server-enforced.
- Manager-only selected-member pickers support search over loaded members, loading more roster pages, persisted add/remove operations and visible failures. The private allowlist is paginated instead of silently truncating after 200 entries. Selection changes save immediately; policy changes use Save.
- Space settings expose posting policy, description and pinning on both platforms. Invalid policies are rejected before other supplied fields mutate.
- **Spaces open as topic post feeds**, reusing Home's feed, composer, likes, media and moderation controls. Home and each Space have separate database filters and permissions. Space feeds require active community membership.
- Existing encrypted conversations and their history remain available through **Open existing encrypted chat**. Feed copy describes the new posts as server-readable; it does not claim the feed is encrypted.
- Added manual refresh and pagination. New cursors preserve PostgreSQL microseconds and break timestamp ties by post ID. Legacy timestamp cursors are still accepted.
- **View counts store only an aggregate integer**, with no viewer table or viewer list. Clients submit an impression when a post is visible, at most once per feed-view lifetime; reopening can add another view. This is an impression count, not a count of unique people. Atomic increments avoid losing concurrent views. Unpublished, removed and unreadable posts cannot be counted.
- Existing like/unlike requests remain idempotent; failures restore the old UI state and show an error. Home and Space counters use the same server responses.
- Android now displays actual post images, supports photo attachments with bounded, orientation-aware decoding, and invokes the existing report flow and native share sheet. Both apps' inert Save-post placeholder was removed; Share is wired on iOS too. The inert comments count was replaced with the requested views indicator; this change does not add comment threads.
- Newly created announcement Spaces default to manager posting. Suspended communities do not return usable posting capabilities or Space feeds.

## Validation

- Root `npm test`: all five package test suites passed, plus the Ludo asset check. Integration suites requiring unrelated services remain skipped.
- Full API run: **319 passed, 0 failed, 17 skipped**. Community integration suites used an isolated PostgreSQL database with all repository migrations applied.
- Final targeted policy suite: **12 passed, 0 failed**, including an additional suspension regression after the full run.
- Database coverage includes Home/Space permission separation, owner and selected-member behavior, invalid-setting rejection, private allowlist access, same-timestamp pagination, outsider exclusion, repeated like/unlike, concurrent view increments, scheduled/removed posts and suspension.
- Android: **156 unit tests, 0 failures/errors**, including three new wire-contract cases; Debug compilation passed.
- Swift production-model decoding fixture passed: server capabilities, safe defaults, Space metadata, counters and official author identity.
- Final iOS simulator Debug build and Android Kotlin compilation passed, including the privacy-copy corrections.
- CI's five backend/shared TypeScript checks passed (`api`, `websocket`, `games`, `workers`, `common-utils`).
- `git diff --check` passed.

## Before release

Migrations **078** and **079**, already present in the repository, must be applied before this API version. Release the API before the mobile apps. No migration creates or converts encrypted message content into feed posts.

The signed iOS build and Android debug APK were installed and launched on physical phones. Android wireless ADB remained connected after USB removal. Full physical-device interaction tests are still needed: owner/admin/selected/ordinary member, each policy on Home and two Spaces, photo upload failure/retry, long rosters/feeds, likes from two devices, visible view counting, and access to old encrypted chats.

The deferred Cloudflare/admin sign-in work and the earlier conference SDK key-rotation work were not part of this continuation. Moderator author identity already on the API is preserved; a new admin-panel Space publishing workflow is not introduced here.

## Backend deployment — 2026-09-17

- Verified server `/opt/voiid` was already on `5c2086bd`; migration ledger confirms 078 and 079 applied, neither in progress. No schema mutation was needed.
- Deployed the tested `backend/api/src/routes/communities.ts`, rebuilt the API successfully, and restarted only `voiid-api`. Local health confirms database and Redis up.
- Deployed source SHA-256: `4c5d721c6cab430acc0a1f4545ee5eaae377534b166c69000ed60783ad6dd24a`.
- Rollback source and compiled API backup: `/opt/voiid-community-backup-20260917-IqJw9G`.
- This is an uncommitted source deployment on top of `5c2086bd`; `/health` still reports that base commit. Commit and include these changes in the next regular release, which would otherwise overwrite this patch.

## Space publishing and community messages follow-up

- Space feeds now show the Space name, purpose, and a clear posts heading. The written Refresh button was removed; feeds refresh with the platform pull gesture.
- The post composer loads authoritative Home/Space capabilities and supports selecting Home plus multiple Spaces. The API validates every destination first and inserts every copy in one SQL statement, so a denied destination cannot leave a partial post behind.
- Per-Space posting permissions remain controlled independently by the host/community admins through Space settings: Everyone, Managers, Selected members, or Nobody.
- “Message host” is now “Message.” A newly opened request always creates its own encrypted community moderator group, titled `<Community> · Moderator`, even if the member and owner already have a personal conversation. The owner and all currently active community admins are included. Moderator inbox/status access uses the same owner/admin role check.
- Existing legacy owner-only host threads remain readable. For new moderator groups, promoting or demoting an admin from the community’s own controls also updates that person’s encrypted group membership from the host device.
- Follow-up API deployed successfully on 2026-09-17. Source hashes: `communities.ts` `c53d83bd291388f5cc12e0d4787d89fa36cc428ef8c2094af2dfec1ecb2e1079`; `communityHostThreads.ts` `31eb95e443c353d75bff4e36085b5a8487ad70a067ec49f6419b00a64d354221`. Rollback backup: `/opt/voiid-community-followup-20260917-iWlt07`.
- Updated Android APK was installed and launched over wireless ADB. The signed iPhone build completed, but installation awaits the iPhone reconnecting to CoreDevice.
