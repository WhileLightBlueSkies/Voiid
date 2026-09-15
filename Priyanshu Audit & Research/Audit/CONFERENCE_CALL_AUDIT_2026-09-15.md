# Conference calls (adding someone to a 1:1 call): audit

> **Date:** 15 Sep 2026
> **Baseline:** `main` at `9fc79f3`
> **Scope:** adding a third person to a live 1:1 call on iOS and Android: invite, key exchange, move to the LiveKit room (SFU), answering, leaving, failure paths, and the backend and relay behind them.
> **Related:**
> - [CALLS_LOW_DATA_AUDIT_2026-09-15.md](CALLS_LOW_DATA_AUDIT_2026-09-15.md): four findings there also affect conferences. They are listed in §5 and not repeated.
> - [docs/CONFERENCE_LIFECYCLE_FIXES_2026-09-09.md](../../docs/CONFERENCE_LIFECYCLE_FIXES_2026-09-09.md): earlier fixes. Nothing below repeats them.

---

## Summary

The backend is consistent: all 51 conference and call-grant tests pass. The failures are in the apps, in how the two call engines, the encryption keys and the audio session hand over to each other. Five problems are enough on their own to make conferences fail on both platforms:

1. **iOS: LiveKit takes over the audio session inside a CallKit call.** The LiveKit SDK switches the audio category and deactivates the session by itself, and the app never turns that off. Expected symptoms: the original call loses its microphone while someone is being added, voice calls jump to loudspeaker, and a failed add silences the original call.
2. **Android as the adder: the original call goes silent.** The adder never switches its own original-call encryption to the new key, but the other person does. From then on neither side can decrypt the other, and if the add fails the call stays silent.
3. **Every key change drops audio.** The new key overwrites the only key slot, so frames under the old key fail until everyone has the new one. Android changes keys on every room join, leave or reconnect.
4. **The invitee often can't get the key in time.** Keys aren't stored for a phone that isn't connected yet, so a push-woken invitee depends on a second key change arriving within 8 seconds.
5. **An invitee with two devices gets removed.** The device that didn't answer eventually sends "leave" for the whole account, which removes the person from the call on the device they answered with.

The rest (§2) covers a stranded invitee after a failed add, the original peer missing the "move to the room" message, pickers offering people the server refuses, iOS allowing only one added person, forced loudspeaker, invites that never expire, and smaller issues.

### Evidence labels

| Label | Meaning |
|---|---|
| **Source** | Confirmed by reading the code at the cited lines |
| **SDK** | Confirmed in the LiveKit SDK sources this app builds against (Swift 2.15.2, Android 2.27.0, from the local build caches) |
| **Device** | The runtime symptom is predicted from source and must be confirmed on phones |
| **Verify** | Lives outside the repo (server env, LiveKit server) |

No device reproduction was possible: a conference needs three accounts on real phones. §6 lists the tests that tell which of these problems a failing call hit.

Severity: **P0** conference can't work or the original call breaks · **P1** fails in a common situation · **P2** functional gap or wrong behavior · **P3** cleanup.

---

## 1. How the flow works today

A = the person adding, B = the other person on the 1:1 call, C = the person being added.

