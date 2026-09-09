# Voiid call QA test matrix

Implementation follow-up: [calling fixes and verification](CALL_FIXES_2026-09-09.md). The audit below describes the pre-fix baseline; automated results do not mark physical-device cases as passed.

Conference follow-up: [join, leave, key recovery and call-ending fixes](CONFERENCE_LIFECYCLE_FIXES_2026-09-09.md), with targeted acceptance cases still awaiting a three-device run.

Prepared: 2026-09-09. **Status: test cases generated; none of these runs has been executed as part of this document.** This is a release acceptance plan, not a claim that all expected behaviors currently work. Expected results describe the desired behavior; known code differences are listed below.

A = caller; B = receiver; C = another caller or invitee. “Cut” means End/Cancel by the caller; “decline” means an explicit rejection by the receiver. Test both phones together: passing on A while B keeps ringing is a failure.

## Execution matrix

| Direction | Caller A | Receiver B |
| --- | --- | --- |
| D1 | iOS | Android |
| D2 | Android | iOS |
| D3 | iOS device 1 | iOS device 2 |
| D4 | Android device 1 | Android device 2 |

Run every applicable P0 case in all four directions for **voice and video**. Voice-only/video-only cases use their named mode. Platform-specific cases run with that platform in the named role. Group cases require mixed iOS/Android membership and rotation of the inviter/affected peer. Use two distinct devices/accounts for same-platform runs. Use a third account for call waiting and group invitations, and two eligible signed-in devices on B's account for multi-device cases.

Run the core answer/cancel/decline/no-answer cases with B foregrounded, backgrounded, locked, and with its process not running. Repeat with A foregrounded, backgrounded and locked. Keep Android Settings Force stop, swiping from recents, OS process termination and iOS app-switcher dismissal as separate states in the results. Record exact OS, Android OEM/model, notification settings, battery restrictions and distribution build.

For network cases, impair A only, B only and then both unless the row specifies a topology. Repeat P0 setup/end cases on N0 and N1; network rows use their named profile. Use boundary offsets of −250 ms, approximately simultaneous, and +250 ms for race cases, at least ten repetitions per ordering.

A run ID is `CASE.DIRECTION.MODE.APPSTATE.NETWORK.AFFECTED.REPEAT`, for example `END-09.D1.VIDEO.LOCKED.N1.B.R03`. Each expanded run gets its own result; do not mark an entire base case passed after one platform combination.

## Preconditions and network profiles

Use dedicated authorized test accounts with established contact reachability, working camera/mic permission, valid push registration, a known API/socket build and a baseline call that connects. Use physical phones for real push, system call UI, audio routing and background checks. Simulator checks are supplementary. Server fault/replay cases run in a controlled test environment.

The following are **proposed reproducible lab conditions**, not measured Voiid performance guarantees. Apply shaping at a test router, controlled gateway or equivalent tool that actually covers the tested media transport. An HTTP proxy alone does not establish that UDP media was impaired. Record observed bandwidth, RTT, jitter and loss; values at two impaired endpoints may combine.

| Profile | Lab condition | Main purpose |
| --- | --- | --- |
| N0 | Healthy internet; no injected restriction | Baseline and control comparison |
| N1 | 512 kbit/s each way; about 200 ms RTT; 30 ms jitter; 2% loss | Poor mobile/Wi-Fi conditions |
| N2 | 128 kbit/s each way; about 400 ms RTT; 50 ms jitter; 5% loss | Very low bandwidth; audio prioritization |
| N3 | 1 Mbit/s each way; about 800 ms RTT; no added loss | High delay independently of low bandwidth |
| N4 | 1 Mbit/s each way; about 200 ms RTT; 100 ms jitter; 10% loss | Jitter and loss resilience |
| N5 | 100% drop on the selected path for 2, 10 or 45 seconds | Transient outage and exhausted recovery |
| N6 | Block UDP; allow only configured TCP/TLS relay paths and required signaling | TURN fallback |
| N7 | Separate carrier NATs, VPN, or restrictive test network; record exact configuration | Real topology constraints |

## Timing and outcome checks

These defaults come from the checked-out source and must be rechecked if configuration/code changes. Measure each timer from its actual arming event on that phone, not from an assumed shared start time. Lab observation allowance: approximately two seconds after a local foreground deadline; record background scheduling effects separately. Healthy-network terminal propagation target: within two seconds. These allowances are proposed QA thresholds, not a measured SLA.

| Guard | iOS | Android | What to verify |
| --- | --- | --- | --- |
| Push received but 1:1 offer absent | 30 seconds | 30 seconds | B cannot ring/connect forever waiting for SDP |
| Incoming ringing cap | 45 seconds | 45 seconds | Stops unanswered ringing; obsolete timer cannot end an answered call |
| Outgoing unanswered fallback | 60 seconds | 60 seconds | A exits even if remote decline/hangup never reaches it |
| Transient disconnect grace | 3 seconds | 3 seconds | Temporary loss can recover; current call is not re-rung |
| ICE restart budget | 3 attempts | 3 attempts | Recovery terminates after budget exhaustion; successful recovery resets appropriately |
| Android initial media connection watchdog | See iOS setup/recovery path separately | 35 seconds | No indefinite initial Connecting on Android |
| Buffered offer TTL | Server default 60 seconds, configurable | Same server | Expired buffered offers cannot revive old calls |
| Ad-hoc conference size | Server cap: 8 participants | Same server | Ninth participant rejected without disturbing existing call |

