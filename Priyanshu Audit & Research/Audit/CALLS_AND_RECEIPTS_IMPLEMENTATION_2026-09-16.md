# Calls and read receipts: validation and implementation follow-up

Date: 16 September 2026

Reviewed against the workspace source, local LiveKit SDK sources and regression tests. The original audits correctly identified the main failure mechanisms. Their historical baseline is preserved; use this document for implementation status.

## Status

Most actionable application and backend fixes are implemented. This is **not a claim that every audit finding is closed**. Seamless conference key rotation (CF-03) remains partly unresolved, and physical-device call/notification matrices remain unverified. Full cross-device answered-call history (MC-08) is outside the missed-call recovery implemented here.

Original audits:

- [Conference calls](CONFERENCE_CALL_AUDIT_2026-09-15.md)
- [iOS missed calls](IOS_MISSED_CALLS_NOT_APPEARING_IN_CALL_LOG_AUDIT_2026-09-15.md)
- [Read receipts and unread badges](CHAT_READ_RECEIPTS_AND_UNREAD_BADGE_AUDIT_2026-09-15.md)

“Implemented” below means source changes and the indicated automated checks exist. It does not mean a three-phone call or Apple Recents classification was observed.

## Conference findings

| Finding | Validation and resulting change | Status |
|---|---|---|
| CF-01 | LiveKit automatic audio-session configuration and deactivation were enabled. Both are now disabled before room creation; app-owned session changes preserve an active CallKit call. | Implemented; physical audio test pending |
| CF-02 | A shared call ID allowed room keys to change P2P encryption. Separate `p2p` and `room` envelopes, key stores and installation paths now preserve the original media key and verification tag. | Implemented; Swift isolation regression passes |
| CF-03 | Slot-zero replacement can interrupt media. Roster-based rotation, coordinator-only minting and matching provider settings reduce unnecessary changes. A coordinated indexed media-key transition is still missing. | **Partial; see design below** |
| CF-04 | Offline invitees could miss the room key. Relay now retains bounded, opaque, device-addressed frames for 60 seconds; clients also request a fresh encrypted copy while waiting. | Implemented; replay regressions pass |
| CF-05 | Account-wide leave allowed a sibling device to remove the answering device. Join/token/leave use active device identity; winner notification stops sibling ringing without leaving the winner's call. | Implemented; PostgreSQL arbitration regression passes |
| CF-06 | Failed handovers left server conference state and invitees behind. Abort/complete endpoints serialize rollback against handover completion; clients retry abort and preserve P2P only while it remains usable. | Implemented; PostgreSQL rollback regression passes |
| CF-07 | Migration signaling was lost across reconnects. Authorized, unexpired migration frames replay on reconnect; rollback to a direct-call grant disables replay. | Implemented; actual relay functions tested |
| CF-08 | An early migrated hangup could be forgotten. iOS remembers peer retirement and completes its transition when ready; failure after retirement ends cleanly. | Implemented; physical timing test pending |
| CF-09 | Lost connected-status HTTP requests let the sweeper classify a live call as missed. Both clients retry; relay answer evidence is checked by sweepers. A guarded database update also suppresses notifications for calls answered or declined after leasing. | Implemented; PostgreSQL and notification regressions pass |
| CF-10 | Pickers offered unreachable contacts. Both use the server's invitable-user filter, which applies call reachability and roster restrictions. | Implemented |
| CF-11 | iOS had no Add control after handover. Its conference screen now supports adding; joined invitees can add on both platforms. | Implemented |
| CF-12 | Voice handovers forced the speaker. iOS carries the current route into the conference and defaults voice to the earpiece. | Implemented; headset/Bluetooth tests pending |
| CF-13 | Invitations held seats indefinitely. Admission, roster, grants and join enforce 60-second expiry; a periodic sweep settles stale invitations. | Implemented; PostgreSQL expiry regression passes |
| CF-14 | Android's retired P2P engine kept recovery state alive. Retirement stops monitoring and clears reconnecting state. | Implemented |
| CF-15 | SDK provider defaults differed. Both room providers explicitly use matching shared-key, ratchet-window, failure-tolerance and ring-size settings. | Implemented; both apps compile |

