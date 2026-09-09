# iOS and Android call audit

Implementation follow-up: [calling fixes and verification](CALL_FIXES_2026-09-09.md). The audit below describes the pre-fix baseline; automated results do not mark physical-device cases as passed.

Date: 2026-09-09. Baseline: working tree at `9b0f574`, including existing uncommitted changes. Scope: native 1:1 call engines, system-call integration, selected group/conference lifecycle paths, signaling relay, call history/status and metrics. This was an audit; call implementation files were not changed.

**Assessment:** the implementation has substantial foundations, but I would not sign off on call reliability under cancellation races, delayed callbacks and poor networks yet. The source audit identified **6 high-priority findings (P1) and 4 medium-priority findings (P2)**. These are specific control-flow defects or missing safeguards, not a measured production failure rate.

Evidence levels:

- **Reproduced in isolation:** an unchanged production Swift method body was executed with stubbed collaborators and triggered the stated defect.
- **Source-confirmed:** the relevant branches/call sites are present or missing in the inspected code. The resulting device symptom is a predicted consequence; its frequency has not been measured on physical phones.
- **Backend tests:** existing regression tests ran locally against their test doubles/local HTTP server. They do not establish real push delivery or native media reliability.

## Prioritized findings

| ID | Severity | Affected path | Finding |
| --- | --- | --- | --- |
| CALL-A01 | P1 | iOS/Android setup; selected group paths | Setup continues after cancellation and can mutate a later call |
| CALL-A02 | P1 | iOS system actions; both media engines | Callbacks are not consistently bound to their original session |
| CALL-A03 | P1 | Android notification actions | Stale decline/end actions can act on the current call |
| CALL-A04 | P1 | iOS incoming; Android pre-answer SDP failures | Initial connection deadlines do not cover the full answer/setup path |
| CALL-A05 | P1 | iOS network recovery | Sent restart offers have no application response watchdog |
| CALL-A06 | P1 | Multi-device answer handling and relay | No atomic device winner for simultaneous answers |
| CALL-A07 | P2 | Cross-platform end signaling and Android UI | Decline/no-answer reasons are lost or displayed generically |
| CALL-A08 | P2 | Android history and system recents | Answered-elsewhere and accepted-but-failed calls become missed |
| CALL-A09 | P2 | iOS reliability metrics | Metrics submission is defined but never invoked |
| CALL-A10 | P2 | Backend lifecycle status | A late connected update can overwrite an ended call |

### CALL-A01 — P1: cancellation does not retire in-flight setup

**Evidence: source-confirmed.**

[iOS startCall](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L681) launches an untracked `Task`. It awaits TURN/setup, ring authorization and key exchange, then continues to create/send an offer without checking that `active.id` still matches the captured call. [setupPeerConnection](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2129) creates shared `pc`, local audio and camera capture after its awaited TURN request without a session check. Teardown closes current resources but does not cancel that task. Late ring errors call `hangUp()` against whichever call is active at that point.

[Android startCall](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L396) has the same pattern: a shared-scope coroutine awaits ring/key work, then queues peer-connection/media creation on `exec`. There is no captured-call-ID validation before that work or in its error cleanup. `endInternal` does not cancel this setup coroutine.