After every terminal path verify both phones: no continuing ringtone/ringback; no stale Answer button, overlay or notification; mic/camera released; call timers and retries cancelled; correct peer/direction/type; one logical history record per call ID. An answered call must not later generate a missed-call banner. A failed connection does not mean the other person declined. A network-degraded call need not preserve video quality, but must remain controllable and either recover or end truthfully.

## Code differences to investigate while executing

These are inspection findings, **not reproduced device failures**:

- iOS `CallScreens.endedText` distinguishes decline, busy, unavailable, no answer, setup failure and connection loss. Android's `CallScreens.kt` ENDED branch currently uses “Call ended”; validate the complete Android feedback path and raise a parity defect if the reason is never communicated. Use END-05, END-08, NET-10 and SIG-09.
- Raw history outcomes differ. iOS maps an unconnected outgoing attempt to `failed` in the default branch and busy to `declined`; Android's final default is `missed` for unconnected outcomes except explicit decline/ICE failure. Validate visible history and notification semantics separately from raw storage in HIS-03 through HIS-06; do not assert that a dedicated `cancelled` enum already exists.
- Older reliability/checklist documents contain historical implementation/provisioning statements. Use current source, deployed configuration and measured behavior when deciding pass/fail.
- Android Settings Force stop must not be treated as ordinary backgrounding: FCM requires reopening after a settings force-stop. This does not mean Android recents dismissal has identical behavior. See [Firebase delivery preconditions](https://firebase.google.com/docs/cloud-messaging/flutter/receive-messages).
- For iOS, test the actual PushKit → CallKit path, including a late offer after system UI appears. Apple's flow reports the incoming call and connects to the server in parallel; generic alert-push behavior is not a substitute. See [Apple's VoIP notification flow](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit).

## Case inventory

| Area | Cases |
| --- | --- |
| Basic voice and video calls | 10 |
| Cancel, decline, no answer and end races | 20 |
| Foreground, background, lock and process lifecycle | 16 |
| Weak networks, outages, handover and recovery | 28 |
| Audio, video and call controls | 16 |
| Busy, call waiting and multiple devices | 12 |
| Call history, notifications and cleanup | 10 |
| Group calls and adding someone to a call | 14 |
| Signaling, server faults and authorization | 12 |
| Repetition, accessibility and regression | 6 |
| **Total base cases** | **144** |

P0 = must pass before release for supported states; P1 = extended regression/reliability coverage. `Blocked` means a required condition, device or service is unavailable, not that the case passed. An intentional OS restriction is recorded as `Expected OS limitation` with evidence, followed by a separate recovery-after-reopen result.

## Basic voice and video calls

| ID | Priority | Scenario | Steps / setup | Expected on caller and receiver |
| --- | --- | --- | --- | --- |
| BAS-01 | P0 | Voice call; caller ends | A calls B; B answers; speak both ways for 20 seconds; A ends. | Both hear intelligible audio; timer starts on connection; both end once; no ringtone continues. |
| BAS-02 | P0 | Voice call; receiver ends | Repeat the connected voice call; B ends. | A promptly leaves the active call; B ends locally; one answered record on each device. |
| BAS-03 | P0 | Video call; caller ends | A video-calls B; answer; verify both cameras and microphones; A ends. | Both receive live audio/video; both release camera/mic after ending. |
| BAS-04 | P0 | Video call; receiver ends | Repeat video call; B ends. | A sees the end; no frozen call overlay, active camera or continuing audio remains. |
| BAS-05 | P0 | Calling versus ringing | Delay B's push/socket delivery; then permit delivery. | A stays Calling before an actual ring acknowledgment; Ringing/ringback starts only once B alerts. |
| BAS-06 | P0 | Answer immediately | B answers as soon as the incoming UI appears. | One connecting transition; ringback stops; no accepted call remains on the ringing screen. |
| BAS-07 | P0 | Answer near ring deadline | B answers just before its incoming ring cap. | One terminal decision wins; a connected call is not ended by an obsolete ring timer. |
| BAS-08 | P1 | Long contact identity | Use long names, Unicode and an account without an avatar. | Correct peer and voice/video type appear without clipping controls or inventing an identity. |
| BAS-09 | P1 | Call entry points | Call through chat, profile/contact action and call history, where available. | Each entry reaches the intended peer and the same call lifecycle; one call ID per attempt. |
| BAS-10 | P1 | Immediate redial after normal end | End a connected call; immediately call the same person again. | A new call ID and clean media session; the old cleanup cannot end the new call. |

## Cancel, decline, no answer and end races

