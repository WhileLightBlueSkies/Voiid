# FCM / VoIP Call Delivery and Connection — Research

Topic: an incoming call not ringing / not connecting when the app is backgrounded or
killed. Android primarily, iOS readiness too. All claims cite actual code; hypotheses
are marked as such.

Related prior docs: `docs/CALL_RELIABILITY.md`, `docs/KILLED_STATE_CALLS_CHECKLIST.md`
(both predate parts of the code below; the checklist's "Layer 2 fixed" claim is
verified true in code, see §1.3).

---

## 1. What exists today

### 1.1 Backend ring path

`POST /calls/ring` (backend/api/src/routes/calls.ts:40-112) persists a `calls` row and
selects the callee's devices:

- iOS devices with a `voip_token` get a PushKit VoIP push **only when the server has a
  VoIP APNs key** (`voipConfigured()` gate, calls.ts:95-102 → `sendVoipPush`,
  backend/api/src/push.ts:344-365).
- Everything else falls back to `sendWakePush` (calls.ts:105): FCM data-only
  high-priority for Android (push.ts:134-173), APNs alert push with
  `mutable-content: 1` for iOS (push.ts:236-289).

Payloads are content-free routing ids only (`call_id`, `call_kind`, `caller_id`,
`conversation_id`) built in backend/api/src/pushPayload.ts:75-147 and enforced by the
`ALLOWED_PUSH_KEYS` allowlist (pushPayload.ts:44-59) with tests
(backend/api/test/pushPayload.test.ts). VoIP pushes correctly use
`apns-push-type: voip`, the `<bundle-id>.voip` topic, priority 10, and a 30s expiry
(pushPayload.ts:184-200, `VOIP_TTL_SECONDS` at pushPayload.ts:26).

Dead tokens are cleared on APNs 410/`Unregistered`/`BadDeviceToken` and FCM
`registration-token-not-registered` / `invalid-registration-token`
(push.ts:157-169, 264-279, 397-412).

`POST /calls/group/ring` (calls.ts:213-253) fans a `type: "group_call"` **wake** push
(deliberately not VoIP) to every other member's devices that have a `push_token`
(calls.ts:233-238).

### 1.2 Backend signaling relay

Call signaling (offer/answer/ice/hangup/decline/busy/ringing/hold) rides the WebSocket
relay over Redis pub/sub, sender-stamped server-side
(backend/websocket/src/index.ts:407-505). Three buffers compensate for pub/sub having
no persistence:

- `call_offer` is parked in a per-user Redis hash for `OFFER_BUFFER_TTL` (60s default)
  and flushed — without draining, so multiple devices each get it — every time a
  socket attaches (index.ts:30-38, 120-140, 194-199, 444-448). It is deleted when the
  call resolves (index.ts:449-465).
- `call_taken` verdicts are parked the same way so a push-woken sibling device cancels
  its ring instead of posting a false missed call (index.ts:479-501, 148-159).
- Only `call_offer` is buffered — **`call_ice` is not** (see §2.5).

### 1.3 Android incoming path

`VoiidMessagingService.onMessageReceived` handles `type == "call"`
(apps/android/app/src/main/java/com/voiid/app/net/VoiidMessagingService.kt:61-83):
resolves the caller's display name on-device (`runBlocking` with a 6s network
fallback, VoiidMessagingService.kt:73-80), then `CallManager.onRingPush(...)`.

`CallManager.onRingPush` (apps/android/.../net/CallService.kt:373-399) raises
`RINGING_IN` state, records a "missed" history row up front, calls
`raiseIncomingAlert` (Telecom first via `TelecomBridge.reportIncoming`, with a 2.5s
watchdog that rings in-app if Telecom never binds a Connection, CallService.kt:415-439)
and `announceRinging` (sends `call_ringing` over the WS, CallService.kt:447-449).

