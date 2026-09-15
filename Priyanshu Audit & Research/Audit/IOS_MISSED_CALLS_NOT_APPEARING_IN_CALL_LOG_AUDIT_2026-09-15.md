# iOS missed calls not appearing in call logs: audit

> **Date:** 15 Sep 2026  
> **Baseline:** `main` at `9fc79f3`  
> **Scope:** iOS incoming 1:1, conference and call-waiting lifecycle; Voiid’s local Calls screen; Apple Phone Recents through CallKit; notification backstops; persistence; comparison with Android.  
> **Method:** read-only source/history audit. No product code or user data was changed. CallKit/PushKit behavior requires signed real-device verification and was not treated as simulator-verifiable.

---

## Executive summary

The report is credible and matches two historical iOS gaps, both of which have repair code on the current `main` branch:

1. iOS used to wait until call teardown before writing Voiid’s local `call_history`. If the app was suspended or killed while the call rang, teardown never ran and the missed call left no row. Android’s working implementation writes a provisional missed row as soon as ringing starts.
2. iOS previously reported every unconnected remote end to CallKit as a normal completed call. Apple Phone Recents therefore did not classify it as missed.

Current `main` now writes a provisional local row from `beginCallTelemetry()` at ring start and later upgrades the same row by call ID. It also reports `.unanswered` to CallKit for inbound calls that never connected. These changes strongly suggest the observed iOS device is running an older build, or the updated path has not been verified/deployed on a signed device.

The issue is not fully closed, however. There is no server-to-iOS call-history reconciliation when the original VoIP push never arrives, the backend missed-call sweep targets only FCM devices, the iOS Calls screen reads SQLite only once per presentation, and local write failure is silently reduced to a log line. These gaps can still produce missing or apparently missing entries.

**Assessment:** historical P0/P1 lifecycle defect appears repaired in source; remaining P1 recovery gap and P2 live-refresh/durability gaps require implementation and device verification.

## Two different “call logs”

The product has two independent histories and both were audited:

- **Voiid Calls screen:** reads the device-local SQLite `call_history` table ([CallLogView.swift:98](../../apps/ios/Voiid/Voiid/Main/CallLogView.swift#L98)). It does not sync from the backend.
- **Apple Phone → Recents:** driven by CallKit. Whether iOS labels a call missed depends on the `CXCallEndedReason` supplied by Voiid ([CallManager.swift:233](../../apps/ios/Voiid/Voiid/Networking/CallManager.swift#L233)).

A call may appear in one and not the other. The fixes and remaining risks are different for each.

## Expected iOS flow on current `main`

1. A VoIP push creates the inbound active call.
2. `beginCallTelemetry()` immediately inserts a provisional `outcome="missed"` row before CallKit reporting and before PushKit completion ([CallService.swift:1225](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1225)).
3. A scheduled local notification is handed to the system as a process-death backstop ([CallService.swift:1238](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1238)).
4. On answer/connect, the same call ID is upserted to `answered`.
5. On teardown, the final local outcome is persisted and an unconnected inbound call is reported to CallKit as `.unanswered` ([CallService.swift:2218](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2218)).
6. Opening Voiid’s Calls sheet queries the latest 500 local rows.

## Findings

| ID | Severity | Status | Finding |
|---|---:|---|---|
| MC-01 | P0 | Repaired in current source | iOS historically recorded missed calls only at teardown, which may never run after suspension/termination |
| MC-02 | P1 | Repaired in current source | Wrong CallKit end reason prevented Apple Recents from classifying calls as missed |
| MC-03 | P1 | Open | iOS cannot recover a missed call when the original VoIP ring never reaches the device |
| MC-04 | P2 | Open | The Voiid Calls screen does not refresh while already presented |
| MC-05 | P2 | Open | Call-history persistence is best-effort and failures are not recoverable |
| MC-06 | P2 | Partially repaired | Call waiting and conference paths have separate history branches and need real-device matrix coverage |
| MC-07 | P2 | Coverage gap | Existing checks validate merge/lifecycle fragments, not PushKit → SQLite → UI end to end |
| MC-08 | P3 | Product limitation | Call history is device-local and disappears on reinstall or another device |

## Detailed findings

### MC-01 · P0 · Repaired in current source · Missing provisional history write

**Historical failure.** A missed call was finalized inside `endActiveCall`. iOS may suspend or terminate the app after the mandatory PushKit completion while CallKit continues owning the ring UI. In that case no later application teardown code is guaranteed, so the local row was never written.

**Why Android worked.** Android explicitly records `outcome="missed"` immediately after constructing the incoming ringing state ([CallService.kt:542](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L542)). Its own comment states that this protects the ignored-call/process-death case.

**Current iOS repair.** `beginCallTelemetry()` now records the active call immediately with a provisional missed outcome ([CallService.swift:936](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L936)). Both the VoIP-push path and foreground WebSocket-offer path call it before reporting the call ([CallService.swift:1233](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1233), [CallService.swift:1476](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1476)). The upsert later upgrades the outcome without duplicating the row.

**Conclusion.** This is the strongest explanation for Android working while iOS production did not. Confirm the affected build contains this code; source presence alone does not prove deployment.

### MC-02 · P1 · Repaired in current source · CallKit was told the call completed normally

Apple Phone Recents is not populated from Voiid’s SQLite table. It relies on CallKit lifecycle reports. Reporting `.remoteEnded` for an inbound call that never connected classifies it like an ordinary completed call rather than a missed call.

Current code selects `.unanswered` whenever the call never connected and was not explicitly declined/busy ([CallService.swift:2221](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2221)). `CallManager` passes that reason to `CXProvider.reportCall` ([CallManager.swift:239](../../apps/ios/Voiid/Voiid/Networking/CallManager.swift#L239)).

**Verification required.** Make a signed-device inbound call, ignore it until timeout, and confirm the row appears red/missed in Apple Phone Recents as well as Voiid Calls. Simulator success is not evidence for CallKit/PushKit behavior.

### MC-03 · P1 · Open · No iOS reconciliation for a completely missed ring

Voiid’s in-app history is local-only. A device can write a provisional row only if it receives the VoIP push or live WebSocket offer and starts the incoming-call path. If APNs drops the VoIP push, the token is stale, the phone is offline beyond the ring window, or the app is force-quit, there may be no local call lifecycle to record.

The backend does have a durable missed-call sweeper, but it selects only devices with `push_provider='fcm'` ([missedCallNotifications.ts:22](../../backend/api/src/missedCallNotifications.ts#L22)). That is explicitly an Android/FCM recovery path. There is no audited endpoint or startup sync that returns missed server calls to iOS and inserts them into `call_history`.

**Required correction.** Add a server-backed call-history/missed-call reconciliation cursor for authenticated devices, or extend the durable alert path to APNs and have the iOS notification handler idempotently persist the call by `call_id`. The server record should be the recovery source; local provisional writes remain the instant/offline fast path.

### MC-04 · P2 · Open · Calls screen is a one-time snapshot

`CallLogView` loads entries only in `.task` when the sheet is presented ([CallLogView.swift:98](../../apps/ios/Voiid/Voiid/Main/CallLogView.swift#L98)). It does not observe database changes, app-active notifications, or CallService completion.

If a call ends while the Calls sheet remains open—or the sheet stays alive across a lifecycle transition—the new row will not appear until the user dismisses and reopens it. This can look identical to missing persistence.

**Required correction.** Observe GRDB changes or publish a call-history-changed event after committed writes. At minimum reload on scene activation and call teardown while the sheet is visible.

### MC-05 · P2 · Open · Persistence failure is silent and unrecoverable

`LocalStore.recordCall` uses the database’s best-effort `write` method ([LocalStore.swift:273](../../apps/ios/Voiid/Voiid/Storage/LocalStore.swift#L273)). If the database pool is unavailable or the transaction fails, `write` logs and returns `nil`; the caller ignores the result ([VoiidDatabase.swift:307](../../apps/ios/Voiid/Voiid/Storage/VoiidDatabase.swift#L307)). Because there is no server reconciliation on iOS, that failure permanently loses the entry.

**Required correction.** Use an outcome-bearing committed write for call history, emit diagnostics/metrics on failure, and queue an idempotent retry. Do not acknowledge any server history cursor until the local insert commits.

### MC-06 · P2 · Partially repaired · Parallel incoming-call paths can drift

iOS has distinct paths for primary 1:1 calls, calls received only through WebSocket, call waiting, third-call/busy handling, conference invitations, and “answered elsewhere.” Current source contains explicit writes for these paths, including waiting-call finalization ([CallService.swift:1647](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1647)).

The risk is regression rather than one obvious missing current branch: each path independently chooses outcome, CallKit reason, notification cancellation, timestamps, and whether a row is provisional or final. Android centralizes more of the final outcome calculation around `recordCall` ([CallService.kt:2220](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2220)).

**Required correction.** Define one shared iOS final-outcome mapper and one idempotent history owner. Every exit path should supply facts—direction, connected, locally answered, declined, busy, taken elsewhere—rather than independently inventing strings and CallKit reasons.

### MC-07 · P2 · Coverage gap · Existing checks stop before the UI boundary

`tools/check-call-recovery-history.py` validates SQLite migration/upsert semantics and duration calculations. `tools/check-call-lifecycle.py` validates five CallKit callback state cases. These are useful, but they do not prove that a real VoIP push writes a row, that the process-death case survives, or that `CallLogView` refreshes.

**Required test matrix:**

- signed iPhone, app foreground/background/suspended/force-quit;
- ignore, decline, answer then hang up, caller cancels, no SDP after push;
- ordinary 1:1, call waiting, group/conference invitation;
- call answered/declined on another device;
- VoIP push delivered versus intentionally withheld;
- Voiid Calls open during the event and opened afterward;
- Apple Phone Recents classification;
- restart/reinstall/multi-device expectations.

Add a store-level iOS test that starts an incoming ring, asserts a provisional row exists before teardown, finalizes it, and asserts a live Calls view receives the change.

### MC-08 · P3 · Product limitation · History is device-local

The Calls screen explicitly states that it shows calls made or received on this device ([CallLogView.swift:170](../../apps/ios/Voiid/Voiid/Main/CallLogView.swift#L170)). It does not recover calls answered or missed on another phone, and reinstalling removes the log.

That limitation is documented in the UI, but it becomes operationally important here: without a server reconciliation source, “the device never ran the incoming path” and “the logging code is broken” produce the same empty result.

## Root-cause conclusion

The primary historical iOS root cause was lifecycle timing: durable history was written too late. Android wrote at ring start, while iOS depended on teardown in a process the OS was free to suspend. The current provisional-write code brings iOS in line with Android and is the most likely repair for the reported difference.

The deeper remaining weakness is local-only truth. A local log cannot recover an event the device never received, and a notification alone is not a database record. Reliable missed-call history needs an idempotent server reconciliation path in addition to immediate local recording.

## Recommended implementation order

1. Confirm the affected iOS build predates or includes the provisional write and `.unanswered` CallKit repair.
2. Run the signed-device matrix for both Voiid Calls and Apple Phone Recents.
3. Add server-to-iOS missed-call reconciliation keyed by `call_id`.
4. Make call-history writes acknowledged/retryable and observable.
5. Refresh the Calls screen live or on scene activation.
6. Consolidate iOS outcome mapping and add path-complete regression tests.

## Verification performed

- Traced iOS PushKit/CallKit receipt, ring caps, provisional/final persistence, local notification backstop, call waiting, taken-elsewhere handling, SQLite schema/upsert, Calls screen query/filtering, and Apple Recents reporting.
- Compared Android’s incoming-ring and finalization writes with iOS.
- Inspected backend missed-call recovery and confirmed it currently selects FCM devices only.
- Ran `tools/check-call-lifecycle.py`: all five production CallKit handler regression cases passed.
- Ran the history recovery checker. Its SQLite portion passed for both Android and iOS. The full script then stopped because its dependency lookup selected Gradle `*-sources.jar` files and could not load the Kotlin compiler main class; this is a checker-environment failure, not evidence that the app behavior passed or failed.
- No application files or existing user changes were modified.