| ID | Priority | Scenario | Steps / setup | Expected on caller and receiver |
| --- | --- | --- | --- | --- |
| END-01 | P0 | Cancel before ring request finishes | Throttle the ring API; A taps End immediately after Call. | A ends immediately; delayed API/offer completion cannot start a new outgoing call; B does not retain a stale ring. |
| END-02 | P0 | Cancel while Calling | A ends before B reports ringing. | A stops setup; B suppresses or promptly clears any late incoming UI; never an answered record. |
| END-03 | P0 | Cancel while B is ringing | Wait for B to ring; A taps End. | B stops ringing and clears incoming controls; A ends once. An alerted, unanswered B may receive one missed-call record. |
| END-04 | P0 | Cancel after several rings | Let B ring for 10 seconds; A ends. | Both leave the call; no later timeout adds another log or missed-call banner. |
| END-05 | P0 | Decline inside app | B taps Decline while foregrounded. | B stops ringtone immediately; A receives a declined outcome; B receives no missed-call banner for this deliberate decline. |
| END-06 | P0 | Decline from lock screen | Lock B; call it; decline using the system incoming-call UI. | Same decline semantics; app does not reopen a stale incoming screen on unlock. |
| END-07 | P0 | Decline from notification | Use Android incoming notification Decline, or an equivalent available system action. | The action targets this call ID; caller learns the decline; notification and foreground ringing are cleared. |
| END-08 | P0 | No answer | Neither person acts after A places the call. | B stops at the incoming cap; A learns no answer or reaches its own fallback cap; B has one missed call, no duration. |
| END-09 | P0 | Answer while caller cancels | Synchronize A End and B Answer within about 100 milliseconds; repeat both orderings. | One converged outcome; no ghost connection or permanent Connecting screen; any briefly connected media is torn down. |
| END-10 | P0 | Decline while caller cancels | Synchronize A End and B Decline; repeat both orderings. | Idempotent cleanup; no duplicate history; a deliberate decline must not later produce a missed-call notification on B. |
| END-11 | P0 | Double-tap Answer | B taps Answer rapidly twice. | One accept operation and one media session; no duplicate room/token/peer connection. |
| END-12 | P0 | Double-tap End or Decline | Rapidly tap the relevant terminal control on either phone. | One effective terminal action; no crash, repeated tones or duplicate call records. |
| END-13 | P0 | End while Connecting | B answers; prevent media connection; A ends, then repeat with B ending. | Both escape Connecting; setup work and timers stop; an accepted-but-failed call is not presented as ignored by B. |
| END-14 | P0 | Both end together | Connect; both tap End at the same instant. | Both release resources once; no error screen from the duplicate remote/local end. |
| END-15 | P0 | Decline at timeout boundary | B declines just before, at and just after its ring timer fires. | No contradictory decline-plus-missed notification; late input cannot affect another call. |
| END-16 | P0 | Stale Answer action | Keep an old notification/action reference; end that call; start another; invoke the old action. | Old action cannot answer the new call or resurrect the old one. |
| END-17 | P0 | Stale Decline action | Invoke an old decline action while a newer call is ringing. | The new call continues normally; old action is ignored safely. |
| END-18 | P0 | Redial after decline | B declines; A redials immediately; B accepts the second attempt. | Second call connects; first call's end frame and timers cannot stop it. |
| END-19 | P0 | Redial after no answer | Allow timeout; immediately place and answer another call. | Clean second call; old missed-call backstop cannot interrupt or mislabel it. |
| END-20 | P1 | Late offer after cancel | Deliver A's offer only after A has cancelled. | No persistent ringing or new call; any required system reporting is promptly reconciled as ended. |

## Foreground, background, lock and process lifecycle

| ID | Priority | Scenario | Steps / setup | Expected on caller and receiver |
| --- | --- | --- | --- | --- |
| APP-01 | P0 | Both foreground | Keep both apps open; place and answer a call. | Both app UIs and system call state agree; exactly one incoming alert. |
| APP-02 | P0 | Receiver backgrounded | Leave B on its home screen; call and answer. | Incoming system surface appears when permitted; answering reaches usable media, not endless Connecting. |
| APP-03 | P0 | Receiver locked | Lock B for two minutes; call and answer from the lock screen. | Correct caller and type; audio works after answer without requiring an extra app-opening step. |
| APP-04 | P0 | Receiver process not running | Use a controlled OS/process termination, distinct from Android Settings Force stop; call B. | Supported push wake path reports one call and connects after answer; capture delivery, launch and media timestamps. |
| APP-05 | P0 | Receiver swiped from recents | Swipe away B; call it; repeat on each OS/device model. | Record platform/OEM behavior separately from force-stop; eligible incoming calls alert once; otherwise caller ends truthfully and never rings forever. |
| APP-06 | P0 | Android Settings Force stop | Force-stop B from Android Settings; call it; then reopen B and call again. | No assumption of FCM delivery while force-stopped; A times out cleanly; fresh calls work after explicit reopen; old calls do not re-ring. |
| APP-07 | P1 | Device reboot and first unlock | Reboot B; test before first unlock, after unlock, and after opening Voiid. | Record OS eligibility at each step; no false answered state or stale ring; normal operation resumes once eligible. |
| APP-08 | P0 | Caller backgrounds while ringing | A calls and goes home; B answers. | Outgoing call remains controllable; media connects; returning to Voiid shows the active call once. |
| APP-09 | P0 | Caller locks while ringing | A places call then locks phone; B answers. | No setup loss caused solely by screen lock; native call controls and audio remain coherent. |
| APP-10 | P0 | Lock or background after connection | Connect voice then video; background/lock A and B separately; restore. | Voice continues where permitted; video capture respects background rules; foreground restores media without duplicate tracks. |
| APP-11 | P0 | Kill caller while ringing | A starts ringing B; terminate A's process. | B stops via termination signaling or bounded fallback; no indefinite ringing or later resurrection. |
| APP-12 | P0 | Kill receiver while ringing | Terminate B while it rings; leave A waiting. | A exits by remote outcome or cap; B's later restart does not show the old call as active. |
| APP-13 | P0 | Kill either side during call | Connect; terminate A, then repeat with B. | Survivor detects loss and ends within recovery bounds; restart has no ghost session or mic/camera ownership. |
| APP-14 | P1 | Android Doze and battery saver | Put B in Doze/battery saver; repeat incoming call and answer. | Record delivery/alert latency and OEM restrictions; permitted wake path connects; no duplicate foreground service. |
| APP-15 | P1 | iOS Low Power Mode | Enable Low Power Mode; test locked incoming and a connected call. | Call handling remains coherent; no duplicate ring, lost answer or stale screen. |
| APP-16 | P1 | Notification/full-screen access restricted | Disable Android incoming-call notification/full-screen capability individually; call B. | Allowed fallback remains usable; app does not claim an unavailable full-screen surface appeared; caller gets bounded outcome. |

