# Early call termination investigation

## Evidence

The API ring and TURN requests succeeded during reproduced failures. iPhone console capture at 16:59:50 IST received call_hangup while ringing; ringback stopped immediately. A call_answer frame arrived at 16:59:54. This establishes incoming hangup handling on that attempt, but does not identify the originating Android callback or prove the later answer belongs to the same call (the console type-only lines do not record its ID). Older PostgreSQL error messages were not established as related; the inspected conference participant query passed read-only EXPLAIN against the deployed schema.

## Concrete Android defect corrected

VoiidConnection.onReject/onDisconnect/onAbort forwarded to unscoped CallManager actions. Delayed callbacks could therefore decline or hang up a replacement call. Added main-thread execution with checks for current call ID, connection identity and termination state before answer/reject/disconnect/abort/hold/unhold and ring UI actions. A delayed ring UI callback also verifies that the call is still incoming/ringing. Old connection cleanup now removes only its own mapping, not a newer object under the same call ID. Constant, content-free diagnostic labels identify Telecom abort/disconnect/reject actions in future logs.

This is a code-confirmed race correction, not proof that it caused the friend's failure. No call authorization, TLS, encryption or caller hangup semantics were weakened. Current-call hangup still functions normally.

## Validation and follow-up

Android assembleDebug and existing unit tests passed on the initial guard. Final build includes the diagnostic labels and ring-state check. Shareable APK replaces build/share/Voiid-Android-2026-09-11-latest.apk after validation. No connected Android test device is available; actual call behavior requires the friend's retest/bug report. iPhone console is /tmp/voiid-iphone-call-console-20260911.log (private). Temporary server call-route diagnostics expire automatically one hour after activation.

Final build and unit tests passed; APK signature verification passed. Latest shareable APK has been replaced with this build.

## Retest: failure persists

The user reports the updated Android APK still fails. The stale Telecom callback guard is not a confirmed resolution. Deployed WebSocket index.ts and callSignaling.ts hashes matched local source before the diagnostic update. Relay error-log modification time was 06:28 UTC, so its TLS/Redis errors are historical, not evidence for the newer attempts. Anonymous two-hour metrics predominantly used unknown end reasons and cannot identify a particular user's failure.

Added temporary WebSocket lifecycle diagnostics gated by VOIID_CALL_DIAGNOSTICS_UNTIL. Only allowlisted event, decision, reason and timestamp are logged; no call/user/device identifiers, SDP, ICE candidates, ciphertext or arbitrary client reason strings. This can distinguish received/forwarded hangup reasons and device-arbitration rejection, but cannot conclusively correlate concurrent calls. Five targeted tests passed; Redis integration test skipped without a dedicated local test Redis. WebSocket TypeScript build passed. This is diagnostic instrumentation, not a calling behavior change or proven fix.

## Android bug-report findings (17:31 IST capture)

The private report confirms these separate observations:

- At 17:28:07, the API connection times out after **15000 ms**, not 1500 ms. Two following bootstrap transport retries fail too. The stack is in E2EManager bootstrap via ApiClient; this alone does not identify a call-ring failure.
- The failed socket originates from the device's VPN tunnel address. The active network dump identifies an AdGuard VPN on tun0, and its UID ranges include Voiid. VPN/filtering interference is therefore a concrete lead requiring an A/B test, not a proven root cause.
- At 17:27:48, ActivityManager kills the Voiid process for `remove-task`. That entry is not a Java crash report and does not by itself prove an active call was killed.
- The earlier 17:18 attempt receives offer/ICE signaling and a call_taken frame. The latter can be the normal echo of the device's own answer and is not proof of incorrect multi-device arbitration. WebRTC playout starts at 17:18:14 and stops at 17:18:41; this does not prove bidirectional audio connected.
- Package metadata shows installation/update at 17:15 IST, but versionCode 1 / versionName 0.1 cannot uniquely identify the APK contents.

Next controlled check: temporarily pause AdGuard on the affected phone, reopen Voiid, and test both call directions. Do not bypass the user's VPN in application code, disable TLS verification, or label the overall calling issue fixed based solely on this report. No raw report, message data, device identifiers or private network addresses are stored in this document.

## Second report and deployed call-mode correction

The 18:01 IST Android report shows successful outgoing-call answer/key verification, but incoming offers followed by early terminal signaling. The server trace likewise contains early hangup frames. Without per-call correlation and originating-device diagnostics, these entries alone do not establish which device initiated every hangup.

Code-confirmed defect: `/calls/ring` used `encodeCallGrant`, which writes format version 2 for ordinary 1:1 calls as well as conferences. The relay used `grant.v !== 2` to enable device arbitration, so current 1:1 calls skipped it entirely. Added an explicit server-authored `mode: one-to-one` marker and a shared predicate. Conference rewrites retain conference behavior, including conferences with only two remaining participants. Unmarked v2 grants preserve rolling-deployment compatibility; the correction applies to fresh calls.

Validation: common-utils, API and relay TypeScript builds pass. Local targeted suite: 42 passed, one Redis integration test initially skipped. On the server, all five signaling tests subsequently passed against a dedicated loopback-only, nonpersistent Redis instance, including competing answers, caller-sibling cancellation, late answers after cancellation, and stale device hangups. Test Redis was stopped. Backup-protected API/relay deployment completed at 12:51 UTC; API health reports database and Redis up and the relay listener is ready. No mobile binary changes required for this server correction. This is a verified defect fix, not yet confirmation that the reported directional failure is resolved.

## Retest after call-mode fix

User reports iOS-to-Android still fails. The explicit-mode defect correction is not sufficient to resolve the reported behavior. Server lifecycle diagnostics expired at 12:56 UTC, so the later retest was not captured; do not infer a new result from the older events. Added content-free iOS termination-path diagnostics: in-app hangup request, CallKit end callback/current-call match, provider reset, and terminal engine reason/direction/connected state. Device verification is still pending.

Caller-side diagnostic build passed xcodebuild and startup-resource validation; installed on Nehal's iPhone and launched under devicectl console at 18:59 IST. Console file is private at /tmp/voiid-ios-caller-end-console.log. Launch and app log output were verified. Awaiting a new reproduction; this diagnostic build is not a claimed functional fix.

## Captured 19:00 IST reproduction

The iPhone received call_hangup at 19:00:43 and 19:00:50. For both attempts its terminal trace is remoteHangup, outgoing=true, connected=false, notifyPeer=false, fromCallKit=false. Thus its local CallKit/UI did not initiate these two cancellations. User clarifies the trigger is Android tapping Answer. The iPhone process was later killed with signal 9; that is separate from the preceding remote-end traces.

Added Android diagnostic lines at answer acceptance, media/SDP preparation, local SDP installation, and centralized teardown. Teardown includes internal reason/state and up to five app code locations, without call IDs or peer identities. Android build, 138 unit tests, and APK signature verification passed. build/share/Voiid-Android-2026-09-11-latest.apk now contains these diagnostics. Awaiting an Android report from a reproduction on this build. No additional call behavior change or resolution claimed.
