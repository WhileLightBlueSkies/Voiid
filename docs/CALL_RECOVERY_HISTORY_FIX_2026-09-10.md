# Recovered-call status and call-history timing — September 10, 2026

The user reported that audio returns while the call still says “Reconnecting”, and requested the original call time plus duration in chat.

## Recovery

Android's restart watchdog previously returned when ICE was healthy without clearing the reconnecting flag or completing recovery bookkeeping. Network-change hints also set the flag before checking whether the media path was actually interrupted. iOS renegotiation marked the call reconnecting but relied on a subsequent ICE transition to clear it, even when the existing transport continued working.

Both clients now reconcile current transport health through the existing stats sampling path and SDP completion paths. Android's watchdog also reconciles before returning. Healthy ICE clears the reconnect label even if an SDP answer is pending; pending signaling remains intact. Stable signaling additionally clears recovery timers and resets the restart attempt state. Stale/ended Android calls and absent/ended iOS calls are excluded. Neither path recreates media tracks or resets the first connected timestamp.

## Call history

- The displayed timestamp and transcript ordering remain the original dial/ring time. Upserts preserve the earliest recorded start, even if an initial write completes after the terminal write.
- Both databases gain a nullable `connected_at` column through an additive migration. The first connected time is persisted and never replaced by reconnects or duplicate reports.
- New connected-call duration is `ended_at - connected_at`, excluding ringing. Example: ring at 10:00:00, connect at 10:00:20, end at 10:01:25 → timestamp 10:00, duration 1:05.
- iOS now persists the initial call record when telemetry starts, rather than relying on a terminal write. Both clients persist the connected transition. Call-waiting promotion retains the waiting call's original ringing timestamp.
- Late initial writes cannot overwrite an already-finished call's final outcome. Conversation/peer identifiers learned after the initial push fill missing history fields.
- Android Recents previously treated database seconds as milliseconds for both time and duration. It now converts for date formatting and calculates duration in seconds. Chat view models continue using milliseconds on Android and Date on iOS.
- Existing historical records have no recoverable first-connected timestamp. They remain intact and retain their previous elapsed-time estimate; the migration does not invent missing timing data.

## Validation

`tools/check-call-recovery-history.py` runs the production Kotlin/Swift recovery methods and duration models, and executes the actual migration/merge SQL against the shipped Android v4 call-history schema. Coverage includes healthy/disconnected transports, pending SDP, stale/ended calls, unchanged connected time, duration excluding ring time, missed calls, clock-order clamping, preservation of existing rows, and delayed/duplicate writes.

Final Android debug and iOS device builds passed after the recovery adjustment. All 114 Android JVM tests passed with no failures, errors, or skips. The targeted recovery/history checks and iOS bundle-resource preflight also passed.

Physical verification is pending: Android is absent from USB/wireless ADB discovery and the paired iPhone's device tunnel is disconnected. These builds have not yet been installed on the test phones. The checks above establish build and regression coverage, not live network-handover behavior.

## Device checks

1. Place a call in each direction, briefly interrupt the network, then restore it. Once audio returns, “Reconnecting” should clear and elapsed connected time should continue.
2. Let a call ring for a noticeable interval before answering. End it after about a minute and verify both chat and Recents show the original ringing time and roughly one minute of connected duration.
3. Repeat across a minute boundary and check missed/declined calls, which must not show connected duration.
4. Open existing history after upgrading; prior records must still be present.