## Weak networks, outages, handover and recovery

| ID | Priority | Scenario | Steps / setup | Expected on caller and receiver |
| --- | --- | --- | --- | --- |
| NET-01 | P0 | Different networks | A uses Wi-Fi and B cellular; then reverse. | Both audio and video connect through a usable direct or relay path; same-Wi-Fi success alone is insufficient. |
| NET-02 | P1 | Different carriers | Put A and B on different mobile carriers. | Usable media or bounded truthful failure; record selected candidate pair and relay usage. |
| NET-03 | P0 | Poor network on caller | Apply N1 to A before dialing; B remains N0. | A can cancel; call either connects with intelligible audio or fails explicitly; no fake Ringing before acknowledgment. |
| NET-04 | P0 | Poor network on receiver | Apply N1 to B before dialing. | Push, answer and media still reconcile; a slow answer never creates duplicate call state. |
| NET-05 | P0 | Poor networks on both | Apply N1 to both peers; place voice and video calls. | Graceful quality adaptation; controls stay usable; no crash or indefinite setup. |
| NET-06 | P1 | Very low bandwidth | Apply N2 during an established call for 60 seconds. | Audio is prioritized; video may reduce quality; no false success claim if media becomes unusable; recovery is visible. |
| NET-07 | P1 | High delay | Apply N3 to A, B and then both. | Measure conversational delay and control propagation; no repeated offers/calls or unstable timers. |
| NET-08 | P1 | High jitter and packet loss | Apply N4 to A, B and then both for 60 seconds. | Record audio gaps and video freezes; adaptation/recovery does not duplicate streams or mute controls. |
| NET-09 | P0 | Short full outage | Apply N5 for two seconds to either peer during a connected call; restore. | Transient recovery does not produce a new call or missed-call log; state returns from reconnecting to connected. |
| NET-10 | P0 | Long full outage | Apply N5 for 45 seconds during connection. | Recovery is bounded; when exhausted, show connection loss and release resources; no endless Reconnecting. |
| NET-11 | P0 | Caller offline before call | Put A offline; tap Call. | Prompt local setup failure/cancellable state; B is not falsely reported as ringing; no indefinite spinner. |
| NET-12 | P0 | Receiver offline before call | Put B offline; A calls. | A stays Calling until a real acknowledgment, then ends within a bound; reconnecting B must not ring an expired call. |
| NET-13 | P0 | Both offline before call | Put both offline; attempt a call; restore later. | No accidental delayed call after cancellation; a fresh explicit attempt works. |
| NET-14 | P0 | Network lost during ring API | Break A's connectivity while ring authorization is pending. | No unauthorized or abandoned offer sent later; local cancel remains final; retry uses a fresh call. |
| NET-15 | P0 | Network lost while receiver rings | Disconnect B after ringing starts; A cancels. | B stops locally by its cap even if hangup is lost; no stale ringing when connectivity returns. |
| NET-16 | P0 | Decline message lost | B taps Decline on N5; restore after several seconds. | B ends immediately; A ends on delivered decline or timeout; B never gets a missed-call banner for its explicit decline. |
| NET-17 | P0 | Answer message lost | B answers, then block its signaling before answer reaches A. | No permanent connecting state; recover once or fail; B's accepted attempt must not be labeled an ignored call. |
| NET-18 | P0 | Hangup message lost | Connect; block A's signaling; A ends; restore. | A releases locally immediately; B converges via restored end delivery or loss handling; old end cannot kill a later call. |
| NET-19 | P0 | Wi-Fi to cellular | Connect on Wi-Fi; walk out of range or disable Wi-Fi with mobile data enabled. | Same call survives if recovery succeeds; no re-ringing; route, mute and duration remain consistent. |
| NET-20 | P0 | Cellular to Wi-Fi | Connect on mobile data; join Wi-Fi mid-call. | Same call recovers; no one-way audio or duplicate video tracks. |
| NET-21 | P0 | Both peers switch networks | Switch both paths within one second during a connected call. | Concurrent recovery converges; bounded retries; no offer collision loop. |
| NET-22 | P1 | Repeated network switching | Alternate Wi-Fi/cellular five times, allowing recovery between switches. | Recovered calls receive a fresh retry budget; no accumulating timers, ringbacks or degraded routing. |
| NET-23 | P0 | Signaling socket drops; media stays up | Block only the signaling socket for 10 seconds while allowing media. | Media is not ended solely because signaling drops; socket reconnects; queued control messages reconcile safely. |
| NET-24 | P0 | Media blocked; signaling stays up | Block RTP/relay media but keep API/socket reachable. | No permanently healthy-looking silent call; reconnect or fail visibly; signaling alone does not prove media success. |
| NET-25 | P0 | UDP blocked | Apply N6; attempt calls across networks. | Configured TCP/TLS TURN fallback provides media; if unavailable, explicit bounded connection failure. |
| NET-26 | P0 | TURN unavailable | In staging, make relay credentials/server unavailable on a topology requiring relay. | No endless Connecting or false connected media; useful failure; later healthy attempt succeeds. |
| NET-27 | P1 | Captive portal or DNS failure | Join unauthenticated portal or break DNS; attempt call; restore valid internet. | Wi-Fi icon is not treated as connectivity proof; setup fails/cancels cleanly and fresh retry succeeds. |
| NET-28 | P1 | VPN/restrictive NAT | Use N7 on one peer; repeat connect and network switch. | No assumption of a direct route; working relay or bounded failure; no media leak to unrelated peers. |