The ring surface is a full-screen-intent notification on an `IMPORTANCE_HIGH` channel
with DND bypass (apps/android/.../net/CallForegroundService.kt:177-206, 288-300);
Telecom-owned calls post the same notification from
`VoiidConnection.onShowIncomingCallUi` (apps/android/.../net/VoiidConnection.kt:57-59).
Accept/Decline are `PendingIntent.getBroadcast` actions into `CallActionReceiver`
(CallForegroundService.kt:249-255, 305-340).

The manifest declares `USE_FULL_SCREEN_INTENT`, `FOREGROUND_SERVICE_MICROPHONE/CAMERA`,
`MANAGE_OWN_CALLS`, `FOREGROUND_SERVICE_PHONE_CALL`
(apps/android/app/src/main/AndroidManifest.xml:24-53); targetSdk = 36
(apps/android/app/build.gradle.kts:19).

The WebSocket client parks outbound signaling frames in a bounded FIFO outbox while
the socket is down and flushes on reconnect (apps/android/.../net/WebSocketClient.kt:59-74,
158-190); reconnect backoff caps at 5s during a call, 30s idle (WebSocketClient.kt:196-209).
`WebSocketClient.connect()` is only *explicitly* called from the chats screen
(`Stores.loadConversations` → `ws.reconnect()`, apps/android/.../model/Stores.kt:187-193)
— see §2.4 for what happens on a push cold start.

FCM token registration: `onNewToken` → `E2EManager.registerPushToken`
(VoiidMessagingService.kt:47-54), on-login fetch in ChatsHomeView
(apps/android/.../main/ChatsHomeView.kt:143-148), attached to `devices/register` as
`push_token`/`push_provider: "fcm"` (apps/android/.../net/E2EManager.kt:178, 192-196).

### 1.4 iOS incoming path

`VoIPPushManager` owns `PKPushRegistry`, persists the token, uploads it to
`POST /devices/voip-token` with retry (apps/ios/Voiid/Voiid/Networking/VoIPPushManager.swift:54-91;
backend column: database/migrations/015_device_voip_token.sql). On
`didReceiveIncomingPushWith` it synchronously (main-queue registry +
`MainActor.assumeIsolated`) hands off to
`CallService.reportIncomingCallFromVoIPPush` (VoIPPushManager.swift:125-152), which:

- tolerates duplicate pushes / WS-offer-first (CallService.swift:846-848),
- reports call-waiting properly instead of report-and-kill (CallService.swift:854-865),
- schedules a missed-call backstop *before* the CallKit report so it survives jetsam
  (CallService.swift:880-886, 908-920),
- reports to CallKit and calls PushKit's `completion` from the report callback
  (CallService.swift:888-895),
- explicitly reconnects the WebSocket so the buffered offer can arrive
  (CallService.swift:901-903), with a 30s offer timeout and 45s ring cap
  (CallService.swift:173-186, 904-905).

`UIBackgroundModes` includes `voip` (apps/ios/Voiid/Voiid/Info.plist:43-45).

This is structurally the same shape as Signal-iOS (`PushRegistrationManager.swift:146+`
— "This branch MUST start a CallKit call before it returns", line 157 comment).

---

## 2. What is broken or weak

### 2.1 CRITICAL (iOS): the APNs *alert* token is never uploaded — the documented fallback ring path cannot exist

`didRegisterForRemoteNotificationsWithDeviceToken` hands the APNs token to Firebase
Auth **only** (apps/ios/Voiid/Voiid/VoiidApp.swift:121-127). The device-registration
body has no `push_token`/`push_provider` fields at all
(apps/ios/Voiid/Voiid/Networking/E2EManager.swift:220-224, 233-244), and a repo-wide
search finds no other upload. So for every iOS device, `devices.push_token` is NULL.

Consequences, all real today:

- calls.ts:66-69's own comment promises "iOS without a PushKit token, or a deployment
  with no VoIP APNs key configured, falls back to the existing alert/data wake push" —
  but the fallback selects `push_token is not null` (calls.ts:76-79, 99-101), which no
  iOS device satisfies. **If `voipConfigured()` is false, or a device's `voip_token`
  was cleared as dead (push.ts:116-122), iOS gets no ring signal of any kind.**