| # | What happens | Code |
|---|---|---|
| 1 | A taps Add and picks C from their chats | iOS [CallScreens.swift:661-672](../../apps/ios/Voiid/Voiid/Main/CallScreens.swift#L661-L672), Android [CallScreens.kt:583-615](../../apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt#L583-L615) |
| 2 | A calls `POST /calls/:id/escalate`. Server adds A and B as `joined` and C as `invited`, rewrites the relay grant, pushes C | [calls.ts:1109-1228](../../backend/api/src/routes/calls.ts#L1109-L1228) |
| 3 | A creates a new call key and sends it to B and C as `call_key` frames. The relay does not store them | iOS [CallConference.swift:327](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L327), Android [CallConferenceService.kt:405](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L405) |
| 4 | A sends `call_migrate` to B and `call_invite` to C. The relay does not store them either | iOS [CallConference.swift:331-337](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L331-L337), Android [CallConferenceService.kt:416-418](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L416-L418) |
| 5 | A gets a room token and joins the LiveKit room **without** its mic; the 1:1 call still carries audio | iOS [CallConference.swift:346-397](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L346-L397), Android [CallConferenceService.kt:682-807](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L682-L807) |
| 6 | B gets `call_migrate`, waits for the key, gets a token, joins the room without mic | iOS [CallConference.swift:484-507](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L484-L507), Android [CallConferenceService.kt:434-467](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L434-L467) |
| 7 | When both A and B are in the room, the 1:1 call is closed with `call_hangup(reason: conference-migrated)` and the mics move to the room. Android: only A does this. iOS: A **and** B do it | iOS [CallConference.swift:404-455](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L404-L455), Android [CallConferenceService.kt:969-1011](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L969-L1011) |
| 8 | C answers: `POST /join`, sends `call_invite_accept` to A, waits up to 8 s for a key, joins the room with mic | iOS [CallConference.swift:584-637](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L584-L637), Android [CallConferenceService.kt:482-515](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L482-L515) |
| 9 | On each roster change the key coordinator creates a new key for everyone | iOS [CallConference.swift:726-801](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L726-L801), Android [CallConferenceService.kt:608-652](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L608-L652) |

---

## 2. Check these first (before changing code)

1. **Is LiveKit configured on the server that users hit?** If `LIVEKIT_URL`, `LIVEKIT_API_KEY` or `LIVEKIT_API_SECRET` is missing, escalate returns 503 ([calls.ts:1124-1130](../../backend/api/src/routes/calls.ts#L1124-L1130)). iOS then hides the feature and says "Conference calling isn't available on this server"; Android shows the same message. *Verify.*
2. **Can phones reach the LiveKit server on mobile data and on UDP-blocked Wi-Fi?** See LD-14 in the low-data audit. *Verify.*
3. **Collect logs from a failing attempt.** These lines show which step broke:

| Step | iOS log (`[VOIID]`) | Android log (`VOIID`) |
|---|---|---|
| Server refused | `escalate <id> failed: <status>` | `conference: escalate refused (<status>)` |
| No room token | `adhoc-token <id> failed` | `conference: adhoc token failed` |
| No key | `adhoc join refused for <id>: no call key` / `invitee <id>: no call key arrived` | `conference: no per-call secret for <id> — refusing to join unkeyed` |
| Key delivery | `call-key: fan-out to <user> failed` / `call-key: installed gen=` | `call key: fan-out failed` / `conference: media key applied (epoch=` |
| Handover | `escalation <id>: both originals on the SFU — dropping the 1:1 leg` | `conference: both original participants on the SFU — retiring the 1:1 leg` |
| Add abandoned | *(no log; the UI shows the abort message)* | `conference: escalation timed out — falling back to the 1:1 call` |
| Key mismatch on the 1:1 call | `call-key: commitment MISMATCH` | `call-key: commitment MISMATCH` |

---

## 3. Findings

| ID | Sev | Platform | Issue |
|---|---|---|---|
| [CF-01](#cf-01) | P0 | iOS | LiveKit manages the audio session by itself inside a CallKit call, next to a second WebRTC audio engine |
| [CF-02](#cf-02) | P0 | Android adder | Adder never switches its own original-call key, so the original call goes silent (permanently if the add fails) |
| [CF-03](#cf-03) | P1 | Both | Each key change overwrites the only key slot and drops audio; Android changes keys on every room join, leave or reconnect; two devices can create competing keys |
| [CF-04](#cf-04) | P1 | Both + relay | Invitee often can't get a key in time (keys not stored for offline phones) |
| [CF-05](#cf-05) | P1 | Both + server | An invitee's second device removes them from the call |
| [CF-06](#cf-06) | P1 | Both + server | A failed add strands the invitee; on iOS it also silences the original call |
| [CF-07](#cf-07) | P1 | Both + relay | The original peer misses `call_migrate` on a flaky connection, so the add fails |
| [CF-08](#cf-08) | P2 | iOS | iOS peer ignores the "migrated" hangup if its room isn't connected yet |
| [CF-09](#cf-09) | P2 | Server | A live 1:1 call can be marked "missed", which blocks adding anyone |
| [CF-10](#cf-10) | P2 | Both | The picker lists people the server will refuse |
| [CF-11](#cf-11) | P2 | iOS | iOS can add only one person; the platforms disagree on whether an invitee can add others |
| [CF-12](#cf-12) | P2 | iOS | Voice conferences switch to loudspeaker |
| [CF-13](#cf-13) | P2 | Server | Invites never expire: ghost "Ringing…", held seats, keys sent to absent people |
| [CF-14](#cf-14) | P3 | Android | Stuck "reconnecting" dot after the call becomes a conference |
| [CF-15](#cf-15) | P3 | Both | LiveKit key-provider settings differ between platforms |

---

<a id="cf-01"></a>
### CF-01 · P0 · iOS: LiveKit manages the audio session by itself inside a CallKit call

**Evidence:** Source + SDK. Runtime symptoms: Device.

**What the code does**
- **1:1 engine:** `CallService` builds its own WebRTC factory ([CallService.swift:176-181](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L176-L181)). CallKit owns its audio: manual audio mode, enabled only when CallKit activates the session ([CallManager.swift:65-67](../../apps/ios/Voiid/Voiid/Networking/CallManager.swift#L65-L67), [CallManager.swift:300-319](../../apps/ios/Voiid/Voiid/Networking/CallManager.swift#L300-L319)).
- **LiveKit room:** runs a second factory with its own audio engine. In Swift SDK 2.15.2, `RTC.swift` uses `admType = .audioEngine` (lines 30, 52-66).
- **LiveKit's automatic audio-session handling** is on by default: `AudioSessionEngineObserver.swift` lines 70-72 set `isAutomaticConfigurationEnabled = true`, `isAutomaticDeactivationEnabled = true` and `isSpeakerOutputPreferred = true`. Its `configureAudioSession` (lines 162-212):
  - with only playback running, sets the category to **`.playback`**
  - once the mic is on, sets `.playAndRecord` **with speaker preferred**
  - when LiveKit's audio stops, calls **`setActive(false, .notifyOthersOnDeactivation)`**
- **The app never turns this off.** Nothing in `apps/ios` references LiveKit's `AudioManager.shared`.
- **The app's own session setup:** `GroupCallService` also calls `setCategory`, `setActive(true)` and forces the speaker ([GroupCallService.swift:558-570](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L558-L570)).

**What goes wrong (Device)**
- **While adding:** A and B are in the room without mics, and the 1:1 call still carries their voices. Once C's audio reaches the room, LiveKit starts playback and switches the session to `.playback`, which has no microphone input. Expected: the original call's outgoing audio stops.
- **At handover:** LiveKit's mic starts and the session becomes play-and-record with loudspeaker preferred (also CF-12).
- **When the room closes** (failed add, leaving, call end): LiveKit deactivates the session. If the 1:1 call is still running (failed add), its audio dies (also CF-06).
- **Always:** two WebRTC audio engines drive one audio session, and only one owner (CallKit plus a single engine) is safe.

**Fix**
1. At app start, before any room is created, turn off LiveKit's automatic session handling: set `AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false` (the property exists, `AudioSessionEngineObserver.swift:33-35`), and turn off automatic deactivation too. CallKit plus `LKRTCAudioSession` become the only owner, as they already are for 1:1 calls.
2. Stop `GroupCallService.configureAudioSession` from calling `setActive` or `setCategory` while a CallKit call exists. Leave the category and mode as the 1:1 engine set them (`.playAndRecord` / `.voiceChat`). Change only the output route, and only on user request.
3. Make the handover order explicit: close the 1:1 connection and release its audio track first, **then** turn on LiveKit's mic (`finishMigration` then `adoptAudioSession`, [CallConference.swift:445-455](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L445-L455)). Log each step with a timestamp.
4. Test on a real iPhone with three accounts. If the two audio engines still conflict after 1–3, check whether the SDK exposes a public way to switch LiveKit to the classic audio engine used by the 1:1 path, rather than the default `.audioEngine`.

**Pass test:** iPhone A adds C while talking to B. B hears A the whole time, C's audio doesn't cut A's mic, a voice call stays on the earpiece after handover, and a failed add leaves A↔B talking.

---

<a id="cf-02"></a>
### CF-02 · P0 · Android adder: the original call goes silent

**Evidence:** Source.

**What the code does**
- **The adder** creates the new key and applies it only to the LiveKit room: `addPerson` → `mintAndFan` ([CallConferenceService.kt:405](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L405)) → `mintAndFanSerial` → `applySecret`, which only touches the LiveKit key provider ([CallConferenceService.kt:552-601](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L552-L601)). The 1:1 call's frame encryption on the adder keeps the old key.
- **The other person** (B) switches the 1:1 call to the new key as soon as it arrives:
  - iOS B: `install` re-keys the 1:1 frame key provider ([CallKeyExchange.swift:365-370](../../apps/ios/Voiid/Voiid/Networking/CallKeyExchange.swift#L365-L370))
  - Android B: `onCallKey` hands the key to the 1:1 engine ([CallConferenceService.kt:258-265](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L258-L265)) → `applyFrameSecret` ([CallService.kt:2088-2118](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2088-L2118))
- **Visible side effect:** B's verification tag for the new key reaches A, which still holds the old one, so A's call screen shows "commitment MISMATCH" ([CallService.kt:2025-2028](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2025-L2028)).

**What goes wrong.** From the moment B has the new key until the handover, A and B's frames are encrypted under different keys and are dropped, not played: silence both ways. If the add then fails (C declines, B can't reach the room, timeout), the app "falls back to the 1:1 call", which stays silent for good. This happens whenever an Android phone is the adder, whatever B's platform.

**Fix.** Keep the two keys separate:
- The **1:1 call keeps its original key** until it is closed. A conference key must never change the 1:1 frame encryption.
- In `CallKeyExchange.install` (iOS) and `onCallKey` / `onOneToOneCallKey` (Android), apply a key to the 1:1 frame encryption only if it belongs to the 1:1 call. Mark this inside the encrypted envelope (for example `scope: "p2p" | "room"`) rather than by call id, since both share the same call id.
- The room (LiveKit) uses the conference key from the start.

This removes the problem on both platforms, and a failed add then leaves the 1:1 call untouched.

**Pass test:** Android A adds C. A and B keep hearing each other while "Adding…" shows. C declines, and A and B still hear each other. The encryption badge stays verified.

---

<a id="cf-03"></a>
### CF-03 · P1 · Every key change drops audio; Android changes keys far too often

**Evidence:** Source; drop length: Device.

**What the code does**
- **Every key is written to slot 0**, replacing the previous key:
  - iOS 1:1 frame key ([CallKeyExchange.swift:168](../../apps/ios/Voiid/Voiid/Networking/CallKeyExchange.swift#L168), [CallKeyExchange.swift:368](../../apps/ios/Voiid/Voiid/Networking/CallKeyExchange.swift#L368))
  - iOS room key ([GroupCallService.swift:316](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L316))
  - Android room key ([CallConferenceService.kt:594](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L594))
  - Android 1:1 frame key ([CallService.kt:2115](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2115))
- **A code comment claims the opposite.** [CallKeyExchange.swift:361-364](../../apps/ios/Voiid/Voiid/Networking/CallKeyExchange.swift#L361-L364) says a frame under the previous key still decrypts. With one slot overwritten, frames sent under the other key fail until sender and receiver hold the same key.
- **Android changes keys on every LiveKit participant connect or disconnect**, including reconnects, with no check that the roster changed ([CallConferenceService.kt:854-861](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L854-L861) → [CallConferenceService.kt:608-618](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L608-L618)). iOS changes keys only when the server roster changes ([CallConference.swift:792-800](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L792-L800)).
- **Two devices can create keys at once.** Android `addPerson` creates one without checking whether this device is the key coordinator ([CallConferenceService.kt:403-405](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L403-L405)); iOS checks ([CallConference.swift:729](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L729)). Both sides eventually settle on the lower user id's key, but everyone drops audio until they do.
- **An iOS peer can join the room with the previous key.** `awaitCallKey` is satisfied immediately by the key from the 1:1 call ([CallConference.swift:512-520](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L512-L520)). The later key change fixes it, after a gap.

**What goes wrong.** Every key change gives each participant an audio gap about as long as key delivery takes: encrypt, relay, decrypt. That is short on good Wi-Fi and seconds on weak links. On Android, one person's network blip makes LiveKit report a disconnect and reconnect, which triggers two key changes and two gaps for everyone. Together with the 8 s key-failure timer on iOS (LD-16), repeated gaps can end the call.

**Fix**
1. **Change keys by slot, not by overwrite.** Put key version N in slot `N % 16`; both SDKs keep 16 slots, and each encrypted frame names its slot. Receivers add the new key the moment it arrives, keeping the old one. Senders switch to the new slot once every joined participant has confirmed receipt with a small `call_key_ack`, or after a 2 s grace period.
2. **Change keys only when the set of joined users changes** on the server roster. Never on LiveKit connect, disconnect or reconnect events. Wait 1–2 s to combine bursts.
3. **Only the elected coordinator creates keys**, on both platforms and in every code path, including Android `addPerson`.
4. A peer joining the room must wait for the conference key (the `scope: "room"` envelope from CF-02), not accept the 1:1 key.

**Pass test:** in a 4-person call, one phone drops Wi-Fi for 5 s and comes back, with no key change. A real join produces at most one blip under 300 ms.

---

<a id="cf-04"></a>
### CF-04 · P1 · The invitee often can't get a key in time

**Evidence:** Source.

**What the code does**
- **When the key is sent**, the invitee is usually asleep, waiting to be woken by push, with no socket.
- **The relay publishes `call_key` without storing it** ([index.ts:882-889](../../backend/websocket/src/index.ts#L882-L889)). It stores only offers and ICE candidates ([index.ts:898-923](../../backend/websocket/src/index.ts#L898-L923)).
- **iOS doesn't queue `call_key`** when its own socket is down ([WebSocketClient.swift:203-212](../../apps/ios/Voiid/Voiid/Networking/WebSocketClient.swift#L203-L212)).
- **The invitee waits 8 s** after joining ([CallConference.swift:615-622](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L615-L622), [CallConferenceService.kt:716-727](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L716-L727)). A key arrives in time only if the coordinator notices the join and creates a new key within 8 s:
  - through `call_invite_accept`, which goes only to the inviter ([CallConference.swift:599](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L599))
  - or through the 3 s roster poll
- **If the coordinator isn't the inviter** (someone else added this person, or the inviter left), only the poll can trigger it.
- **Sending to a person with no encryption session yet** first fetches their prekeys, adding a request.

**What goes wrong.** The invitee answers and then sees "Secure keys for this call didn't arrive" (iOS) or "Encryption keys for this call aren't ready yet" (Android). This is most likely when the invitee's phone was locked or the app was killed, which is the normal case for being added to a call.

**Fix**
1. **Store `call_key` copies on the relay** per recipient device for 60 s, as offers are, and deliver them when that device's socket connects. Each copy is one-time encrypted output; a duplicate delivery simply fails to decrypt a second time and is ignored.
2. **Add a `call_key_request` frame.** After `/join`, an invitee with no key sends it to every joined participant. Whoever holds the current key re-sends that same key version (iOS already has `redistribute`, [CallKeyExchange.swift:231-235](../../apps/ios/Voiid/Voiid/Networking/CallKeyExchange.swift#L231-L235)); no new key is needed.
3. **Have the server tell participants immediately.** On `/join` and `/leave`, publish a `call_roster_changed` frame to all live participants so the coordinator reacts at once instead of on the next poll. This also removes the need for 3 s polling (LD-19).

**Pass test:** C's phone is locked with the app killed. A adds C, and C answers from the lock screen. C hears A and B within 5 s on Wi-Fi.

---

<a id="cf-05"></a>
### CF-05 · P1 · An invitee's second device removes them from the call

**Evidence:** Source.

**What the code does**
- **The server's leave and decline act on the user, not the device.** `transitionConferenceParticipant(..., 'leave')` updates the row for `(call_id, user_id)` ([calls.ts:1319-1325](../../backend/api/src/routes/calls.ts#L1319-L1325)).
- **Nothing tells the other devices that the invite was answered.** Accept sends `call_invite_accept` to the inviter only. The relay sends "answered on another device" (`call_taken`) only for `call_answer`, `call_decline` and `call_busy` ([index.ts:945-981](../../backend/websocket/src/index.ts#L945-L981)).
- **The device that didn't answer keeps ringing.** When its ring limit ends, it "declines", which posts leave:
  - iOS `endActiveCall` → `declineInvite` → `POST /leave` ([CallService.swift:2317-2319](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2317-L2319), [CallConference.swift:648-654](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L648-L654))
  - Android `endInternal` → `ConferenceManager.declineInvite` ([CallService.kt:2233-2235](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2233-L2235), [CallConferenceService.kt:521-530](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L521-L530))

**What goes wrong.** C has an iPhone and an Android tablet. C answers on the iPhone; the tablet keeps ringing for 45 s, then posts leave. The server marks C `left`, the relay grant drops C, the next key change leaves C out, and C's audio stops mid-conversation.

**Fix**
1. **Server:** store the answering `device_id` on `/join` (already written, [calls.ts:1310-1315](../../backend/api/src/routes/calls.ts#L1310-L1315)). A `/leave` from a different device while the user is `joined` becomes a no-op returning 200. A decline changes the row only while its state is still `invited`.
2. **Server and relay:** when `/join` succeeds, publish `call_taken { reason: "answer", winner_device_id }` to the user's own channel, and store it like the existing `call:taken:<user>` entries, so other devices stop ringing on connect.
3. **Clients:** a ring that ends because another device answered must not call `/leave` (iOS `handleCallTakenElsewhere`, Android `onCallTakenElsewhere`: route conference invites through them).

**Pass test:** C is signed in on two devices and answers on one. The other stops ringing within 2 s, and C is still in the call 2 minutes later.

---

<a id="cf-06"></a>
### CF-06 · P1 · A failed add strands the invitee and (iOS) silences the original call

**Evidence:** Source.

**What the code does**
- **iOS abort runs in the wrong order.** `abortEscalation` starts `leaveAdhoc` in a `Task`, then immediately calls `cancelMigration` ([CallConference.swift:459-470](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L459-L470)). By the time the room teardown runs, `migratingCallId` is already nil, so it calls `deactivateAudioSession()` ([GroupCallService.swift:498-500](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L498-L500)) under the still-running 1:1 call. LiveKit's automatic deactivation (CF-01) does the same.
- **Nobody tells the invitee or the server.** iOS doesn't post leave on abort. Android's `fail(keepCall = true)` skips it on purpose ([CallConferenceService.kt:1196-1212](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L1196-L1212)): if A and B posted leave, the call would end ([calls.ts:1333-1347](../../backend/api/src/routes/calls.ts#L1333-L1347)) and the relay grant A↔B still need would be deleted ([calls.ts:1037-1039](../../backend/api/src/routes/calls.ts#L1037-L1039)).
- **The platforms give up at different times.** iOS stops waiting for the handover after 20 s ([CallConference.swift:215](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L215)), Android after 30 s ([CallConferenceService.kt:173](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L173)). In mixed calls one side quits while the other is still joining.

**What goes wrong**
- C has answered and sits in the room hearing nobody; the roster still says A and B are there.
- On iOS, A (or B) loses audio on the call they were told was "still connected".

**Fix**
1. **iOS:** call `cancelMigration` only after `leaveAdhoc` has finished, or pass "keep the audio session" into teardown explicitly. With CF-01 fixed, LiveKit won't deactivate the session either.
2. **New endpoint `POST /calls/:id/abort-escalation`,** allowed for the original two participants. It marks every other participant `left`, keeps the call `connected`, and writes back a 1:1 relay grant (`encodeOneToOneCallGrant`, which restores device claims).
3. **New `call_invite_cancel` frame** to each invitee, stored like offers. Invitee apps end with "Couldn't add you to the call".
4. **One shared handover timeout** (for example 30 s) and one rule for who closes the 1:1 call: the adder does it, and the peer follows the "migrated" hangup. Same on both platforms.

**Pass test:** block the LiveKit host on B's network. A's add fails; A and B keep talking; C sees "couldn't add you"; the server roster shows only A and B.

---

<a id="cf-07"></a>
### CF-07 · P1 · The original peer misses `call_migrate` on a flaky connection

**Evidence:** Source.

**What the code does**
- **The relay publishes `call_migrate` without storing it** ([index.ts:886-889](../../backend/websocket/src/index.ts#L886-L889)).
- **The peer enters the conference only from that frame:** Android [CallConferenceService.kt:434-467](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L434-L467), iOS [CallConference.swift:484-507](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L484-L507).
- **A code comment promises a fallback that doesn't exist.** It says the peer can re-derive the migrate from the roster ([CallConferenceService.kt:413-415](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L413-L415)), but nothing does.

**What goes wrong.** If B's socket is reconnecting when A adds someone (common on mobile), B never joins the room. A waits 20–30 s, then gives up (CF-06).

**Fix**
1. Store `call_migrate` for the recipient for 60 s, like offers, and deliver it on connect.
2. Have `/calls/:id/escalate` publish a server-side `call_escalated { call_id, room }` frame to the other original participant, so B learns about the add even if A's frame was lost.
3. When a client's socket reconnects during a 1:1 call, it fetches `GET /calls/:id/participants` once. If the call has become a conference, it follows the migrate path.

---

<a id="cf-08"></a>
### CF-08 · P2 · iOS peer ignores the "migrated" hangup if its room isn't connected yet

**Evidence:** Source.

**What the code does**
- **iOS** returns early for a `conference-migrated` hangup ([CallService.swift:410-416](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L410-L416)). `completeRemoteHandover` does nothing unless the room is already connected ([CallConference.swift:473-478](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L473-L478)), so the hangup is dropped.
- **Android** remembers the request and applies it once connected (`peerRetirementRequested`, [CallConferenceService.kt:994-1003](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L994-L1003), [CallConferenceService.kt:806](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L806)).

**What goes wrong.** If the iOS peer's room connection then fails, the other side has already closed the 1:1 call. The iOS peer is left on a dead 1:1 call: ICE fails, restarts toward a closed peer, then the call drops with "Connection lost".

**Fix.** Record the migrated hangup as Android does and apply it when the room connects. If the room fails after the other side closed the 1:1 call, end the call cleanly instead of trying to reconnect.

---

<a id="cf-09"></a>
### CF-09 · P2 · A live 1:1 call can be marked "missed", which blocks adding anyone

**Evidence:** Source.

**What the code does**
- **The sweeper:** every 15 s ([api index.ts:385-393](../../backend/api/src/index.ts#L385-L393)), it marks any direct call still `ringing`, with no `answered_at`, older than 75 s as `missed` ([missedCallNotifications.ts:7-19](../../backend/api/src/missedCallNotifications.ts#L7-L19)).
- **How `answered_at` gets set:** only by `POST /calls/:id/status connected` ([calls.ts:726-735](../../backend/api/src/routes/calls.ts#L726-L735)). Both apps send it once, with no retry ([CallService.swift:2512-2516](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2512-L2516), [CallService.kt:1938-1940](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L1938-L1940)).
- **The effect on adding:** once marked, escalate returns 409 ([calls.ts:1134-1138](../../backend/api/src/routes/calls.ts#L1134-L1138)), and the app shows "That call is no longer live" ([CallConference.swift:832-834](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L832-L834)).

**What goes wrong.** If both phones' "connected" requests are lost (a weak network at connect time), then 75 s into a working call the server marks it missed. Nobody can add anyone, and the callee's Android devices get a false missed-call notification.

**Fix**
- Retry the `connected` status with backoff until it succeeds.
- Make the sweeper skip calls the relay knows were answered: the relay already records an `answer` result in `call:device:<call>:<user>` in Redis ([callSignaling.ts:26-45](../../backend/websocket/src/callSignaling.ts#L26-L45)).

---

<a id="cf-10"></a>
### CF-10 · P2 · The picker lists people the server will refuse

**Evidence:** Source.

**What the code does**
- **What the pickers list:** every direct chat except the current peer and self ([ConferenceViews.swift:42-51](../../apps/ios/Voiid/Voiid/Main/ConferenceViews.swift#L42-L51), [ConferenceViews.kt:81-83](../../apps/android/app/src/main/java/com/voiid/app/main/ConferenceViews.kt#L81-L83)).
- **What the chat list contains:** it requires only **my** side to have accepted the chat ([conversations.ts:236-241](../../backend/api/src/routes/conversations.ts#L236-L241)), and doesn't remove blocked users.
- **What escalate requires:** **both** sides accepted, or mutual contacts, and no block ([calls.ts:826-848](../../backend/api/src/routes/calls.ts#L826-L848)).
- The chat models carry neither state, so the pickers can't filter.

**What goes wrong.** Picking someone who hasn't accepted your message request, or someone blocked in either direction, fails with "You can't add this person to a call."

**Fix.** Add `GET /calls/:id/invitable`, which runs the same `canReachForCall` test and excludes people already on the roster, and use it to build the picker. Also hide the picker when the call is full (8).

---

<a id="cf-11"></a>
### CF-11 · P2 · iOS can add only one person; platforms disagree on who can add

**Evidence:** Source.

**What the code does**
- **iOS:** the Add button exists only on the 1:1 call screen ([CallScreens.swift:661-672](../../apps/ios/Voiid/Voiid/Main/CallScreens.swift#L661-L672)). After handover the app shows `GroupCallScreen` ([CallScreens.swift:226-233](../../apps/ios/Voiid/Voiid/Main/CallScreens.swift#L226-L233)), which has no add control, although `escalate()` supports adding more ([CallConference.swift:284](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L284), [CallConference.swift:339](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L339)).
- **Android** offers Add during a conference ([CallScreens.kt:583-585](../../apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt#L583-L585)).
- **Invitees:** an iOS invitee can never add (`canEscalate` requires `!isConferenceInvite`, [CallConference.swift:183-187](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L183-L187)). An Android invitee can.
- **Server:** allows any joined participant to add ([calls.ts:933-938](../../backend/api/src/routes/calls.ts#L933-L938)).

**Fix.** Put the Add control on the iOS conference screen. Decide once whether invitees may add others, and apply that rule on both platforms (and on the server if the answer is no).

---

<a id="cf-12"></a>
### CF-12 · P2 · iOS voice conferences switch to loudspeaker

**Evidence:** Source + SDK.

**What the code does**
- **App:** `GroupCallService.speakerOn` defaults to `true` ([GroupCallService.swift:95](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L95)), and `configureAudioSession` forces the speaker ([GroupCallService.swift:558-570](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L558-L570)). That runs when an invitee joins and at handover.
- **SDK:** LiveKit also prefers the speaker by default (CF-01).
- **Android** fixed the same bug on 11 Sep ([docs/ANDROID_CONFERENCE_AUDIO_ROUTE_2026-09-11.md](../../docs/ANDROID_CONFERENCE_AUDIO_ROUTE_2026-09-11.md)).

**Fix.** Carry the 1:1 call's route into the conference (`CallService.currentRoute`). Default voice to earpiece and video to speaker. Keep Bluetooth and wired headsets as they are.

---

<a id="cf-13"></a>
### CF-13 · P2 · Invites never expire

**Evidence:** Source.

**What the code does**
- **When an invite is cleared:** an `invited` row leaves that state only when the invitee's own app posts leave, or when the last joined person leaves ([calls.ts:1333-1347](../../backend/api/src/routes/calls.ts#L1333-L1347)).
- **What an uncleared invite still counts for:**
  - the roster (shown as "Ringing…")
  - the 8-person limit ([calls.ts:959-973](../../backend/api/src/routes/calls.ts#L959-L973))
  - key fan-out ([CallConference.swift:747-757](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L747-L757), [CallConferenceService.kt:558](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L558))

**What goes wrong.** If C's phone never got the push, or was off, C shows "Ringing…" for the whole call, holds a seat, and every key change is encrypted and sent to C for nothing.

**Fix.** Treat an invite as expired 60 s after `state_changed_at`. Filter expired invites out of roster, seat-count and grant queries (`state = 'invited' and state_changed_at > now() - interval '60 seconds'`), and mark them `declined` in a periodic sweep. Clients skip expired invitees when sending keys.

---

<a id="cf-14"></a>
### CF-14 · P3 · Android: stuck "reconnecting" dot after the call becomes a conference

**Evidence:** Source.

**What the code does.** After handover the 1:1 connection is released, but its network monitor keeps running. On any network change, `requestIceRestart` marks the call as reconnecting because the 1:1 connection no longer exists ([CallService.kt:2373-2383](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2373-L2383)). Nothing clears the flag, because clearing it needs a live connection ([CallService.kt:2386-2400](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2386-L2400)). The pulsing dot reads that flag ([CallScreens.kt:540](../../apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt#L540)).

**Fix.** Stop the 1:1 network monitor and stats collector in `retire1to1LegForConference` ([CallService.kt:643-658](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L643-L658)), and return early from `requestIceRestart` when there is no connection.

---

<a id="cf-15"></a>
### CF-15 · P3 · LiveKit key-provider settings differ between platforms

**Evidence:** SDK.

**What the SDKs do.** The app passes default key-provider settings on both platforms ([GroupCallService.swift:306](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L306), [CallConferenceService.kt:754](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L754)), and the defaults differ: the ratchet window is **0** on iOS (`KeyProvider.swift:24`) and **16** on Android (`E2EEOptions.kt:24`). The salt, magic bytes and passphrase encoding match, so both sides derive the same key; the difference only changes how each side retries a frame it fails to decrypt.

**Fix.** Pass explicit, identical settings on both platforms: ratchet window 0 (the app changes keys itself), 16 key slots, failure tolerance -1.

---

## 4. Implementation order

| Phase | Goal | Findings |
|---|---|---|
| 1 | Make conferences work at all | CF-01, CF-02, CF-04, CF-05, CF-06 |
| 2 | Make them reliable | CF-03, CF-07, CF-08, CF-09, CF-13, plus LD-16 and LD-19 from the low-data audit |
| 3 | Complete and polish | CF-10, CF-11, CF-12, CF-14, CF-15, plus LD-15 |
| Server check | Before any of the above | §2 items 1–2 (LiveKit configured and reachable; LD-14) |

---

## 5. Already covered in the low-data audit (not repeated)

| Low-data finding | How it affects conferences |
|---|---|
| **LD-14** TURN, SFU and API placement | One LiveKit box whose config isn't in the repo; if TCP/TLS-443 fallback is off, conferences fail on UDP-blocked networks |
| **LD-15** Group calls publish with SDK defaults | Conference rooms use the same defaults ([CallConferenceService.kt:769](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L769), [GroupCallService.swift:302-307](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L302-L307)) |
| **LD-16** Join and key deadlines too tight | 35 s join limit, Android's 8 s key wait, and iOS's 8 s key-failure teardown all apply to conferences |
| **LD-19** HTTPS polling during calls | Conference roster polled every 3 s on both platforms |

---

## 6. Device tests

**Setup.** Three accounts on real phones. Run every row with the adder, peer and invitee on each of these platform mixes (A / B / C):
- iOS / iOS / iOS
- Android / Android / Android
- iOS / Android / Android
- Android / iOS / iOS

Capture the §2 logs from all three phones.

| # | Scenario | Pass when |
|---|---|---|
| 1 | Voice call, A adds C while A and B talk | A↔B never silent for more than 0.5 s; C hears both within 5 s of answering; earpiece kept (CF-01, CF-02, CF-12) |
| 2 | Add done by the original caller, then by the original callee | Same as 1 both ways |
| 3 | C's phone locked and app killed; C answers from lock screen | C hears A and B within 5 s on Wi-Fi (CF-04) |
| 4 | C declines; C ignores the ring | A↔B unaffected; C's tile shows declined or no answer; seat freed within 60 s (CF-06, CF-13) |
| 5 | C signed in on two devices, answers on one | Other device stops ringing within 2 s; C still in the call after 2 min (CF-05) |
| 6 | LiveKit host blocked on B's network | Add fails cleanly within 30 s; A↔B keep talking; C told; roster shows only A and B (CF-06) |
| 7 | B's socket reconnecting at the moment A adds C | B still joins the room (CF-07) |
| 8 | Add a second and third person, from each platform | Works on both; everyone hears everyone (CF-11) |
| 9 | One participant drops Wi-Fi for 5 s and returns | No key change; others hear no gap longer than 1 s (CF-03) |
| 10 | Original adder leaves | Others keep talking; exactly one key change; audio back within 1 s |
| 11 | Video conference: flip camera, mute, unmute | Tiles and mute states correct on all three phones |
| 12 | Encryption badge during and after an add | Never shows "mismatch" (CF-02) |
| 13 | Long 1:1 call on a weak network, then add someone after 2 min | Add works; no false missed call (CF-09) |
| 14 | Picker contents | Only people the server accepts are listed (CF-10) |

---

## 7. What this audit checked

**Read line by line**
- **iOS:** `CallConference.swift`, `CallKeyExchange.swift`, `GroupCallService.swift`, `CallService.swift` (earlier today), `WebSocketClient.swift`, `VoIPPushManager.swift`, `ConferenceViews.swift` (picker)
- **Android:** `CallConferenceService.kt`, `CallConference.kt`, `CallService.kt`, `WebSocketClient.kt`
- **Backend:** `routes/calls.ts` (status, escalate, adhoc-token, join, leave, participants and their helpers), `callConference.ts`, `common-utils/callGrant.ts`, `websocket/src/callSignaling.ts`, the relay's call section and connect-time delivery in `websocket/src/index.ts`, `missedCallNotifications.ts`, migrations `031` and `038`
- **Docs:** `docs/research/02_conference_1to1.md` and the three conference fix docs from 9 and 11 Sep

**Read the relevant parts:** the conference paths in iOS `CallManager.swift` and `CallScreens.swift`, Android `CallScreens.kt` and `ConferenceViews.kt`, and the conversation list query in `routes/conversations.ts`.

**SDK checks:** LiveKit Swift 2.15.2 (`AudioSessionEngineObserver.swift`, `RTC.swift`, `E2EE/KeyProvider.swift`, `E2EE/Options.swift`) and LiveKit Android 2.27.0 sources (`e2ee/E2EEOptions.kt`, `e2ee/KeyProvider.kt`).

**Ran:** backend tests `callConference`, `conferenceRelayFrames`, `conferenceInvitePush` and `callGrantRace`: 51 passed, 0 failed. `conferenceCapPostgres` and `callLifecyclePostgres` need a test database and were not run.

**Not done:** device calls, network impairment, reading the production env or the LiveKit server config.