## Audio, video and call controls

| ID | Priority | Scenario | Steps / setup | Expected on caller and receiver |
| --- | --- | --- | --- | --- |
| MED-01 | P0 | Mute either peer | Connect; A mutes/unmutes, then B; both speak. | Remote peer hears nothing from the muted mic; unmute restores audio; UI matches actual state. |
| MED-02 | P0 | Both muted | Mute both; unmute one and then the other. | Independent controls; reconnect/background never silently unmutes either user. |
| MED-03 | P0 | Earpiece and speaker | Switch earpiece/speaker repeatedly during voice/video call. | Audio follows selected route; no silence, feedback burst or stuck route after end. |
| MED-04 | P0 | Bluetooth before call | Connect headset before dialing/answering. | Mic and output use the intended available route; system and in-app route labels agree. |
| MED-05 | P0 | Bluetooth connect mid-call | Pair/connect headset during a call. | Route changes without ending call or losing microphone permanently. |
| MED-06 | P0 | Bluetooth disconnect mid-call | Disconnect or power off active headset. | Audio falls back to a usable route; user is not left in a silent connected call. |
| MED-07 | P1 | Wired headset insertion/removal | Insert and remove a supported wired headset mid-call. | Usable fallback; no persistent mute or wrong speaker state. |
| MED-08 | P1 | Volume and silent mode | Test minimum/normal volume and silent/vibrate on A and B separately. | Incoming alert respects OS settings; outgoing ringback follows call audio route; no ringtone leaks into connected media. |
| MED-09 | P0 | Camera off/on | During video, disable then enable A's camera; repeat B. | Remote sees camera-off state instead of a misleading live frame; audio continues; no capture while off. |
| MED-10 | P1 | Switch front/back camera | Switch cameras repeatedly during video. | Correct live remote image returns; no crash, inverted controls or extra capture session. |
| MED-11 | P0 | Microphone permission denied | Deny mic before outgoing call and before answering; test first-time prompt. | Clear permission outcome; no falsely working audio call; peer not left indefinitely ringing/connecting. |
| MED-12 | P0 | Camera permission denied | Deny camera for outgoing and incoming video. | Clear permission/fallback behavior; voice continuation only if supported and explicit; no claimed live video without capture. |
| MED-13 | P1 | Permissions changed in Settings | Change mic/camera access; return and attempt a fresh call. | No stale granted state; instructions reflect current permission; fresh call works after permission is restored. |
| MED-14 | P1 | Another app owns audio/camera | Use competing recording/camera activity; initiate or answer Voiid. | Resource acquisition failure is clear; no crash or permanent capture/audio lock. |
| MED-15 | P0 | Native cellular-call interruption | During Voiid, receive and handle a cellular call; return to Voiid. | System priority is respected; Voiid reflects hold/end policy; surviving call restores audio without crosstalk. |
| MED-16 | P1 | Minimize, PiP and restore | Minimize connected call; navigate app; restore via banner/PiP; end from available surface. | One active call; controls work from each surface; end removes all overlays. |

## Busy, call waiting and multiple devices