- Group calls: `POST /calls/group/ring` selects `push_token` only (calls.ts:233-238),
  so a backgrounded/killed iOS device **never learns a group call started**. The whole
  "join" notification path (buildApnsAlertPayload's `'Group call · tap to join'`,
  pushPayload.ts:115) is dead code for iOS.
- (Out of this topic's scope but same root cause: the NSE message push path
  push.ts:226-289 also has no iOS recipients.)

### 2.2 CRITICAL (backend/Android): ring pushes carry a 28-DAY TTL

`wakeTtlSeconds` special-cases only `story` (pushPayload.ts:65-68); `type: 'call'` and
`'group_call'` fall through to `OFFLINE_TTL_MS` = 28 days. That TTL is applied to the
FCM ring push (push.ts:155) and to the APNs alert-fallback ring
(pushPayload.ts:163-176). The VoIP path already gets this right with a 30s expiry and
documents exactly why (pushPayload.ts:21-26: a device resumed "to ring a long-dead
call").

Failure: callee's Android phone is off/out of coverage during the ring. Hours or days
later it reconnects, FCM delivers the held `type: "call"` data message,
`onMessageReceived` runs the full ring path (VoiidMessagingService.kt:61-83) and the
phone rings a full-screen incoming call for a call that ended long ago. The 60s
offer-buffer TTL (websocket index.ts:30) means accept then hangs on "Connecting" until
the 30s offer timeout equivalent on Android (none exists — the ring notification just
sits there until manually declined; `startOfferTimeout` exists only on iOS,
CallService.swift:904).

### 2.3 CRITICAL (Android 12+): Accept from the notification is a blocked notification trampoline — call answers with no UI

`CallActionReceiver.onReceive(ACTION_ACCEPT)` calls `context.startActivity(...)` from a
BroadcastReceiver reached via a notification action
(CallForegroundService.kt:309-317; same for `ACTION_WAITING_ACCEPT` at 323-330).
Since Android 12, apps targeting SDK 31+ (this app targets 36,
apps/android/app/build.gradle.kts:19) **cannot start an activity from a
receiver/service in response to a notification tap** — the start is silently dropped
with a "notification trampoline" log. `CallManager.accept()` still runs, so:

- Voice call: answers, audio connects, but the user is left on the lock screen /
  notification shade with no in-call surface (no mute/hangup/speaker UI until they
  manually open the app).
- Video call: answers but the call screen (and camera preview / renderer attach,
  CallService.kt:1085-1103) never composes; the callee streams nothing and sees
  nothing.

The Telecom path has the same shape: `VoiidConnection.answer()` calls
`appContext.startActivity` from a binder callback (VoiidConnection.kt:65-77) — a
background activity start that Android 10+ blocks unless an exemption applies.
*Hypothesis:* answering from a watch/headset via Telecom may keep working on some
OEMs (Telecom apps sometimes hold BAL grants), but the notification-action path is
deterministically blocked by the trampoline rule.

### 2.4 HIGH (Android): cold-start WebSocket connect is an accident of the outbox, not a designed step

Nothing in the FCM ring path connects the WebSocket. `CallManager.init` only installs
the `onCallSignal` handler (CallService.kt:232). The socket comes up as a
side-effect: `onRingPush` → `announceRinging` → `sendCallRinging` → `send(frame,
queueIfDown=true)` finds the socket down, parks the frame, and calls
`scheduleReconnect()` (WebSocketClient.kt:158-168), which `connect()`s after a
500-1000ms jittered backoff (WebSocketClient.kt:196-208). Compare iOS, which
explicitly calls `WebSocketClient.shared.reconnect()` inside the push handler
(CallService.swift:901-903).

Why this is fragile, not just ugly:

- If `announceRinging`'s `runCatching` path ever changes (or the `callerId` is blank),
  no reconnect is ever scheduled and the offer flush never happens — the exact
  "rings, then Connecting forever" failure `KILLED_STATE_CALLS_CHECKLIST.md` §2
  describes.
- `reconnectAttempts` is not reset by this path until `onOpen`, so a prior failed
  cycle inflates the delay (WebSocketClient.kt:199-203) during the most
  latency-sensitive seconds of the product.
- The offer-buffer flush happens only "the moment that user's socket attaches"
  (websocket index.ts:194-196); every ms of connect delay is added ring-to-media time.

### 2.5 HIGH (backend): trickle ICE sent before the callee's socket attaches is lost

The relay buffers only `call_offer` (websocket index.ts:444-448). The caller starts
trickling candidates immediately after the offer (CallService.kt:328-334 + the
`onIceCandidate` → `sendCallIce` path; WebSocketClient.kt:268-270 queues them
client-side only while the *caller's* socket is down). For a push-woken callee, every
caller candidate published between offer-send and callee-socket-attach is dropped by
pub/sub (index.ts:161-169 delivers to live sockets only).

Result: the callee holds an offer whose SDP (trickle) contains no candidates and never
receives the caller's. Connectivity then depends entirely on the callee's candidates
reaching the caller and the caller's connectivity checks creating peer-reflexive
candidates at the callee. That works often on host/srflx networks, but fails or is
slow behind symmetric NAT / TURN-only paths — i.e. exactly the networks TURN exists
for. This is a plausible root cause for "rings, accepts, then never connects" on
killed-process Android, distinct from the (fixed) offer loss.

### 2.6 HIGH (Android): the incoming call plays one notification "ding", not a looping ringtone

For a **self-managed** ConnectionService, the system does not play a ringtone — the
app must. Voiid's only ring surface is the notification channel's default sound
(`INCOMING_CHANNEL`, IMPORTANCE_HIGH, no `setSound`, CallForegroundService.kt:288-300)
— a one-shot notification tone. `CallTones` implements only the *caller-side*
ringback (apps/android/.../net/CallTones.kt:68-86); its header comment asserts the
callee ringtone "is the notification channel" (CallTones.kt:13-17), which produces a
single chirp for a 45-second ring window. A phone across the room effectively never
rings. Signal-Android dedicates `IncomingRinger` to this: a looping `MediaPlayer` on
the user's `RingtoneManager` ringtone URI plus vibrator, started when the call screen
raises ("/Users/devacc/Signal stack/Signal-Android/app/src/main/java/org/thoughtcrime/securesms/webrtc/audio/IncomingRinger.java":68, 142-186).

### 2.7 MEDIUM (Android 14+): full-screen intent grant is never checked

`setFullScreenIntent(fullPi, true)` (CallForegroundService.kt:199) is the entire
lockscreen-takeover mechanism. On Android 14+ (`USE_FULL_SCREEN_INTENT` is
user-revocable; Play only auto-grants it to calling/alarm apps), a denied grant
silently degrades the ring to a heads-up notification. The code never calls
`NotificationManager.canUseFullScreenIntent()` nor deep-links to
`ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`, so a revoked state is invisible to both
the app and the user.

### 2.8 MEDIUM (Android): ring latency — up to 6s of synchronous name resolution before the ring is raised

`onMessageReceived`'s call branch does `runBlocking { UserDirectory.ready(ctx); … 
withTimeoutOrNull(6_000L) { ChatService(ctx).resolvePeer(...) } }` **before**
`CallManager.onRingPush` (VoiidMessagingService.kt:73-81). On a killed process on a
slow network, the callee's phone shows nothing for up to ~6s of the caller's ring
window (iOS caps ringing at 45s; Android has no cap at all — see 2.2). The group-call
branch has the same 6s block (VoiidMessagingService.kt:91-96). Signal posts the ring
first and refines details after (FcmReceiveService → immediate service start,
"/Users/devacc/Signal stack/Signal-Android/app/src/main/java/org/thoughtcrime/securesms/gcm/FcmFetchManager.kt":74-76, 148-151).

### 2.9 MEDIUM (Android 13+): denied POST_NOTIFICATIONS means calls silently never ring

`Notifier.postMessage` guards on the permission and logs (VoiidMessagingService.kt:283-289),
but `CallForegroundService.showIncoming` does not (CallForegroundService.kt:177-206) —
`notify()` is a silent no-op without the permission on API 33+. Combined with 2.7 there
is then *no* ring surface at all. Nothing in the app detects or warns about this state
for calls specifically.

### 2.10 MEDIUM (backend): `/calls/ring` has no authorization beyond a valid JWT

Any authenticated user can ring any `to_user_id` with any `conversation_id` string
(calls.ts:40-61 validates types/UUID only — no membership or contact check, unlike
`/calls/group/ring` which verifies membership at calls.ts:225-230). This is a
wake-push spam / harassment vector (full-screen ring on arbitrary victims) and lets
arbitrary `calls` rows be inserted with attacker-chosen `conversation_id`.

### 2.11 LOW-MEDIUM (Android): push-token staleness edge cases

- `registerPushToken` early-returns when the cached token equals the new one
  (E2EManager.kt:89-94) even if the previous upload failed; recovery relies on
  `bootstrap()` re-running `register(id)` on next process start (E2EManager.kt:60-67,
  192-196). If the server cleared the token as dead (push.ts:125-131 — including on
  transient `NotRegistered` responses), the device is ring-deaf until the next app
  open. Signal re-verifies token freshness periodically against the server.
- `devices/register` upserts `push_token = excluded.push_token`
  (backend/api/src/routes/devices.ts:17-23), so a register that runs before the first
  FCM token exists (fresh install: `bootstrap()` runs before the
  `FirebaseMessaging.getInstance().token.await()` in ChatsHomeView.kt:137-148) writes
  NULL over nothing today, but any future reordering can null a live token.

### 2.12 LOW (Android): no OEM battery-kill mitigation

FCM high-priority data messages (push.ts:155) correctly pierce Doze, but aggressive
OEM task killers (Xiaomi/Oppo/Vivo "battery optimization") prevent the process from
being started for FCM at all. There is no
`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` prompt, no Settings deep-link, and no in-app
diagnostics (no hits for battery/wakelock anywhere under apps/android). Signal ships
device-specific guidance and a websocket-fallback foreground fetch service
(FcmFetchManager.kt:74-76).

### 2.13 LOW (Android): ring path runs for signed-out devices

The `type == "call"` branch never checks `TokenStore.isAuthenticated`
(VoiidMessagingService.kt:61-83), unlike the story branch (line 108). A device that
logged out but whose token wasn't yet cleared server-side will raise a full incoming
ring it cannot answer (accept → WS connect skipped for missing JWT,
WebSocketClient.kt:113).

### 2.14 Notes — NOT bugs, verified working

- The "offer published before socket attach is lost forever" bug from
  KILLED_STATE_CALLS_CHECKLIST.md §2 **is** fixed in code (websocket index.ts:393-398,
  444-448, 194-196), including multi-device non-draining flush and resolution cleanup.
- iOS PushKit ordering (report before completion), duplicate-push tolerance, waiting
  call handling, and the pre-report missed-call backstop are all correct
  (CallService.swift:840-906).
- The kotlinx `encodeDefaults` bug class does not bite here: Android call signaling
  frames are built by string templates (WebSocketClient.kt:257-303), and the FCM
  payload is a plain string map (pushPayload.ts:75-87). Swift reads push fields via
  optional casts, not Codable (VoIPPushManager.swift:133-137) — no keyNotFound risk.

---

## 3. How WhatsApp + Signal do it

**Signal-Android** ("/Users/devacc/Signal stack/Signal-Android"):

- `FcmReceiveService` (app/src/main/java/org/thoughtcrime/securesms/gcm/FcmReceiveService.java:28-35)
  receives the high-priority FCM push and *logs the delivered priority* to detect
  downgrades. It does not parse call content from the push; it triggers
  `FcmFetchManager` (gcm/FcmFetchManager.kt:74-76, 148-166), which on a
  high-priority push starts a **foreground service** (`FcmFetchForegroundService`) to
  own process lifetime, then drains the server message queue over the websocket.
  The call "offer" is an E2EE *message* in the store-and-forward queue — so signaling
  can never be lost the way fire-and-forget pub/sub loses it; the queue is the buffer.
  Voiid's Redis offer/ICE buffering is the moral equivalent and should cover the same
  frame set.
- Incoming ring: `IncomingRinger` (webrtc/audio/IncomingRinger.java:68, 142-186) loops
  the user's system ringtone via `MediaPlayer` with vibration and ringer-mode checks;
  ringing is a first-class audio component, not a notification-channel sound.
- The full-screen incoming UI is an *activity* launched via full-screen intent, and
  answer happens inside that activity — no notification-trampoline `startActivity`
  from a receiver.

**Signal-iOS** ("/Users/devacc/Signal stack/Signal-iOS"):

- `PushRegistrationManager.swift` owns `PKPushRegistry` (lines 290-294) and in
  `didReceiveIncomingPushWith` (line 146) the comment at line 157 states the exact
  contract Voiid implements: the branch MUST start a CallKit call before returning.
  Voiid's iOS shape matches; the difference is Signal also registers the standard APNs
  token with its server for everything that is not a call — the piece Voiid iOS is
  missing entirely (§2.1).

**WhatsApp** (from public engineering behavior, not source — hypothesis-grade): same
split — PushKit+CallKit on iOS; on Android a high-priority FCM data message starts a
foreground service, plays a looping ringtone on `STREAM_RING`, and uses full-screen
intent; call setup offers are re-fetched from the server rather than trusted to
transient channels.

---

## 4. Recommended fixes (ordered)

1. **Upload the APNs alert token from iOS and accept it server-side.** (iOS +
   backend; critical) — In `AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken`
   (apps/ios/Voiid/Voiid/VoiidApp.swift:121-127) hex-encode and persist the token, and
   add `push_token`/`push_provider: "apns"` to `RegisterDeviceBody` in
   apps/ios/Voiid/Voiid/Networking/E2EManager.swift:220-244 (plus a re-upload trigger
   on token change, mirroring VoIPPushManager.uploadTokenIfNeeded). No backend schema
   change needed (devices.push_token exists, database/migrations/002_devices.sql:14;
   route already accepts it, backend/api/src/routes/devices.ts:9-23). Risk: low —
   additive; unblocks the calls.ts alert fallback and group-call rings on iOS.

2. **Give ring pushes a short TTL.** (backend; critical) — In
   backend/api/src/pushPayload.ts:65-68 add `if (meta?.type === 'call' || meta?.type
   === 'group_call') return CALL_RING_TTL_SECONDS` (~45-60s, aligned with iOS's 45s
   ring cap). Automatically applies to both FCM `ttl` (push.ts:155) and
   `apns-expiration` (pushPayload.ts:163). Add a payload test. Risk: minimal.

3. **Fix the Android accept-action trampoline.** (Android; critical) — Replace the
   `startActivity` calls in `CallActionReceiver` (apps/android/.../net/CallForegroundService.kt:309-317,
   323-330) and `VoiidConnection.answer()` (apps/android/.../net/VoiidConnection.kt:65-77)
   with an accept flow that does not start an activity from a receiver: make the
   Accept action a `PendingIntent.getActivity` into MainActivity carrying an
   `EXTRA_ACCEPT_CALL` extra (handled by DeepLinkRouter → `CallManager.accept()`), and
   keep `CallManager.accept()` in the receiver only for the Telecom/no-UI paths.
   Risk: medium — touches answer UX on every Android version; verify lockscreen accept.

4. **Play a real looping ringtone + vibration on Android.** (Android; high) — Add an
   incoming ringer to apps/android/.../net/CallTones.kt (or a new `IncomingRinger.kt`):
   looping `MediaPlayer`/`Ringtone` on `RingtoneManager.getDefaultUri(TYPE_RINGTONE)`
   with `AudioAttributes USAGE_NOTIFICATION_RINGTONE`, vibrator, respect ringer mode;
   start it where the ring is raised (`CallManager.raiseIncomingAlert`,
   apps/android/.../net/CallService.kt:415-439 and `VoiidConnection.onShowIncomingCallUi`,
   VoiidConnection.kt:57-59), stop on accept/decline/remote-end/timeout. Also set the
   notification channel sound to null once the ringer owns audio. Risk: low-medium
   (audio focus interplay with MODE_IN_COMMUNICATION; mirror Signal's IncomingRinger).

5. **Buffer `call_ice` alongside `call_offer` in the relay.** (backend; high) — In
   backend/websocket/src/index.ts:444-448, also `hset` a per-user per-call ICE list
   (e.g. `call:ice:{userId}` hash of `call_id` → JSON array, appended) with the same
   TTL and the same resolution-time `hdel` (index.ts:449-465); flush after the offer
   in `flushPendingOffers` (index.ts:120-140). Candidates are opaque and short-lived,
   same privacy posture as buffered SDP. Client change: none (Android/iOS already
   accept late candidates; Android queues pre-remoteDesc candidates,
   CallService.kt:610-622). Risk: low; bounds needed (cap list length).

6. **Explicitly connect the WebSocket in the Android ring path.** (Android; high) —
   In `CallManager.onRingPush` (apps/android/.../net/CallService.kt:373-399) call
   `WebSocketClient.get(appContext).reconnect()` (mirroring iOS
   CallService.swift:901-903) and set `callActive = true` early so backoff uses the
   5s cap (WebSocketClient.kt:39-40, 65). Also add an Android offer timeout (~30s)
   that tears down the ring if no offer arrives, mirroring iOS
   `startOfferTimeout` (CallService.swift:173-175). Risk: low.

7. **Raise the Android ring before name resolution.** (Android; medium) — In
   VoiidMessagingService.kt:61-83, call `CallManager.onRingPush` immediately with the
   local-directory name (`UserDirectory.user(callerId)` only, no 6s network wait), and
   refine the displayed name asynchronously (update the notification). Same for the
   group_call branch (lines 87-99). Risk: low.

8. **Detect and surface degraded ring capability on Android.** (Android; medium) —
   Check `NotificationManagerCompat.areNotificationsEnabled()` +
   `NotificationManager.canUseFullScreenIntent()` (API 34+) at app start and before
   `showIncoming` (CallForegroundService.kt:177-206); log distinctly, show an in-app
   "calls can't ring" banner with deep-links to the relevant Settings pages
   (`ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`). Optionally add an OEM
   battery-optimization prompt (`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`)
   behind a "calls unreliable?" help screen. Risk: low.

9. **Authorize `/calls/ring`.** (backend; medium) — In
   backend/api/src/routes/calls.ts:40-61, require the caller to be an active member of
   `conversation_id` and the callee to be a member too (same query shape as
   calls.ts:225-230), 403 otherwise. Risk: low, but verify the contact-card /
   call-log redial path always has a conversation (Android CallService.kt:285 allows
   null conversation ids — the endpoint currently requires a string; align both).

10. **Harden token upkeep.** (Android + backend; low-medium) — (a) In
    `E2EManager.registerPushToken` (E2EManager.kt:88-97), don't skip the upload when
    `prev == token` unless the last upload verifiably succeeded (persist an
    `uploaded_ok` flag). (b) In backend/api/src/routes/devices.ts:17-23 change the
    upsert to `push_token = coalesce(excluded.push_token, devices.push_token)` so a
    tokenless register can never null a live token. (c) Consider not clearing tokens
    on a single FCM `NotRegistered` (push.ts:160-166) without a retry/second strike.
    Risk: low.

11. **Ignore ring pushes when signed out.** (Android; low) — Add
    `if (!TokenStore.get(ctx).isAuthenticated) return` at the top of the `"call"` and
    `"group_call"` branches in VoiidMessagingService.kt:61-99, matching the story
    branch (line 108). Risk: minimal.