The pattern also exists in [iOS group join](../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L163): leaving while token fetch is suspended can be followed by room creation, microphone publication and `state = .connected`. Android group setup has useful null-state checks, but [those checks](../apps/android/app/src/main/java/com/voiid/app/net/GroupCallService.kt#L218) do not distinguish an old join from a newly started group call.

**Reproduce:** delay TURN/ring/token response, start a call, cancel, optionally start a second call, then release the first response. Observe renewed capture/signaling, an old error ending the second call, or an old group join replacing newer state.

**Fix direction:** own setup in a per-session task/job; cancel it on every terminal path; validate a session generation and call ID after every suspension and before every shared-state mutation, media creation or send. Cleanup must target the captured session, not a global current call.

**QA cases:** END-01, END-02, END-13, END-18, END-19, GRP-07.

### CALL-A02 — P1: stale callbacks can end or reconnect a newer call

**Evidence: iOS end action reproduced in isolation; media callback behavior source-confirmed.**

[iOS callKitEnd](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1938) checks the UUID only inside optional branches, then unconditionally calls `endActiveCall`. A UUID belonging to neither the active nor waiting call still ends the active call. A harness executed the unchanged production method with an old UUID and a different current call; the current call was ended. A matching-UUID control also behaved normally.

The [iOS ICE callback](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2245) receives the originating peer connection but never checks it against `self.pc` after its MainActor dispatch. A late `.closed` can end a newly installed call; a late `.connected` can mark current state connected. `markConnected` also lacks an ended-state rejection.

[Android's shared pcObserver](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L1728) similarly reads the current global call for candidates and terminal callbacks. Its observer is not constructed per call with a generation guard. Also, [onRemoteAnswer](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L989) does not compare `sig.callId` with the active call before applying SDP and moving current state to Connecting. Call waiting, rapid retries and delayed callback/signaling delivery are relevant triggers.

**Reproduce:** delay the end/callback for call 1; promote or start call 2; deliver call 1's action or `.closed` callback. Check that call 2 survives. The isolated Swift reproduction proved the end-action branch, not the scheduling frequency of native callbacks.

**Fix direction:** reject unmatched UUIDs before teardown; bind observers to session identity; reject obsolete peer connections and terminal-state transitions. Apply identity validation after dispatch to the main/engine queue.

**QA cases:** END-09, END-14, END-18, CON-05, CON-07.

### CALL-A03 — P1: Android decline/end notifications lack call identity

**Evidence: source-confirmed.**

[Incoming notification creation](../apps/android/app/src/main/java/com/voiid/app/net/CallForegroundService.kt#L230) builds Decline with only an action and fixed request code. [CallActionReceiver](../apps/android/app/src/main/java/com/voiid/app/net/CallForegroundService.kt#L434) then calls `CallManager.decline()` without an expected call ID. Waiting-call decline and the receiver's hangup action have the same missing scoping. The ordinary activity-based Accept path already carries a call ID, showing the intended safeguard is only partially applied.

[CallManager.decline](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L1275) has no guard requiring the original incoming ringing call; it acts on the current state.

**Reproduce:** queue/retain a decline broadcast for call 1; end it and start call 2; deliver the old broadcast. It can decline call 2 or terminate its active session.

**Fix direction:** put the originating call ID in every PendingIntent/RemoteAction, use a distinct intent identity, and require a matching eligible state before acting. Cancel old PendingIntents during teardown as an additional safeguard.

**QA cases:** END-16, END-17, CON-06.

### CALL-A04 — P1: application timeouts do not cover the full connecting state

**Evidence: source-confirmed; indefinite duration requires native ICE not independently reaching a terminal failure.**

Android correctly arms a 35-second watchdog in [onRemoteAnswer](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L989) for the outgoing caller, and in [doAnswer.onCreateSuccess](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L1255) for the receiver. The receiver's guard starts too late to cover every setup failure: offer receipt cancels the no-offer guard; Accept changes state to Connecting; failures in remote SDP application or `createAnswer` use the [no-op SdpObserverAdapter error methods](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2526). The incoming ring cap ignores Connecting, while the connection watchdog has not yet been armed.

On iOS, [callKitAnswer](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1697) cancels the ring timers and enters Connecting. There is no corresponding initial media-connection deadline after SDP is available. The ICE switch ignores `.checking`; the recovery watchdog is conditional on later failure/recovery events.

**Reproduce:** on an iOS receiver, accept valid SDP but keep ICE checking and prevent remote termination delivery. Separately, on an Android receiver, deliver an offer, tap Answer, then fail remote SDP application or answer creation before its watchdog is armed. Verify each endpoint has its own finite deadline rather than relying on the other endpoint to hang up. Android's ordinary outgoing post-answer watchdog is already present and should remain a passing control.

**Fix direction:** arm one session-bound setup deadline on entering Connecting on either role, covering SDP creation/application as well as ICE; finish it on connection, cancellation or explicit failure. Handle every SDP callback failure.

**QA cases:** NET-17, NET-24, NET-26, SIG-04, SIG-05, END-13.

### CALL-A05 — P1: iOS restart attempts are capped, but waiting for an attempt is not

**Evidence: source-confirmed.**

[requestIceRestart](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L850) sets `restartInFlight = true`. [performIceRestart](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L901) fetches TURN, sends the offer and returns without arming an answer/recovery deadline. Further restart requests are ignored while the flag remains set. A lost restart offer/answer can therefore stall the recovery sequence; the three-attempt cap does not independently advance retries. A later native FAILED event may restart it, but that event is not an application timeout guarantee.

The answerer recovery watchdog is only started from [handleIceFailed](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L952). The `.disconnected` grace path can reach the answerer branch of `requestIceRestart`, which only sets Reconnecting and returns, without arming that watchdog.

Android already has a watchdog for successfully sent restart offers. Its SDP failure branches still need consideration under CALL-A04. Cross-platform simultaneous restart negotiation also needs physical verification; this audit does not claim a reproduced glare failure.

**Reproduce:** establish a call, force a network handover, drop the iOS caller's restart offer or its answer, and prevent additional terminal ICE transitions. Separately leave an iOS receiver in Disconnected with no restart from its peer.

**Fix direction:** each restart needs a session-bound response/recovery deadline; the answerer needs a deadline whenever it waits for the peer. Cancel/reset watchdogs on recovery and teardown, and drive retry exhaustion explicitly.

**QA cases:** NET-10, NET-19, NET-20, NET-21, NET-23.

### CALL-A06 — P1: simultaneous multi-device answers have no elected winner

**Evidence: source-confirmed.**

The [relay](../backend/websocket/src/index.ts#L836) authorizes and publishes each `call_answer`, then broadcasts a user-level `call_taken` verdict. There is no atomic device claim or winning-device identity in this path. The verdict is a notification after acceptance, not arbitration.

[iOS](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1564) ignores sibling verdicts once `localAnswerGiven` is true. [Android](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L810) ignores them once it leaves Ringing. If two devices accept before either sees the verdict, both consider themselves the answerer and the caller receives two answers for the same call ID. A losing device can later send a same-call hangup and affect the surviving session.

**Reproduce:** sign receiver B into two eligible devices; synchronize Answer on both before either receives `call_taken`; inspect answers, active devices and later hangups.

**Fix direction:** atomically claim the answering device server-side; include it in verdicts; admit media/signaling only for that winner and make every loser retire without notifying the peer as a local hangup. Cover stale/reconnected devices too.

**QA cases:** CON-09, CON-10, CON-11, CON-12.

### CALL-A07 — P2: caller-facing end reasons are lost

**Evidence: source-confirmed.**

The iOS in-app [decline path](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1769) sends `call_decline`. The native [CallKit end path](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1958) sets a local declined reason but calls teardown with `notifyPeer: true`; [teardown](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1996) always emits a generic `call_hangup`. The caller cannot distinguish that lock-screen decline from other remote endings. This also bypasses the relay's sibling `call_taken` branch, which excludes hangups.

Both incoming ring-cap paths likewise send a generic hangup without a no-answer reason. Consequently a healthy 45-second remote timeout need not display “No answer” on the caller, even though the caller's own 60-second fallback has a timeout reason.

Additionally, [Android's ended UI](../apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt#L423) always uses “Call ended”; decline/busy tones alone do not convey unavailable versus connection failure versus no answer.

**Fix direction:** use a shared terminal-reason contract on the wire and preserve it through native actions, app actions, history and UI. Native decline must resolve siblings too. Do not infer an explicit decline from generic remote hangup.

**QA cases:** END-05, END-06, END-08, NET-16, SIG-09.

### CALL-A08 — P2: Android misclassifies handled calls as missed

**Evidence: source-confirmed.**

[onCallTakenElsewhere](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L820) passes `answered-elsewhere` or `declined-elsewhere` to `endInternal`. Its [outcome mapping](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L1981) recognizes neither: absent `connectedAtMs`, both fall through to `missed`. The outcome is persisted and supplied to the system disconnect mapping. The comments saying this path records a handled call do not match the implementation.

Similarly, an explicit Answer followed by the [no-offer timeout](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L620) becomes missed: Android has no counterpart to iOS's `localAnswerGiven` classification for this path. Ring failures and unavailable recipients also fall into the same broad default.

**Fix direction:** record answer intent separately from media connection; explicitly classify handled-elsewhere, decline, cancel, unavailable, setup failure and true missed incoming calls. Preserve direction-specific display semantics even if the storage enum is deliberately smaller.

**QA cases:** HIS-03, HIS-04, HIS-05, CON-09, CON-10, SIG-04.

### CALL-A09 — P2: iOS reliability metrics never leave the client

**Evidence: source-confirmed by definition/call-site search.**

[postCallMetrics](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L827) constructs/submits the sample, but it has no caller in the iOS source tree. Teardown stops the statistics collector without invoking submission. Android does invoke `metrics.report` during teardown.

**Impact:** the presence of an iOS stats collector and passing server metrics tests can give a misleading impression of cross-platform observability. This 1:1 iOS path does not submit its call outcomes/quality samples through the defined method.

**Fix direction:** submit once per call before counters/resources are reset; deduplicate repeated teardown; keep submission best effort. Add a test asserting both connection and pre-connection-failure samples reach the client API boundary.

**QA cases:** SIG-12, SOAK-01, SOAK-02.

### CALL-A10 — P2: backend call state can move backward after ending

**Evidence: source-confirmed.**

[POST /calls/:id/status](../backend/api/src/routes/calls.ts#L700) unconditionally sets `status = $2`. `coalesce` protects the timestamps, not the lifecycle state. Android sends [connected](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L1819) and [ended](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L1968) through independent asynchronous requests. A slow connected request can arrive after ended and leave `status = connected` alongside an existing `ended_at`.

The endpoint is documented as history/status rather than media signaling, so this finding concerns record correctness; it does not by itself prove that a closed media session is reopened.

**Reproduce:** delay a connected status request; let ended commit first; release connected; read the call row.

**Fix direction:** enforce monotonic transitions in SQL/transactional logic; reject or ignore connected updates after terminal state. Add request-reordering tests.

**QA cases:** HIS-06, HIS-08, SIG-06, SIG-12.

## What is already useful in the design

These are implemented safeguards, not blanket device-test passes:

- Ring authorization is awaited before the first offer on both clients, addressing the missing ring-grant race.
- Push-before-offer reconciliation, same-call checks, ICE candidate buffering and explicit incoming/outgoing ring caps exist.
- Caller ringback is driven by `call_ringing` instead of starting blindly when dialing.
- Network-change monitoring, reconnection UI, TURN refresh and ICE restart mechanisms exist; the findings concern incomplete boundaries around them.
- System call integration, Bluetooth/route handling, call waiting, minimized/PiP surfaces and cleanup paths are implemented.
- Group join refuses to proceed when its required encryption keys are unavailable. Conference membership uses call participants rather than automatically granting messaging permission; the backend regression suite covers that contract with test doubles.

## Verification performed

1. Read the current Swift/Kotlin call lifecycle code, system-action routing, media callbacks, selected group join/leave paths, WebSocket relay and status/metrics endpoints. No environment secrets or production service configuration were inspected.
2. Ran:

   ```sh
   node --import tsx --test \
     backend/api/test/callGrantRace.test.ts \
     backend/api/test/callMetrics.test.ts \
     backend/api/test/callConference.test.ts
   ```

   **Result: 60 passed, 0 failed, 0 cancelled** on the successful run. The first sandbox run could not bind the conference test's local HTTP listener (`listen EPERM`); rerunning with approved loopback access completed the suite. The ring-grant tests model the gate, and the conference tests use controlled database/service doubles. This is not a deployed-system end-to-end test.
3. Extracted `CallService.callKitEnd` unchanged into a small Swift executable with stub collaborators. Passing an old UUID while a different call was active ended the current call; matching-UUID control passed. Temporary reproduction: `/tmp/voiid-call-audit/CallKitStaleEnd.swift` and `/tmp/voiid-call-audit/stale-end-check`.
4. No two-phone calls, PushKit/FCM delivery tests, real network impairment, camera/audio checks, native UI automation or full app rebuild were performed in this audit. Therefore battery impact, actual drop rate, network quality, audio quality and real-device race frequency remain unmeasured.

## Recommended implementation order

1. Fix session ownership and cancellation first: CALL-A01 through CALL-A03. New call state must be immune to old work and old actions.
2. Close setup/recovery deadline gaps: CALL-A04 and CALL-A05. Verify Android → iOS and the reverse with media blocked and signaling delayed independently.
3. Add server-side device winner arbitration: CALL-A06.
4. Align terminal signaling, history, telemetry and monotonic server state: CALL-A07 through CALL-A10.
5. Run the [cross-platform smoke suite and full call matrix](CALL_QA_TEST_MATRIX.md) on physical devices. Require both phones to reach consistent outcomes; a caller-only pass can hide a receiver still ringing.

Do not treat the existing HTTP `CancellableCallTest` as proof that call-session cancellation works: it tests cancellation of an HTTP operation, while CALL-A01 concerns whether the owning call engine actually cancels and scopes its work.