| ID | Priority | Scenario | Steps / setup | Expected on caller and receiver |
| --- | --- | --- | --- | --- |
| CON-01 | P0 | Third caller while B is ringing | A rings B; C calls B before first call connects. | C receives busy or another explicit bounded outcome; no unsupported second active session; first ring stays coherent. |
| CON-02 | P0 | Third caller while B connects | C calls B while A–B are Connecting. | No call-waiting swap into an unestablished call; current setup not corrupted. |
| CON-03 | P0 | Call waiting; decline second | Connect A–B; C calls B; B declines C. | A–B continues uninterrupted; C gets decline; B has no missed-call alert for deliberate decline. |
| CON-04 | P0 | Call waiting; ignore second | Connect A–B; C calls B; B does nothing. | Waiting call times out; first call continues; exactly one appropriate waiting-call history outcome. |
| CON-05 | P0 | Call waiting; accept second | Connect A–B; C calls B; B accepts using the offered swap/end action. | UI clearly follows implemented swap policy; old call ends or is held as advertised; no audio from A leaks into C's call. |
| CON-06 | P0 | Waiting caller cancels | C cancels while B views waiting controls. | Waiting entry disappears; A–B continues; stale Answer cannot join C later. |
| CON-07 | P0 | Crossed calls | A calls B while B calls A within about 100 milliseconds. | Glare resolution converges on one call; no mutual endless Busy/ringing or two media sessions. |
| CON-08 | P0 | Rapid repeated Call taps | A rapidly taps Call or starts it from two entry points. | Only one active attempt; no duplicate notification, ring API fan-out or media session. |
| CON-09 | P0 | Multiple receiver devices; answer one | Sign B into two supported devices; A calls; answer on one. | Other device stops alerting as answered elsewhere; it sends no hangup that ends the winner; no missed-call banner there. |
| CON-10 | P0 | Multiple receiver devices; decline one | Decline on one of B's ringing devices. | All sibling surfaces reconcile with the server's decline decision; no stale ringing or spurious missed notification. |
| CON-11 | P0 | Two receiver devices answer together | Answer the same call on B's two devices simultaneously. | One accepted winner according to server arbitration; loser exits safely; no shared mic/duplicate media to A. |
| CON-12 | P1 | Old device resumes after sibling answered | Keep one B device offline; answer on the other; reconnect the old device. | Buffered offer cannot re-ring an already resolved call or disconnect the live call. |

## Call history, notifications and cleanup

| ID | Priority | Scenario | Steps / setup | Expected on caller and receiver |
| --- | --- | --- | --- | --- |
| HIS-01 | P0 | Answered-call history | Complete a call; inspect A/B app history and system recents where enabled. | Correct direction, peer, type and answered outcome; duration excludes pre-answer ringing; one logical record per call ID. |
| HIS-02 | P0 | Missed incoming history | Ignore an incoming call; inspect B's history and notifications. | One missed entry/banner; correct peer/type; no positive connected duration. |
| HIS-03 | P0 | Declined-call history | Decline on B; inspect both histories and delayed notifications. | Distinguishable decline outcome; B is not later told it missed the declined call. |
| HIS-04 | P0 | Caller-cancel history | A cancels before answer; test before and after B has actually alerted. | A is not shown as having received a missed call; B has no answered record; missed behavior reflects whether it was alerted. |
| HIS-05 | P0 | Accepted but failed before media | B answers; prevent media until setup fails. | A/B reflect connection failure; B's explicit answer is not represented as ignoring the call. |
| HIS-06 | P0 | Failure after connected | Connect; exhaust network recovery. | Record an answered call with a truthful termination cause where supported; no missed-call notification. |
| HIS-07 | P0 | Duplicate delivery/history | Replay same call's push, offer and terminal signal in staging. | One incoming UI and one logical history row; no duplicate missed notification. |
| HIS-08 | P1 | History after restart | Complete answered, declined and missed attempts; restart app. | Outcomes persist; no active-call resurrection or duration reset. |
| HIS-09 | P1 | Missed-call notification tap/callback | Tap a missed notification and its callback action where available. | Correct peer/conversation; callback is a new call ID; dismissing banner never places a call. |
| HIS-10 | P0 | Resources after every end path | After cancel, decline, timeout, failure and normal end, inspect indicators/services. | No lingering mic/camera, ringtone, foreground call notification, PiP, wake lock, audio focus or timer. |

## Group calls and adding someone to a call