### CF-03: remaining implementation design

The bundled Swift 2.15.2 and Android 2.27.0 SDKs keep media frame cryptors inside their E2EE managers. Their public application-facing API does not expose the required operation to switch all active outgoing media cryptors to a selected key index. Merely storing a key at another index does not switch those senders. Increasing key-ring size alone therefore does not close this finding.

A complete fix needs:

1. A pinned SDK change on **both platforms** exposing an explicit outgoing media key-index switch. Newly published audio/video tracks must inherit the active index, including tracks recreated after reconnect.
2. A scoped room-key prepare message carrying generation, slot and membership identity. Each current device installs the key for reception and acknowledges that exact generation over authenticated signaling.
3. Coordinator commit after the required current devices acknowledge. Commit switches outgoing cryptors to the new slot. Handle reordered prepare/commit, duplicate messages, coordinator departure and reconnect explicitly.
4. A bounded old-key receive grace period for in-flight frames, followed by removal. Never distribute the replacement key to a removed participant. Missing acknowledgements need a defined timeout and exclusion/failure policy; silently continuing indefinitely with the old key is unsuitable after removal.
5. Delayed/reordered-packet tests proving both decryptability during the transition and exclusion after membership removal, followed by mixed iOS/Android media tests. Include slot reuse and generation wrap handling.

The SDK modification and this prepare/acknowledge/commit protocol have **not** been implemented. Current code still replaces the active room key at slot zero for necessary membership rotations.

### Mixed-version behavior

Updated clients advertise support for separate room keys inside their encrypted P2P exchange. Initial escalation requires that peer capability. The API requires `protocol_version: 2` for escalation and joining; old clients receive an update-required response. This intentionally limits conference availability during a mixed-version rollout rather than allowing incompatible room keys into a live P2P call.

## Missed-call findings

| Finding | Validation and resulting change | Status |
|---|---|---|
| MC-01 | Provisional incoming-call rows were already present at review time. Idempotent merge behavior remains covered. | Existing fix confirmed |
| MC-02 | Unanswered classification already existed. A shared terminal mapper now also distinguishes failed local answers, sibling answers and aborted conferences consistently. | Existing fix confirmed and extended |
| MC-03 | No recovery existed for a completely missed ring. An authenticated, paginated endpoint returns eligible unanswered direct calls; iOS reconciles missing rows without overwriting local answered/declined outcomes. | Implemented; PostgreSQL authorization tests pass |
| MC-04 | Calls was a snapshot. Successful local commits publish a change event; the screen refreshes while open and on foreground. | Implemented; commit notification test passes |
| MC-05 | Failed SQLite writes could disappear. Account-scoped pending writes survive retries, and notifications publish only after commit. | Implemented; failed-write/retry regression passes |
| MC-06 | Parallel paths independently chose terminal outcomes. Primary and waiting paths now share a facts-based mapper; sibling handling writes the correct final outcome once. Conference abort maps to failure. | Implemented; terminal classification matrix added |
| MC-07 | Original tests stopped short of push/UI end to end. Added commit, persistence, audio ownership, terminal outcome and server recovery checks. | Partial coverage; physical PushKit/Recents matrix pending |
| MC-08 | Device-local full history remains a product limitation. Recovery now restores eligible missed direct calls, but not complete answered/outgoing history from other devices. Clearing local history records a cutoff to prevent recovery resurrecting it. | Partial by design |

## Read-receipt findings

