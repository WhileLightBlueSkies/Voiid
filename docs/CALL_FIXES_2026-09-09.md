# Calling fixes — 9 September 2026

Follow-up: [conference lifecycle defects and additional fixes](CONFERENCE_LIFECYCLE_FIXES_2026-09-09.md), investigated after the reported join/leave/end problems. The verification below describes the earlier pass.

Scope: the existing 1:1 voice/video engine, group rooms, and ad-hoc conferences created by adding someone to a live call. Conferences remain call-scoped, encrypted rooms with a maximum of eight participants; they do not grant messaging rights or create conversations.

## Implemented

- **Call lifecycle:** scope delayed setup, SDP handling, ICE events and native end actions to their call/connection. Ignore completed-call replays and duplicate teardown. Bound initial connection attempts and ICE recovery. Preserve terminal notification frames when removing obsolete queued setup frames.
- **Native controls and outcomes:** Android notification/PiP actions carry their call ID. iOS native decline sends a decline. Surface no-answer/setup/network outcomes, distinguish another device answering from a missed call, and submit iOS terminal metrics once.
- **Multiple devices:** Redis atomically selects the 1:1 answering device. A losing device cannot relay a hangup or decline into the winning call. Clients recognize the server's device identity even when both users already tapped Answer. Sibling cleanup does not end the server's shared call record. Conference membership is excluded from this 1:1 arbitration.
- **Conference signaling and encryption:** enable the missing `call_key` relay path; normalize the shipped iOS and Android key formats while emitting copies compatible with both existing decoders; stamp the authenticated sender device. Initialize Android's conference signal subscription with calling. Accept iOS key envelopes on Android and apply subsequent conference key rotations on iOS. Carry key generations forward when upgrading or retrying an upgrade.
- **Conference join:** handle acceptance directly from a push, wait for the encrypted call key, send acceptance after server membership is joined, and reject completions from abandoned joins. Token/room/media setup has bounded connection windows. Repeated add-person actions do not reconnect an established conference.
- **Conference handover:** distinguish `conference-migrated` from a real hangup. Keep 1:1 media until both originals are present in the conference. Defer iOS capture until handover and wait for Android's media executor to release the old microphone. Preserve mute/camera choices. Fall back to the existing 1:1 call if the upgrade fails.
- **Conference leave:** detach old rooms before asynchronous disconnect, scope delegate events, stop conference bookkeeping when its room ends, and use participant `/leave` semantics instead of globally ending a conference when one person leaves.
- **Server history:** terminal call statuses and their first terminal reason cannot be overwritten by a late connected/end request.

## Verification

- Calling and WebSocket suites: **93 passed, 2 optional tests skipped**, including real Redis answer arbitration, real PostgreSQL status reordering and real concurrent conference-cap tests. The two skipped suites are optional PostgreSQL WebSocket session/recipient integration suites, separate from the calling regressions.
- Standalone production CallKit handler: **5 regression scenarios passed** (stale UUID, correct UUID, duplicate terminal action, waiting-call decline, incoming decline).
- Production Android state updater with real `MutableStateFlow`: **3 regression scenarios passed** (concurrent hangup, replacement call, concurrent controls).
- API and WebSocket TypeScript type checks passed.
- Final Android `:app:assembleDebug`: **passed**. APK: `apps/android/app/build/outputs/apk/debug/app-debug.apk`.
- Final iOS Debug device-target build: **passed** (`generic/platform=iOS`, code signing disabled). This verifies compilation; the build was not installed on the connected phone.

Reproduce the native handler check on macOS:

```sh
python3 tools/check-call-lifecycle.py
python3 tools/check-android-call-state.py
```

Integration tests require **isolated local test services**, never the production database:

```sh
CALL_TEST_REDIS_URL=redis://127.0.0.1:56379 \
CALL_TEST_DATABASE_URL=postgresql://call_test@127.0.0.1:55439/voiid_test_call_lifecycle \
node --import tsx --test \
  backend/websocket/test/callSignaling.test.ts \
  backend/api/test/callLifecyclePostgres.test.ts
```

## Required device acceptance

Builds and automated tests do not prove microphone routing, PushKit/FCM delivery or three-device audio under real network changes. The user confirmed two test devices are ready; the connected iPhone 15 and Android CPH2745 are visible. A third test account/device is not ready, so three-person conference audio remains unverified. No real peer call has been placed in this fix session. Use [the QA matrix](CALL_QA_TEST_MATRIX.md), especially:

1. iOS → Android and Android → iOS: answer, decline, cancel while ringing, no answer and hang up during Connecting.
2. Rapid call/end/call; stale notification/CallKit actions; two devices answering the same account simultaneously.
3. Both directions: start a voice call, add a third device, verify audio in every direction, add another person, then leave from each role while the others continue talking.
4. Conference invite via foreground socket and background/locked-screen push; decline; cancel while fetching the token/key or joining the room.
5. Preserve mute/camera state during migration; speaker, earpiece, Bluetooth and wired routing after handover and after leaving.
6. Wi-Fi/mobile handover, packet loss, complete network loss and recovery during both 1:1 and conference calls.
7. Retry a failed upgrade, invite a late joiner, remove/leave a participant and verify media continues after key rotation.

Deploy the relay/API changes together with the updated clients before evaluating these cross-platform paths. This session does not deploy backend services or establish production TURN/LiveKit health.