| ID | Priority | Scenario | Steps / setup | Expected on caller and receiver |
| --- | --- | --- | --- | --- |
| GRP-01 | P0 | Mixed-platform group voice | Join supported group call with iOS and Android members. | All authorized members hear each other; roster is consistent; no duplicate participants. |
| GRP-02 | P0 | Mixed-platform group video | Join mixed-platform video call; toggle mic/camera per participant. | Media/control state is per person; roster and tiles stay consistent. |
| GRP-03 | P0 | Escalate a live 1:1 call | Connect A–B; use Add someone to invite C; C accepts. | A/B migrate to conference coherently; C joins once; no permanently silent gap or duplicate audio. |
| GRP-04 | P0 | Invitee declines escalation | A adds C to A–B; C declines. | A/B remain in a coherent ongoing call; C is removed from invited roster and receives no false missed alert. |
| GRP-05 | P0 | Invitee does not answer | Invite C and wait for its ring cap. | C stops ringing; A/B call survives; roster no longer falsely claims C is connected. |
| GRP-06 | P0 | Conference invite answered before signaling | Delay conference state delivery; C answers system UI first. | Conference join uses its own path; no inappropriate 1:1 SDP-offer timeout kills the invite. |
| GRP-07 | P0 | Escalation fails during migration | Block token/room connection for A or B during transition. | No irreversible silent call; retain the old usable path until migration is committed or report bounded failure. |
| GRP-08 | P0 | Participant loses network | Disconnect one member, then restore. | Other members continue; reconnecting member returns once or exits cleanly; no duplicate tile/audio. |
| GRP-09 | P1 | Participant leaves | One member leaves an ongoing group/conference. | Remaining members follow intended room policy; departed participant releases resources and disappears from roster. |
| GRP-10 | P0 | Original caller leaves conference | After adding C, have original caller A leave. | Other authorized participants continue according to room policy; A's old 1:1 hangup cannot incorrectly kill the room. |
| GRP-11 | P0 | Ad-hoc conference capacity | Reach the current eight-participant ad-hoc limit; invite a ninth. | Limit includes existing participants as defined server-side; extra invitation is rejected clearly without disrupting the room. |
| GRP-12 | P0 | Stale/duplicate conference invitation | Deliver an invite twice and again after the invitee leaves or call ends. | No duplicate joining/ringing; revoked or ended membership cannot regain media from a stale invite. |
| GRP-13 | P0 | Conference permissions and identity | Add a person unknown to another participant; inspect roster and messaging actions. | Only authorized identity details are exposed; joining does not create contact or messaging permission. |
| GRP-14 | P0 | Conference key delivery/rotation failure | Delay or fail key delivery when joining/leaving in staging. | No unencrypted fallback; unauthorized/departed participants cannot receive subsequent media; clear failure for missing keys. |

## Signaling, server faults and authorization

| ID | Priority | Scenario | Steps / setup | Expected on caller and receiver |
| --- | --- | --- | --- | --- |
| SIG-01 | P0 | Ring grant before offer | Delay POST /calls/ring while observing first outbound offer. | Offer is sent only after authorization grant exists; no push-only ring followed by an unanswered missing offer. |
| SIG-02 | P0 | Push arrives before offer | Deliver ring push first; offer arrives several seconds later. | One incoming call; later offer attaches to same ID; early Answer is honored once. |
| SIG-03 | P0 | Offer arrives before push | Deliver offer first, then push for the same call. | No duplicate ring or second call screen; delayed push reconciles with active/ended state. |
| SIG-04 | P0 | Push arrives; offer never arrives | Drop the 1:1 offer permanently after push. | Thirty-second offer guard bounds the wait; no endless ringing/connecting; outcome reflects whether B answered. |
| SIG-05 | P0 | ICE candidates arrive before SDP | Reorder candidate and offer/answer delivery in staging. | Candidates buffer and apply once description exists; no crash or preventable connection failure. |
| SIG-06 | P0 | Duplicate/out-of-order terminal frames | Replay hangup, decline and busy frames before/after cleanup. | Idempotent handling; no contradictory resurrection; a different call ID remains unaffected. |
| SIG-07 | P0 | Ring API failure | Return 401/403/429/5xx or timeout from ring API. | Explicit setup outcome; cancellation stays responsive; no unauthorized offer or unlimited retry loop. |
| SIG-08 | P0 | Socket/Redis restart during ringing | Restart staging signaling service or expire buffered offer while B wakes. | Recover only valid live call state; expired calls do not re-ring; bounded setup failure if recovery is impossible. |
| SIG-09 | P0 | Peer has no eligible registered device | Call an account whose eligible device count is zero. | Unavailable/setup result; no false Ringing/ringback or claim that someone declined. |
| SIG-10 | P0 | Unauthorized peer/call ID | Attempt ring/signals/token fetch for a call or contact not authorized to the test account. | Server rejects it; unrelated user receives no call/media; existing authorized calls are unaffected. |
| SIG-11 | P1 | Stale push token | Invalidate a test device token; call; register a fresh token and retry. | No endless retry/ringing; fresh token restores eligible delivery; no duplicate device alert. |
| SIG-12 | P1 | Metrics/history API failure | Fail metrics/history-related requests during live call and teardown. | Best-effort reporting cannot interrupt media or prevent local cleanup/history persistence. |

## Repetition, accessibility and regression

| ID | Priority | Scenario | Steps / setup | Expected on caller and receiver |
| --- | --- | --- | --- | --- |
| SOAK-01 | P1 | Repeated short calls | Run 30 answer/end attempts per cross-platform direction. | Record success count and latency; no increasing failures, memory/resource retention or ringtone overlap. |
| SOAK-02 | P1 | Mixed-outcome repetition | Repeat answer, cancel, decline, no answer and failure in a randomized 30-call sequence. | Each new call is independent; all outcomes/history stay correct; no leaked timers. |
| SOAK-03 | P1 | Long voice call | Keep a voice call active for 30 minutes with route changes and one network switch. | No unexpected drop, growing latency or resource leak; measure battery/thermal impact. |
| SOAK-04 | P1 | Long video call | Keep a video call active for 20 minutes; background/restore and switch camera. | Graceful quality/thermal adaptation; no progressive freezing or camera lock after ending. |
| SOAK-05 | P1 | Accessibility and larger text | Use VoiceOver/TalkBack, large text and reduced motion on call controls. | Caller/status/Answer/Decline/End are understandable and reachable; no controls hidden by text or animation. |
| SOAK-06 | P1 | Release build without debugger | Repeat smoke suite on signed release/distribution builds with debugger detached. | Push, system UI and background behavior work for that distribution configuration; debug-only success is insufficient. |