| Finding | Validation and resulting change | Status |
|---|---|---|
| RR-01 | The whole-conversation server sweep already addressed the 50-message ceiling. The integration fixture now covers 2,502 incoming messages and exact compatible per-message events. | Existing fix confirmed and tested |
| RR-02 | Failed reads lacked recovery. Mobile clients persist account-scoped intents, keep the original timestamp boundary, retry on foreground/reconnect and only acknowledge the matching generation. | Implemented; Swift and Android persistence tests pass |
| RR-03 | Whole-conversation events did not match mobile consumers. Server emits the existing per-message receipt format for changed IDs. | Implemented; exact event-set test passes |
| RR-04 | Privacy-off also prevented durable clearing. `last_read_at` is private recipient state; `send_receipts: false` advances it without sender receipt rows/events. Mobile queues check captured and current consent. | Implemented; privacy-off database and queue tests pass |
| RR-05 | Optimistic clearing existed only in memory. Local positions persist and overlay fetched/cached conversations without hiding messages newer than the read boundary. | Implemented; full rendered UI matrix pending |
| RR-06 | Requests omitted device identity. Mobile requests carry the device ID; the endpoint checks ownership and revocation. | Implemented; integration tests pass |
| RR-07 | End-to-end failures lacked coverage. Added real-database boundary/privacy/device tests, a Swift persisted-queue fixture and Android queue tests. | Partial coverage; two-account UI matrix pending |
| RR-08 | Web companion was denied access and only marked loaded IDs. Its capability allowlist permits a matching linked-device request and the engine uses the whole-conversation route. | Implemented; capability tests and web build pass |

## Verification

- API: **329 passed, 0 failed, 14 skipped**. Conference admission/capacity, lifecycle, device arbitration, rollback, expiry, missed history and receipt PostgreSQL suites ran against an isolated local database. Skips are other integration suites requiring their own environment variables/services.
- WebSocket: **23 passed, 0 failed, 3 skipped**. Added tests execute the production replay functions with Redis/socket seams replaced; cover device isolation, expiry, authorization, rollback, buffer length and TTL. Redis-dependent suites remain skipped.
- Android: **153 tests, 0 failures, 0 errors**, across 29 result files; Debug compilation and unit tests passed offline.
- API, WebSocket and web-client builds passed.
- iOS simulator Debug build **passed**, including the final shared outcome mapper and notification extension.
- `check-chat-read-intents.py`: persisted failed-request recovery, fixed boundary, privacy-off behavior, supersession and account isolation passed.
- `check-call-recovery-history.py`: actual SQLite migration/upsert and mobile recovery/duration checks passed.
- `check-call-lifecycle.py`: five production CallKit callback regressions passed.
- `check-conference-recovery.py`: five Swift recovery scenarios and five coordinator elections passed.
- `check-call-key-interop.py`: shared Swift/Android key derivation and commitment vectors passed.
- `check-call-audit-fixes.py`: session ownership, commit-only notifications, failed-write retry, P2P/room key isolation, and all six shared terminal outcome scenarios **passed**.

These checks do not establish physical microphone continuity, background push delivery, Apple Phone Recents behavior or production LiveKit reachability.

## Rollout and remaining acceptance work

1. Apply migrations `075_private_read_position.sql` and `076_conference_handover.sql` before the API version that queries their columns. Both are additive and idempotent.
2. Release the updated API and WebSocket services, then mobile apps and web client. Expect older mobile versions to be refused conference escalation/join. No deployment was performed by this task.
3. Verify actual LiveKit credentials/reachability and the four platform mixes in the conference audit. Exercise blocked SFU access, locked/killed invitees, two-device answering, route changes and coordinator departure.
4. Run the missed-call audit's signed-iPhone matrix, including withheld pushes and Calls already open. Confirm Voiid history and Apple Recents independently.
5. Run the receipt audit's two-account UI matrix: privacy on/off, direct/group, offline/relaunch, rapid open/back, new messages after the boundary and multiple devices.
6. Implement and validate CF-03's SDK/indexed transition before claiming seamless encrypted rekeying.