## Run first: cross-platform smoke suite

Execute these in D1 and D2 first. Repeat applicable rows in both voice and video, with B foregrounded and locked. This is a fast gate; it does not replace the full matrix.

| Order | Cases | Covers |
| --- | --- | --- |
| 1 | BAS-01, BAS-02, BAS-03, BAS-04 | Answer and end from either phone |
| 2 | END-01, END-03 | Cut immediately and cut while ringing |
| 3 | END-05, END-06 | Decline in-app and from lock screen |
| 4 | END-08 | Do not answer; ring timeout |
| 5 | END-09, END-13 | Answer/cancel race and end during Connecting |
| 6 | APP-02, APP-03, APP-04 | Background, lock and terminated process |
| 7 | NET-01, NET-03, NET-04 | Cross-network and weak network on either phone |
| 8 | NET-09, NET-10, NET-19 | Brief outage, prolonged outage and Wi-Fi/mobile handover |
| 9 | NET-16, NET-17, NET-18 | Lost decline, answer and hangup |
| 10 | CON-03, CON-07 | Call waiting decline and crossed calls |
| 11 | MED-01, MED-06, HIS-10 | Mute, headset loss and resource cleanup |

## Result sheet template

Copy this block for each expanded run. All cases start **Not run**.

```text
Run ID:
Base case ID / priority:
Status: Not run / Pass / Fail / Blocked / Expected OS limitation
Tester / date / time zone:
iOS model, OS, app version/build:
Android model/OEM, OS, app version/build:
API/socket build and environment:
Caller A / receiver B / other test-account aliases:
Voice or video / direction:
App/process/lock state on each phone:
Permissions, DND/ringer, battery restrictions, debugger attached:
Network profile and affected peer/path:
Actual measured network conditions:
Call ID (internal correlation only):
Action timestamps: dial / first incoming alert / answer / first two-way media / end
Caller actual UI/audio/result:
Receiver actual UI/audio/result:
History outcome / direction / duration / duplicate count on both:
Notifications and mic/camera/audio-route cleanup:
Recovery duration / retry count / selected ICE candidate type:
Packet loss / jitter / RTT / bitrate / observed audio gaps or video freezes:
Expected versus actual:
Evidence / relevant sanitized logs:
Issue ID / severity / repeatability:
Retest build / result:
```

Record observations from both phones against the same call ID and synchronized clocks. Do not infer two-way audio from a connected timer or a video thumbnail. For poor-network runs, have each person read the same short numbered phrase and count words heard, audio gaps and recovery time; compare with N0. Report measurements rather than calling the network “good” or “bad” by feel alone.

## Release acceptance

- All applicable P0 expanded runs pass for each supported direction and mode. Blocked or unexecuted cases remain visible in the release report.
- Zero ghost calls, unlimited ringing/connecting, calls answered without user action, cross-call stale actions, or mic/camera capture continuing after end.
- No false missed-call banner after an explicit answer or decline. Caller and receiver outcomes describe the same attempt, with direction-specific wording where appropriate.
- Network recovery remains in the same call, or terminates with a truthful failure. A later retry is a new explicit call.
- Summarize attempts, connection success rate, setup time, terminal propagation, recovery time and drop rate by platform pair, media mode and profile. Include sample size; this matrix alone supplies no reliability percentage.

## Source references

- [iOS call lifecycle, guards, history and recovery](../apps/ios/Voiid/Voiid/Networking/CallService.swift)
- [iOS call screen and outcome text](../apps/ios/Voiid/Voiid/Main/CallScreens.swift)
- [iOS CallKit integration](../apps/ios/Voiid/Voiid/Networking/CallManager.swift)
- [iOS PushKit integration](../apps/ios/Voiid/Voiid/Networking/VoIPPushManager.swift)
- [Android call lifecycle, timeouts and outcome mapping](../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt)
- [Android call screen](../apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt)
- [Android incoming notification and foreground service](../apps/android/app/src/main/java/com/voiid/app/net/CallForegroundService.kt)
- [Signaling relay, offer buffer and sibling-device verdicts](../backend/websocket/src/index.ts)
- [Ring authorization and call APIs](../backend/api/src/routes/calls.ts)
- [Ad-hoc conference policy and size limit](../backend/api/src/callConference.ts)
- [Existing ring-grant regression test](../backend/api/test/callGrantRace.test.ts)
- [Existing conference regression tests](../backend/api/test/callConference.test.ts)
- [Existing metrics regression tests](../backend/api/test/callMetrics.test.ts)
- [Historical reliability plan](CALL_RELIABILITY.md)
- [Push/background provisioning checklist](KILLED_STATE_CALLS_CHECKLIST.md)
