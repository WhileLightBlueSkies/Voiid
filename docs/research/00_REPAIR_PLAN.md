# Voiid Repair Plan

Synthesized from the 11 research docs in `docs/research/`. 101 proposed fixes were
deduplicated and re-verified against the current tree on `main` (commit `41eefc7`);
2 were dropped as already shipped, several were merged, and 3 descriptions were
corrected where the doc overstated the defect. What remains is 91 items in
execution order.

---

## Founder summary

**What is actually broken for users right now.** Four things, and they are the whole
of Tier 1.

*Calls do not ring reliably.* On iPhone the app has never told our server where to
send a call notification — the phone registers with Apple, gets an address, and
throws it away. So the backup ring path and every group-call ring silently reach
nobody. On Android, answering from the notification connects the audio but never
opens the call screen, because Google banned that pattern in Android 12 and we
still use it — the user is in a call with no controls and no video. Also on Android
there is no ringtone at all: a single notification "ding," then 45 seconds of
silence, so a phone across the room is never heard. And a call push is currently
allowed to sit in the queue for 28 days, which means a phone that was off can
full-screen-ring a call that ended last week.

*Note to Self is dead on Android and degrades on iPhone.* Android throws a
"no recipient" error on every single operation — you cannot even open the chat, let
alone send to it. iPhone works until you close the app: the local database has no
slot for "self" chats, so on the next launch the note re-reads as a normal chat and
breaks the same way. Separately, notes never sync between your own devices, and any
photo or reaction sent to a note is rejected by the server.

*The map features interfere with each other.* Adding one person to your map wipes
you off the map for everyone already watching — permanently, until you toggle
visibility off and on. Stopping a location share in a chat can erase you from the
friends map. And on iPhone, if the app is killed, you keep showing as "sharing" to
everyone while actually broadcasting nothing.

*Memories (stories) lag.* On iPhone a full-size photo is being read from disk and
decoded on the main thread up to 30 times per second while it is on screen. On
Android photos decode at full camera resolution into a cache that is never emptied
— ten stories is roughly half a gigabyte held. Both platforms also show black bars
around any photo that is not exactly phone-shaped.

**What is not broken, just dated.** Tier 2 is the reels/creator UI, the clip editor
and camera, and the game-invite banner. These work; they look and feel a generation
behind Instagram. The single highest-leverage item here is that tapping a clip on
someone's profile does nothing at all — the grid is decorative.

**What does not exist yet.** Tier 3 is net-new: conference calling (escalating a 1:1
to a group without creating a group chat), groups at 1000 members, communities, and
the admin/DPDP compliance plane. Tier 3 is where the real risk lives — the
compliance items in particular are launch-blocking in India, and one of them is a
live security hole where any logged-in user can remotely disable any other user's
device.

**Two corrections worth surfacing.** First, the research proposed adding
authorization to the call-ring endpoint — that has already been fixed and shipped;
both the API membership check and the WebSocket ring-grant are in the tree today, so
those two items are struck. Second, three security defects were found that are not
about polish and should be treated as urgent regardless of tier: the device-deletion
hole above, deleted accounts silently coming back to life on next login, and client
IP addresses being attacker-controlled in every log we keep.

**Sequencing in one line.** Fix what is broken, then modernize what is dated, then
build what is missing — and pull the three security holes forward out of Tier 3 to
run alongside Tier 1.

---

## How to read this plan

Each item carries **severity**, **platform**, **files**, a self-contained
instruction, and **conflicts** — items touching the same file that must not run
concurrently. Items with no conflict listed are safe to parallelize freely.

Severity is user impact, not effort. `critical` = broken or a live security hole;
`high` = materially degraded; `medium` = noticeable; `low` = polish or latent.

**The conflict rule.** Two items that name the same file must not be assigned to
parallel agents. The heavy contention points in this repo are:
`backend/api/src/routes/calls.ts`, `backend/api/src/routes/messages.ts`,
`backend/api/src/routes/conversations.ts`, `apps/*/net/ChatEngine.*`,
`apps/*/Stories/StoryViewerView.*`, and `apps/*/clips/ClipFullscreenView.*`.

---

# TIER 0 — Live security holes (run immediately, alongside Tier 1)

These are out of tier order deliberately. They are not user-visible breakage, which
is why the docs filed them under the admin workstream, but each is exploitable today
by any authenticated user.

### 0.1 — `DELETE /devices/:device_id` has no ownership check
**Severity:** critical · **Platform:** backend
**Files:** `backend/api/src/routes/devices.ts`

*Verified in tree at devices.ts:101-105.* The handler runs
`update devices set revoked_at = now() where id = $1` using only the path parameter;
the authenticated caller's `user_id` is never read. Any authenticated user who knows
another user's `device_id` can revoke that device and delete its one-time prekeys,
denying the victim inbound sessions. Device ids are not secret —
`GET /devices/:user_id` returns them for any user to any authenticated caller, so
this is a two-request unprivileged attack. Read `const { user_id } = (req as any).auth`,
change the update to `where id = $1 and user_id = $2 returning id`, return 404 when
no row matches, and run the `one_time_prekeys` delete only when the revoke matched.
The correct pattern already exists directly above in the `/voip-token` handler at
devices.ts:70-77. Strictly narrowing; the only legitimate caller is the user's own
linked-devices screen.
**Conflicts:** 1.9 (same file — sequence 0.1 first, it is smaller).

### 0.2 — Deleted accounts resurrect on login; deleted users keep a 30-day valid token
**Severity:** critical · **Platform:** backend
**Files:** `backend/api/src/routes/auth.ts`, `backend/api/src/auth.ts`, `backend/api/src/routes/users.ts`

Three defects, one root cause: `deleted_at` is a flag with no lifecycle. (a)
`POST /auth/firebase` upserts on conflict without inspecting `deleted_at`, so logging
in with a deleted account's number returns a working token for a row that every read
path filters out — the account is neither erased nor usable. (b) `requireAuth`
verifies only the JWT signature and never loads the user row; with a 30-day default
expiry and a no-op logout, a user who deletes their account keeps full API access —
posting clips, sending ciphertext — for up to a month. (c) `DELETE /users/me` enforces
deletion only by revoking devices, inferring reachability from device state rather
than identity. Add `deleted_at` to the upsert's `returning` and branch explicitly
(reject, or clear it as a deliberate audited un-delete if product chooses
reinstatement-within-grace). Add a `deleted_at is null` check to `requireAuth`,
caching the lookup in Redis for a few seconds to avoid a per-request DB round-trip.
Fail closed for deleted users but **not** on a Redis outage. This must land before
the erasure worker (3.15) — a worker deleting rows while stale JWTs still
authenticate against them creates orphaned writes.
**Conflicts:** 3.15, 3.17 (users.ts); 0.4 (auth.ts).

### 0.3 — Client IP is attacker-controlled in every log
**Severity:** high · **Platform:** backend
**Files:** `backend/api/src/index.ts`, `backend/api/src/security.ts`, `backend/api/src/routes/admin.ts`, `backend/api/src/routes/reachability.ts`

Three places parse `x-forwarded-for` directly and trust it, while Express
`trust proxy` is never set and nothing validates the header came from our own reverse
proxy. Any client reaching the Node port directly can set an arbitrary value, writing
fabricated IPs into `admin_sessions`, `security_events`, and the admin audit log —
poisoning exactly the records a breach investigation or DPDP incident report relies
on. It also defeats the per-IP rate limiter, whose Redis key is
`ratelimit:<bucket>:<ip>`. Set `app.set('trust proxy', <hop count or proxy CIDR>)` in
`index.ts` matching the real topology in `docs/VULTR_DEPLOY.md`, then replace all
three manual helpers with `req.ip`. Getting the hop count wrong fails in both
directions — too permissive and spoofing still works, too restrictive and every
request appears to come from the proxy, throttling all users as one client. Verify
against the deployed topology before merging.
**Conflicts:** 0.4 (must land first — see below); 3.19 (admin.ts).

### 0.4 — Failed-login events logged without client IP
**Severity:** medium · **Platform:** backend
**Files:** `backend/api/src/routes/auth.ts`, `backend/api/src/security.ts`

`auth.ts:27` calls `logSecurityEvent('failed_login', ...)` passing no `ip_address`,
though the signature accepts one and the table has the column. The most useful
credential-stuffing signal is recorded without the attacker's address. Pass the
client IP. **Strictly ordered after 0.3** — without trust-proxy the recorded IP is
attacker-controlled, which is worse than none, since it lets an attacker forge
failed-login records against arbitrary addresses.
**Conflicts:** 0.2, 0.3 (both files). Must run after 0.3.

---

# TIER 1 — Broken for users now

## 1A. Calls not ringing

### 1.1 — iOS never uploads its APNs alert token
**Severity:** critical · **Platform:** iOS
**Files:** `apps/ios/Voiid/Voiid/VoiidApp.swift`, `apps/ios/Voiid/Voiid/Networking/E2EManager.swift`

*Verified: VoiidApp.swift:121-127 passes the token only to `Auth.auth().setAPNSToken`
and discards it; `E2EManager.swift` contains no `push_token` reference at all.* So
`devices.push_token` is NULL for every iOS device in production. This kills the
backend's alert-push ring fallback (`calls.ts:66-101` selects `push_token` when VoIP
is unconfigured or the VoIP token is missing/cleared) and means
`POST /calls/group/ring`, which uses `push_token` only, never reaches a backgrounded
or killed iOS device. Hex-encode and persist the device token in the AppDelegate
callback, add `push_token` and `push_provider: "apns"` to `RegisterDeviceBody`, and
re-upload on token change — mirror the existing `VoIPPushManager.uploadTokenIfNeeded`
shape rather than inventing a new one. The backend already accepts both fields
(`devices.ts:9-23`); no schema change and no backend work needed.
**Conflicts:** none in the iOS batch.

### 1.2 — Android call Accept is a blocked notification trampoline
**Severity:** critical · **Platform:** Android
**Files:** `apps/android/.../net/CallForegroundService.kt`, `apps/android/.../net/VoiidConnection.kt`, `apps/android/.../net/DeepLinkRouter.kt`, `apps/android/.../MainActivity.kt`

*Verified at CallForegroundService.kt:309-317 and 323-330:* `CallActionReceiver.onReceive`
calls `context.startActivity` from a BroadcastReceiver reached by a notification
action. The app targets SDK 36; since Android 12 this is a blocked notification
trampoline, so `CallManager.accept()` runs and audio connects but `MainActivity`
never opens — the user answers into no UI, and video calls never attach camera or
renderers. `VoiidConnection.answer()` has the same background-activity-start problem
from a Telecom binder callback. Make the Accept action a `PendingIntent.getActivity`
into `MainActivity` carrying an accept-call extra routed through `DeepLinkRouter` to
`CallManager.accept()`, keeping receiver-side accept only for headless/Telecom paths.
Verify lockscreen answer on Android 12 through 16 specifically — that is where the
regression risk sits.
**Conflicts:** 1.4 (CallForegroundService.kt, VoiidConnection.kt), 1.6 (CallForegroundService.kt). Run 1.2 first; it is the correctness fix.

### 1.3 — Ring push TTL is 28 days
**Severity:** critical · **Platform:** backend
**Files:** `backend/api/src/pushPayload.ts`, `backend/api/test/pushPayload.test.ts`

*Verified at pushPayload.ts:65-68:* `wakeTtlSeconds` special-cases only `'story'`;
`'call'` and `'group_call'` fall through to the 28-day `OFFLINE_TTL_MS`, applied to
both the FCM `ttl` and the APNs `apns-expiration`. A phone that was off during the
ring receives the held push hours or days later and full-screen-rings a dead call —
and because the offer buffer TTL is 60s, accepting hangs forever. Add a
`CALL_RING_TTL_SECONDS` of 45-60s (matching the iOS 45s `incomingRingCap` and the
existing `VOIP_TTL_SECONDS = 30` precedent in the same file) and return it for both
call types. Add a test asserting the header and ttl for call-type pushes.
**Conflicts:** none.

### 1.4 — Android has no incoming ringtone or vibration
**Severity:** high · **Platform:** Android
**Files:** `apps/android/.../net/CallTones.kt`, `apps/android/.../net/CallService.kt`, `apps/android/.../net/VoiidConnection.kt`, `apps/android/.../net/CallForegroundService.kt`

The only incoming-call sound is the notification channel's default one-shot
(`INCOMING_CHANNEL` is created without `setSound`), and with a self-managed
`ConnectionService` the system does not ring on the app's behalf. `CallTones`
implements caller-side ringback only. Net result: one ding for a 45-second ring
window, so a phone across the room is never heard. Add an incoming ringer modeled on
Signal-Android's `webrtc/audio/IncomingRinger.java` — a looping MediaPlayer or
Ringtone on `RingtoneManager.getDefaultUri(TYPE_RINGTONE)` with
`USAGE_NOTIFICATION_RINGTONE` attributes plus vibrator, honoring ringer mode. Start it
in `CallManager.raiseIncomingAlert` and `VoiidConnection.onShowIncomingCallUi`; stop
on accept, decline, remote-end, and timeout; silence the notification channel once the
ringer owns audio so there is no double sound.
**Conflicts:** 1.2, 1.5, 1.6.

### 1.5 — Android never explicitly connects the WebSocket on a ring push
**Severity:** high · **Platform:** Android
**Files:** `apps/android/.../net/CallService.kt`, `apps/android/.../net/WebSocketClient.kt`

Nothing in the Android FCM ring path connects the WebSocket — `connect()` is called
explicitly only from the chats screen. On a killed-process ring the socket comes up
only as a side-effect of `announceRinging` queueing a frame into a down socket, which
triggers `scheduleReconnect` with jittered backoff: fragile, and it adds latency to
the server-side offer-buffer flush that fires only on socket attach. In
`CallManager.onRingPush`, explicitly call `WebSocketClient.get(appContext).reconnect()`
and set `callActive = true` so the 5s backoff cap applies, mirroring the iOS path at
`CallService.swift:901-903`. Also add a ~30s no-offer timeout that cancels the ring
and records it missed — iOS has `startOfferTimeout`, Android has none, so a ring
whose offer was lost sits forever.
**Conflicts:** 1.4, 1.7 (CallService.kt).

### 1.6 — Trickle ICE is not buffered for push-woken callees
**Severity:** high · **Platform:** backend
**Files:** `backend/websocket/src/index.ts`

The relay buffers only `call_offer` for push-woken callees; `call_ice` frames
published over Redis pub/sub while the callee's socket is still attaching are lost
permanently, since delivery is to live sockets only. The callee then holds the offer
SDP — trickle, so no candidates in it — but none of the caller's candidates, leaving
connection dependent on peer-reflexive discovery, which fails or stalls behind
symmetric NAT and TURN-only networks. This is a direct cause of the
"rings, accepts, never connects" report on killed-process Android. Park `call_ice`
frames per user per call (e.g. Redis hash `call:ice:{userId}` mapping call_id to a
capped JSON array) with the same `OFFER_BUFFER_TTL` and the same resolution-time
cleanup as offers, and flush them immediately after the offer in
`flushPendingOffers`. Clients already tolerate late candidates — Android queues
pre-remote-description candidates.
**Conflicts:** 3.4 (same file, new frame types) — sequence 1.6 first.

### 1.7 — Android blocks the ring up to 6s resolving the caller's name
**Severity:** medium · **Platform:** Android
**Files:** `apps/android/.../net/VoiidMessagingService.kt`

The call branch of `onMessageReceived` blocks in `runBlocking` on `UserDirectory.ready`
plus a 6-second network `resolvePeer` timeout *before* calling
`CallManager.onRingPush`; the group_call branch does the same. On a cold-started
process on a slow network the callee sees nothing for up to 6 seconds of a 45-second
ring window. Call `onRingPush` immediately with only the synchronous local-directory
name (with a UUID-safe fallback — never a raw id), then resolve the better name
asynchronously and update the posted notification and state. Signal-Android's
`FcmFetchManager` starts its service before doing any fetch work, for exactly this
reason.
**Conflicts:** 1.5 (CallService.kt indirectly), 1.8.

### 1.8 — Android does not detect degraded ring capability
**Severity:** medium · **Platform:** Android
**Files:** `apps/android/.../net/CallForegroundService.kt`, `apps/android/.../MainActivity.kt`

`showIncoming` never checks `POST_NOTIFICATIONS` — on Android 13+ with the permission
denied, `notify()` is a silent no-op and calls never ring, with no trace. (The message
path *does* check, so this is an inconsistency, not an unknown.) Nothing checks
`canUseFullScreenIntent()` on Android 14+ where the permission is user-revocable, so
the lockscreen ring silently degrades to a heads-up notification. And there is no OEM
battery-optimization mitigation anywhere, though aggressive OEM killers prevent FCM
process starts outright. Check both states at app start and before `showIncoming`, log
them distinctly, show an in-app "calls can't ring" banner deep-linking to
`ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT` or notification settings, and add an
optional battery-optimization exemption prompt in a call-reliability help screen.
**Conflicts:** 1.2, 1.4, 1.6 (CallForegroundService.kt).

### 1.9 — Push-token upkeep hardening
**Severity:** low · **Platform:** all
**Files:** `apps/android/.../net/E2EManager.kt`, `backend/api/src/routes/devices.ts`, `backend/api/src/push.ts`

Three staleness edges that each make a device silently ring-deaf. (1)
`registerPushToken` skips upload when the cached token equals the new one even if the
last upload failed or the server cleared it — persist an uploaded-ok flag and re-send
until confirmed. (2) `devices/register` upserts `push_token = excluded.push_token`, so
a register sent before an FCM token exists can null a live server-side token — change
to `coalesce(excluded.push_token, devices.push_token)`. (3) `push.ts` clears a token on
a *single* FCM `registration-token-not-registered` response, which can be transient —
require a second consecutive failure or a timestamped strike, since a wrongly-cleared
token leaves the device ring-deaf until the next app open.
**Conflicts:** 0.1 (devices.ts). Run after 0.1.

### 1.10 — Android rings when signed out
**Severity:** low · **Platform:** Android
**Files:** `apps/android/.../net/VoiidMessagingService.kt`

The `call` and `group_call` branches never check `TokenStore.isAuthenticated`, unlike
the story branch. A logged-out device whose FCM token was not yet cleared server-side
raises a full incoming ring it cannot answer — the accept path skips the WS connect for
a missing JWT. Add an `isAuthenticated` guard at the top of both branches and ignore
silently.
**Conflicts:** 1.7 (same file). Merge into 1.7 if convenient.

> **STRUCK — already shipped.** Two proposed items ("Require conversation membership on
> POST /calls/ring" and "Authorize POST /calls/ring and gate inbound offers on
> reachability") are complete in the tree today: `sharesConversation()` at
> `calls.ts:46-62` checks *both* parties, is called at `calls.ts:101` before the row is
> inserted, and a Redis ring-grant (`ringGrantKey`, `calls.ts:64`) is enforced by the
> WebSocket relay at `websocket/src/index.ts:51-55`. No action. The *client-side*
> half — dropping offers from unknown peers — remains unimplemented but is now
> defense-in-depth rather than the primary gate; it is folded into 3.6.

## 1B. Note to Self

### 1.11 — Android `peerUserId()` throws 404 for SELF conversations
**Severity:** critical · **Platform:** Android
**Files:** `apps/android/.../model/Stores.kt`

*Verified at Stores.kt:512-520 — the function has no SELF branch.* For a self-chat
`conv.peerUserId` is null, so it falls through to `chatService.resolvePeer(conv.id)`,
which looks for a member that is not me in a conversation whose only member *is* me,
returns a null peer, and throws `ApiError.Http(404, "no peer")`. This kills all seven
Android entry points: text send (stuck PENDING, "Couldn't resolve the recipient"),
reply, media (red FAILED bubble), **syncMessages — so merely opening the chat shows
"Couldn't load messages"** — forward, delete-for-everyone, and react. Insert as the
very first line of the function body, before the cached-peer check:
`if (conv.type == ConversationType.SELF) return tokens.userId ?: ""`. This is a literal
port of the shipped iOS fix at `Stores.swift:643`. Verify: open Note to Self with no
error banner, then send text and confirm the bubble reaches SENT rather than sitting on
a clock.
**Conflicts:** none.

### 1.12 — Both local stores collapse `self` into `direct`, re-breaking iOS every cold launch
**Severity:** critical · **Platform:** both mobile
**Files:** `apps/ios/Voiid/Voiid/Storage/LocalStore.swift`, `apps/android/.../store/LocalStore.kt`

*Verified: iOS writes `c.type == .group ? "group" : "direct"` at LocalStore.swift:104
and reads `kind == "group" ? .group : .direct` at :63.* Both stores round-trip the
conversation type as a group/not-group boolean, predating the third case. This is fatal
on iOS because the chat list renders straight from SQLite: after the first
`saveConversations`, the self-chat reads back as `.direct`, the self short-circuit at
`Stores.swift:643` never fires, send falls through to `resolvePeer` and throws
404 — reproducing the Android bug on iOS — the top-pin is lost, and every UI branch
silently takes the `.direct` path. **No schema migration is needed:** `kind` is
free-text in both stores with no enum or CHECK constraint. Six changes: iOS write
`c.type.rawValue`; iOS read `ConversationType(rawValue: kind) ?? .direct`; iOS title
derivation gains a `kind == "self"` branch returning "Note to Self" *before* the
peerUserId branch so a self row never hits the `storedTitle ?? "Unknown"` default;
Android write a three-way `when`; Android read a three-way mapping; Android title gains
the matching branch. Rows already written as "direct" self-heal on the next
fetch-and-save cycle since the server is authoritative on type. Verify: cold-launch in
airplane mode — Note to Self stays pinned with the bookmark mark, header is not
tappable, sending still works.
**Conflicts:** none.

### 1.13 — Zero-recipient fan-out 400s, breaking every non-text Note to Self send
**Severity:** high · **Platform:** backend
**Files:** `backend/api/src/routes/messages.ts`

*Verified at messages.ts:66:* the fan-out branch is gated on
`Array.isArray(messages) && messages.length > 0`. A single-device Note to Self
legitimately produces an **empty** ciphertext bundle — `encryptFanout` returns `[]` by
design, because there is genuinely no other device to encrypt to. The empty array fails
the length check, falls through to the legacy single-ciphertext path, and returns
`400 {error: 'conversation_id and ciphertext required'}` because a fan-out body has no
top-level `ciphertext` field. Only the *text* path short-circuits on an empty bundle;
media, reaction, delete-for-everyone, reply, forward-media and location all POST and
400. On iOS a 400 is not retryable, so media shows a red failed bubble. Change the
discriminator from non-emptiness to presence: `if (Array.isArray(messages)) {`. The
existing body is already safe for an empty array — the metadata insert writes
`ciphertext = null` unconditionally, the per-device loop is a no-op, the owners lookup
returns nothing, no Redis publish fires, and the wake push is already guarded by
`if (deviceIds.length)`. It returns `{message_id, delivered_devices: 0}`, the correct
semantics. Then let the non-text client paths proceed into this now-successful POST so
the note gets a canonical server id and timestamp.
**Conflicts:** 3.9, 3.11 (messages.ts). Run 1.13 first — it is a one-line change.

### 1.14 — Android encrypts notes to the sending device and double-targets linked devices
**Severity:** high · **Platform:** Android
**Files:** `apps/android/.../net/ChatEngine.kt`

*Verified at ChatEngine.kt:670-682 — both self-device guards that iOS has are absent.*
(1) Every device from `GET devices/$peerUserId` is added with no filter, so when
`peerUserId` is my own id the sending device is included: the engine builds an Olm
session to itself and encrypts the note to the device that wrote it, and the server
stores a row that the sender's own sync then discards as an own-message. This also
makes the `targets.isEmpty() && peerUserId == tokens.userId` short-circuit dead code,
since targets is never empty for a self send. (2) My own other devices are then appended
unconditionally, so for a self send every linked device is targeted **twice** — two
ratchet advances for one note, the second row dropped by `on conflict do nothing`,
leaving the receiving ratchet to absorb a skipped message key. Hoist `myId` and `myDev`
above the peer loop, filter the peer loop with
`!(peerUserId == myId && it.id == myDev)`, and change the own-devices guard to
`if (myId != null && peerUserId != myId)`. Verify: single-device self send logs a target
count of 0; with one linked device, 1 — not 2.
**Conflicts:** 1.15 (same file). Sequence 1.14 then 1.15, or do both in one pass.

### 1.15 — Inbound sync skips by user identity instead of device identity
**Severity:** high · **Platform:** both mobile
**Files:** `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift`, `apps/android/.../net/ChatEngine.kt`

The sync loop skips own-sent messages with a *user*-level check
(`if m.sender_id == myId { ...; continue }`). But fan-out is addressed at **device**
granularity. In a normal conversation "sent by me" implies "I already hold the
plaintext," so the skip is correct; in Note to Self *every* message has
`sender_id == myId` — including one written on your other device and legitimately
encrypted to this one. This device holds a real decryptable ciphertext and throws it
away. Note to Self therefore never syncs across devices, contradicting the in-code
promises in both engines. The correct discriminator is already on the wire:
`sender_device_id` is set on send, stored, and returned on read. Compute
`fromThisDevice = m.sender_device_id == nil ? (m.sender_id == myId) : (m.sender_device_id == myDeviceId)`
and gate on `m.sender_id == myId && fromThisDevice`. The null fallback preserves legacy
rows with no device attribution; keeping the `sender_id == myId` conjunct means normal
1:1 chats are completely unaffected. **Follow-on to audit, not to apply blindly:**
messages decrypted on this path are appended with `isMine: false`; for a self-chat a note
synced from your other device *is* yours and should render right-aligned, so consider
`isMine = (m.sender_id == myId)` at those append sites — but inspect each one first, as
some may depend on the literal. **Risk: this is the main receive loop for every
conversation** — regression-test a normal 1:1 alongside.
**Conflicts:** 1.14 (Android ChatEngine.kt). Must run after 1.14.

### 1.16 — Create-conversation error string omits `self`
**Severity:** low · **Platform:** backend
**Files:** `backend/api/src/routes/conversations.ts`

Cosmetic. The fall-through validation error still reads
`"type must be 'direct' or 'group'"` though `type: 'self'` has been valid and handled
since Note to Self landed. Update the string. No behavioral change.
**Conflicts:** 3.2, 3.3 (conversations.ts). Trivially foldable into either.

## 1C. Maps interference

### 1.17 — iOS `addToAudience` permanently erases the sharer from existing viewers
**Severity:** critical · **Platform:** iOS
**Files:** `apps/ios/Voiid/Voiid/Networking/MapPresenceEngine.swift`

*Verified at MapPresenceEngine.swift:381-394.* `addToAudience` recreates the server map
share; the backend supersede ends the old share and publishes `loc_stop` for the **old**
share id to **all** its targets, including retained viewers. Each viewer's `receiveStop`
matches the old id, erases the sender-keyed inbound map key and the cached position. The
sender then redistributes the current key **only to the newly added members** —
`distributeMapKey(key, to: targets)` where `targets` is the added set — so every
pre-existing viewer drops all subsequent fixes with "no inbound map_key" forever, until
the sharer toggles visibility off and on. One-line fix: distribute to the full audience
(`audience.map(\.userId)`), exactly as `goVisible` already does at line 334. Re-sending
the same key is idempotent on receivers, which overwrite the same Keychain entry.
**Conflicts:** 1.18, 1.19, 1.20 (same file). This is the smallest and highest-value — run it first, alone.

### 1.18 — `loc_stop` cannot distinguish supersede from went-dark
**Severity:** high · **Platform:** all
**Files:** `backend/api/src/routes/location.ts`, `apps/ios/.../MapPresenceEngine.swift`, `apps/android/.../net/MapPresenceEngine.kt`

`signalStop` builds a `loc_stop` frame carrying only type, share_id, from_user_id and ts,
and `endShare` is used both for a genuine owner stop *and* for the create-time supersede.
Clients therefore treat every map-share recreation — `goVisible`, `setAudience`,
`addToAudience`, Android's `openShare` retry — as "sender went dark" and **erase the
cached position**, leaving the pin gone until a fresh durable `map_key` plus the next
5-minute-cadence fix arrive. That is the visible "map blips on every re-open." Add
`reason` (`superseded` | `ended`) and share `kind` (`map` | `conversation`) fields to the
frame in `signalStop`, threaded from `endShare` and the supersede loop; in both Map
engines' stop handlers, on `reason=superseded` retire the share id but **keep** the
inbound key and cached position. Fields are additive; old clients ignore them safely.
**Conflicts:** 1.17, 1.19, 1.20 (iOS engine); 1.22 (Android engine). Run after 1.17.

### 1.19 — iOS: stopping a chat live share erases the sender from the friends Map
**Severity:** high · **Platform:** iOS
**Files:** `apps/ios/.../MapPresenceEngine.swift`, `apps/ios/.../ChatEngine.swift`

`receiveStop` guards cross-feature `loc_stop` frames by **sender**, and only checks the
share id when a presence row exists. If a friend is map-visible but has no presence row
yet (waiting for first fix) or the row was pruned by the 8-hour age-out, a `loc_stop` for
their **chat** live share — e.g. its ordinary 15-minute expiry — falls through and erases
their map key, presence, and inbound-sender entry. The chat stream kills the map stream.
Record the inbound **map** share id per sender (persist beside the `inboundSenders` set,
sourced from the `map_key` envelope's `s` field — which requires passing it through the
`voiidMapControlReceived` post in `ChatEngine.swift:1714`, currently omitted for
`map_key`) and require the incoming stop's share id to match before erasing; an unknown
share id means not-ours. Android is already immune here because its handler is keyed by
share id — mirror that shape.
**Conflicts:** 1.17, 1.18, 1.20 (iOS engine); 1.15, 3.6 (ChatEngine.swift).

### 1.20 — iOS Map presence never resumes after process death
**Severity:** high · **Platform:** iOS
**Files:** `apps/ios/.../MapPresenceEngine.swift`, `apps/ios/.../MapShareAPI.swift`

`outboundShareId` is `@Published` in-memory state, never persisted and never reconciled
from `GET /location/shares`. The cold-launch resume restarts the location provider, but
every fix then dies on `guard let sid = outboundShareId`, and the foreground server-extend
is skipped. After any process kill the server row stays active — **viewers see "sharing"
while the client emits nothing** — until the user manually re-runs `goVisible`. Persist
`outboundShareId` and its expiry beside the existing visibility/key storage and restore in
`init`/`noteForegrounded`, or add a `GET /location/shares` reconciliation call. This
matches Android, which already persists share_id/share_key/expires_at and resumes. If the
row lapsed, re-run the `goVisible` path. The ghost hard-gate still governs, so this cannot
resurrect sharing for a ghosted user.
**Conflicts:** 1.17, 1.18, 1.19 (same file).

### 1.21 — iOS: 2-member group shares resume as 1:1 and misroute their durable stop
**Severity:** medium · **Platform:** iOS
**Files:** `apps/ios/.../LocationShareEngine.swift`, `apps/ios/.../Storage/LocationStore.swift`, `apps/ios/.../Storage/LocationSchema.swift`

`resumeOutboundIfNeeded` infers `isGroup: targets.count > 1`. A group with exactly one
other member resumes as a 1:1, so the durable `live_stop` is sent via
`ChatEngine.sendLocation` with the **group** conversationId on the **1:1 Double Ratchet**
path — a ratchet message addressed into an MLS conversation, so the durable stop is lost
for that case. (The WS stop and the expiry still work, which is why this is medium not
high.) Persist an `is_group` column on the outbound share row and read it on resume
instead of inferring from recipient count; needs a small SQLite migration in
`LocationSchema.swift`.
**Conflicts:** 1.23 (LocationShareEngine.swift).

### 1.22 — Android: reconciled shares silently skip the durable stop; groups misrouted
**Severity:** medium · **Platform:** Android
**Files:** `apps/android/.../net/LocationShareEngine.kt`

`refresh()` reconstructs every outbound share with `isGroup = false` and
`peerUserId = null`. `stopShare` then builds the durable `live_stop` with that context,
and `sendControl`'s 1:1 branch hits `conv.peerUserId ?: return` — so the durable E2EE
`live_stop` is **silently never sent for any share stopped after a process restart**, and
offline recipients keep rendering it until expiry; group shares never take the correct
group route. Read `isGroup` (kind) and `peerUserId` from the Room `LocationShareRow` the
engine already writes at share creation, instead of hardcoding. Also make `sendControl`
log a warning rather than silently returning when 1:1 context is missing.
**Conflicts:** 1.18 (Android MapPresenceEngine is a different file — no conflict), 1.24.

### 1.23 — iOS: sending a pin mid-live-share starves the fix stream
**Severity:** medium · **Platform:** iOS
**Files:** `apps/ios/.../Networking/LocationService.swift`

While a one-shot pin request is pending, the shared delegate routes **every** fix into the
one-shot branch and returns before calling `onFix`, so an active live share emits nothing
for up to the 10s one-shot timeout. `requestOneShot` also sets
`desiredAccuracy = kCLLocationAccuracyBest` and `fireOneShot` never restores the live
profile's `nearestTenMeters`, so a share outliving a pin runs at full-GPS power until
restarted. The `isLiveStreaming` flag correctly prevents the one-shot from *stopping* the
stream — only the starvation and the accuracy leak remain. Either give `requestOneShot`
its own short-lived `CLLocationManager`, or forward fixes to `onFix` even while a one-shot
is pending when `isLiveStreaming`, and restore the accuracy in `fireOneShot`.
**Conflicts:** 1.21 (LocationShareEngine.swift — different file, no conflict).

### 1.24 — Chat engines consume Map `loc_stop` with no ownership guard (latent)
**Severity:** low · **Platform:** both mobile
**Files:** `apps/ios/.../LocationShareEngine.swift`, `apps/android/.../net/LocationShareEngine.kt`

iOS `handleInboundStop` runs for every `loc_stop` including a friend's Map ghost —
inserting the map share id into `stopped`, calling `LocationStore.end` and
`LocationKeyStore.deleteKey` — currently no-ops **only because** chat keys use share-id
naming in a separate Keychain service and the DB row does not exist. Android `endInbound`
likewise. Neither has the explicit ownership guard the Map engines have. Add one: iOS
return unless the share is a known active inbound or in emitting/stopped; Android return
unless `inboundViews` or the chat keystore holds that share id. Zero behavior change
today; prevents a future key-naming or upsert change from reintroducing cross-stream
teardown.
**Conflicts:** 1.21, 1.22.

### 1.25 — Android: Map `loc_stop` ignored when key is only in the background store
**Severity:** low · **Platform:** Android
**Files:** `apps/android/.../net/MapPresenceEngine.kt`

`onStop` tests only the in-memory `inbound` map and never consults the
`MapInboundKeyStore` fallback the fix path uses. If a contact's `map_key` was captured
while the app was dead and no fix has decrypted in-process yet, their `loc_stop` is
dropped: the key survives and the contact stays in the persisted `waiting_senders` set.
Similarly a durable `map_off` processed only by background sync removes the key but never
updates `waiting_senders`, leaving "sharing — waiting for location" shown for someone who
went dark. In `onStop`, fall back to `MapInboundKeyStore.get(ctx, stopShareId)` and on
match remove the entry and erase the subject; in `onForeground`/`recomputeSubjects`, prune
any `waiting_senders` entry whose key exists in neither store.
**Conflicts:** 1.18 (same file).

### 1.26 — `docs/LOCATION.md` iOS Map provider spec contradicts shipped code
**Severity:** low · **Platform:** docs
**Files:** `docs/LOCATION.md`

Section 5's iOS bullet states "No `startUpdatingLocation` for the Map, ever," but
`MapLocationProvider.swift:120-143` deliberately runs a 25m-filtered
`startUpdatingLocation` foreground feed alongside significant-change monitoring — the
code comments explain the change (significant-change alone is ~500m, so the street-level
pin target was unreachable). Update the spec to describe the shipped design: filtered
`startUpdatingLocation` in foreground, significant-change for background/relaunch,
background delivery gated on Always authorization.
**Conflicts:** none.

## 1D. Memories lag

### 1.27 — iOS: full-resolution image decoded on the main thread at 30 Hz
**Severity:** critical · **Platform:** iOS
**Files:** `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift`

*Verified at StoryViewerView.swift:148:* `UIImage(contentsOfFile: url.path)` is called
directly inside a `@ViewBuilder`, so the file read plus full JPEG decode runs
synchronously **on the main thread** during view evaluation. Story images are capped at
10MB, so this is a multi-hundred-millisecond stall — and it re-decodes on **every** body
evaluation, which is invalidated at 30 Hz because the tick timer mutates `progress`
state. A still photo is therefore read from disk and decoded up to 30 times per second
for the full 5 seconds it is displayed. **This is the single largest lag source on iOS.**
Add `@State private var image: UIImage?`, populate it from `loadCurrent()` via
`Task.detached`, and decode with `CGImageSourceCreateThumbnailAtIndex` passing
`kCGImageSourceThumbnailMaxPixelSize` set to the screen's pixel width, so a 12MP photo is
decoded once at display size. The body then renders only `if let image`. Follow the
pattern already proven in `ClipsUIKit.swift:110-123`. Add a bounded `NSCache` (count ~6)
so stepping back does not re-decode. Verify with Instruments: main-thread decode work
during dwell should drop to zero.
**Conflicts:** 1.28, 1.30, 1.31, 1.33, 1.35, 1.36 (same file — this is the most contended file in the plan; see the sequencing note below).

### 1.28 — iOS: viewer media is inset by the safe area, producing a permanent black frame
**Severity:** critical · **Platform:** iOS
**Files:** `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift`

`.ignoresSafeArea()` is applied to `Color.black` **only**; the TabView, and therefore all
media inside it, is laid out inside the safe area — roughly 59pt of black at the top and
34pt at the bottom on a notched iPhone, on every story. `.statusBarHidden(true)` hides
status bar content but does not change insets. Move `.ignoresSafeArea()` off the backdrop
and onto the TabView / the player's `GeometryReader` content so media fills the physical
screen, then keep chrome readable by reading `geo.safeAreaInsets` explicitly in the chrome
stack. While there, replace the hardcoded `.padding(.top, 44)` with the real top inset —
44 is a guess at notch height and is wrong on SE and Dynamic Island devices. Clips already
does this correctly at `ClipFullscreenView.swift:58`. Verify on a notched device, an SE,
and iPad split view.
**Conflicts:** same cluster as 1.27.

### 1.29 — Both: fit-scaling against pure black letterboxes every non-9:16 photo
**Severity:** critical · **Platform:** both mobile
**Files:** `apps/ios/.../StoryViewerView.swift`, `apps/android/.../main/stories/StoryCommon.kt`

Both platforms fit the whole image inside the frame against a pure black box, so a 4:3
photo on a 19.5:9 phone leaves large black bands; on iOS this compounds with 1.28. Render
**two layers**, as both Signal platforms do: a backdrop using the same image at
fill/crop, heavily blurred and darkened, filling the frame; and the existing true-aspect
fit image unchanged on top. Signal-Android's `stories_post_fragment.xml` is literally a
`centerCrop` blur ImageView behind a `fitCenter` one; Signal-iOS does the same in code with
a `scaleAspectFill` view plus a dark `UIVisualEffectView`. **Build the backdrop from a
downsampled copy, not a second full-resolution decode**, or you trade black bars for memory
pressure. For video, derive the backdrop from the first frame (Android already retrieves
it; iOS can use `AVAssetImageGenerator`), falling back to a dark neutral rather than pure
black. E2EE-safe: the blur source is the already-decrypted local plaintext file.
**Conflicts:** 1.27, 1.28, 1.30-1.36 (iOS file); 1.30, 1.32 (Android StoryCommon.kt).

### 1.30 — Android: bitmaps decoded at full resolution into an unbounded, never-evicted cache
**Severity:** high · **Platform:** Android
**Files:** `apps/android/.../main/stories/StoryCommon.kt`

*Verified at StoryCommon.kt:58:* `BitmapFactory.decodeFile(p)` with no `Options` and no
`inSampleSize`, so a 12MP photo allocates roughly 48MB as ARGB_8888;
`inSampleSize` appears nowhere in the Android app. Compounding it, `thumbCache` is a plain
unbounded `HashMap` that is never evicted and is **shared between the tray cells and the
full-screen viewer**. Ten photo stories retains roughly 480MB — GC pressure at best, OOM at
worst, and the GC pauses read to the user as exactly the reported lag. (Note: the decode
itself is already off the main thread on `Dispatchers.IO`, so the mechanism here is memory
pressure, not a main-thread stall — unlike iOS.) Two-pass decode:
`inJustDecodeBounds` first, compute `inSampleSize` against the target display size, then
decode for real. Because `rememberStoryThumbnail` serves **both** the ~52dp tray cell and
the full-screen viewer, it needs a target-size parameter and **the cache key must include
that size**, or the tray's tiny bitmap gets reused in the viewer and appears blurry.
Replace the HashMap with an `LruCache` sized from `maxMemory() / 8`, cleared when the viewer
closes. Verify with the Memory Profiler that the heap plateaus, and explicitly test the
tray-then-viewer sequence for blurriness.
**Conflicts:** 1.29, 1.32 (same file).

### 1.31 — Both: prefetch is one deep, never crosses author boundary, cancelled on every step
**Severity:** high · **Platform:** both mobile
**Files:** `apps/ios/.../StoryViewerView.swift`, `apps/ios/.../Networking/StoryEngine.swift`, `apps/android/.../main/stories/StoryViewerView.kt`, `apps/android/.../model/StoriesStore.kt`

iOS warms only `index + 1`, and only *after* the current item finished downloading, so on a
cold context item 2 is serialized behind item 1's full round-trip. Android does the same
one-ahead prefetch inside a `LaunchedEffect(context.authorId, index, active)` that is
**cancelled on every index change** — a fast tapper kills each prefetch before it lands.
Neither prefetches across the author boundary, so every horizontal swipe between people is
a guaranteed cold start with a spinner on black. Both prefetch bytes only; the expensive
decode is still paid on display. Four parts: (1) depth 3, matching Signal-iOS's
`subsequentItemsToLoad = 3`; (2) when fewer than 3 items remain, pull the first items of the
**next author** into the window; (3) detach from the page's task scope — iOS
`Task.detached(priority: .utility)` with a `withTaskGroup` so items fetch in **parallel**,
the exact remedy already applied in `ClipFullscreenView.swift:136-146`; Android launch on
the store's `viewModelScope`; (4) warm the **decode**, not just the bytes, feeding
prefetched paths through the downsampled cache. Preserve the throttle intent of
`autoDownloadEligible` — cap concurrency at ~3 so this does not start 20 simultaneous R2
downloads, and consider gating cross-author prefetch on Wi-Fi.
**Conflicts:** 1.27-1.29, 1.33, 1.35, 1.36 (iOS); 1.32 (Android viewer). Depends on 1.27/1.30 landing first (needs the decode cache to warm).

### 1.32 — Android: mute toggle silently does nothing mid-story
**Severity:** high · **Platform:** Android
**Files:** `apps/android/.../main/stories/StoryCommon.kt`

Volume is set via `mp.setVolume(...)` **only** inside `setOnPreparedListener`, which runs
once in the `AndroidView` factory block; the `update` lambda handles `paused` but never
re-reads `muted`. So the mute control flips its icon and changes nothing audible until a
new VideoView is constructed for a different story. Fix as part of migrating to Media3
ExoPlayer (preferred: bind `volume` in the update lambda, set `RESIZE_MODE_FIT`,
`useController = false`, drive `playWhenReady` from paused). **Note the in-file comment
claiming "No ExoPlayer dependency exists in this app" is stale** — media3-exoplayer and
media3-ui already ship for the Clips work. If the migration is deferred, fix standalone:
VideoView has no public `setVolume`, so capture the MediaPlayer from the prepared listener
into a remembered ref and call `setVolume` from the update block — which is itself an
argument for just migrating.
**Conflicts:** 1.29, 1.30 (same file).

### 1.33 — iOS: `VideoPlayer` letterboxes unconditionally; new `AVPlayer` per story, no pool
**Severity:** high · **Platform:** iOS
**Files:** `apps/ios/.../StoryViewerView.swift`, `apps/ios/.../Main/Clips/ClipFullscreenView.swift`

`VideoPlayer(player:).disabled(true)` is the identical defect Clips already diagnosed and
fixed — SwiftUI's `VideoPlayer` always letterboxes (`videoGravity` is not settable) and
always brings its own controls; `.disabled(true)` suppresses interaction but removes
neither the chrome's compositing cost nor its layout. Separately, a fresh `AVPlayer(url:)`
is constructed inside `loadCurrent()` and the previous one torn down, so every forward tap
on a video story pays a full cold asset-load plus first-frame decode, showing a
ProgressView on black. Reuse `ClipPlayerLayerView` (a `UIViewRepresentable` over
`AVPlayerLayer`, currently `private` — promote it to a shared file or add a Stories
sibling) with `videoGravity = .resizeAspect`, and put the blurred backdrop from 1.29
behind it. Then add a small player pool keyed on story id, modeled on `ClipPlayerPool`,
keeping current and next warm. **Risk: player lifecycle leaks** — ensure both `stop()` and
the context-swipe path release. Test 5 videos, fast taps, author swipes, and confirm no
audio leaks from a page you have left.
**Conflicts:** iOS story cluster; **and `ClipFullscreenView.swift`, which collides with 2.1 and 2.4.** Coordinate: promote the shared player view in one small commit first.

### 1.34 — Android: no swipe-down dismiss; press-to-pause fires on touch-down
**Severity:** medium · **Platform:** Android
**Files:** `apps/android/.../main/stories/StoryViewerView.kt`

Two gesture defects in the root `pointerInput`. `detectTapGestures(onPress = ...)` sets
`paused = true; chromeVisible = false` immediately on touch-**down**, before the
tap-versus-long-press distinction resolves, so every ordinary advance-tap flickers the
chrome off and back on and pauses the timer for the touch duration; WhatsApp only pauses
after ~200ms. Wrap `tryAwaitRelease()` in
`withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis)` and only pause once that
elapses without release. Second, there is **no swipe-down-to-dismiss** on Android — users
can only leave via the system back button, while iOS has it. Add
`detectVerticalDragGestures` on the root Box translating the page with the finger and
calling `onClose()` past a threshold; prefer following the finger over a binary jump.
**Risk: gesture ordering with the enclosing HorizontalPager** — a vertical drag must not
steal the horizontal context swipe; test diagonal drags explicitly.
**Conflicts:** 1.31 (same file).

### 1.35 — iOS: TabView eagerly builds every author page, each with its own 30 Hz timer
**Severity:** medium · **Platform:** iOS
**Files:** `apps/ios/.../StoryViewerView.swift`

A plain `ForEach` inside a paged TabView (not a `LazyHStack`) means SwiftUI constructs a
player for **every** context up front, each installing its own
`Timer.publish(every: 1.0/30.0).autoconnect()` — with 12 authors that is 360 timer fires
per second. The inactive ones return early via `guard isActive`, which makes this a
secondary rather than primary lag contributor (1.27 dominates), but it scales with tray
size. Either hoist the tick into the parent and drive only the active page, or replace
TabView with `ScrollView(.horizontal) { LazyHStack { … } }.scrollTargetBehavior(.paging)`
— the construction Clips adopted for exactly this reason, and the analogue of
Signal-Android's `offscreenPageLimit = 1`. The second option changes swipe feel; verify
paging still snaps cleanly per author.
**Conflicts:** iOS story cluster.

### 1.36 — Both: chrome has no gradient scrim
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/ios/.../StoryViewerView.swift`, `apps/android/.../main/stories/StoryViewerView.kt`

White author names, timestamps and progress capsules are drawn directly over media with
nothing behind them; on a bright photo all of it is unreadable. Both WhatsApp Status and
Signal use top and bottom scrims. Add a top scrim (black→clear, ~140pt/dp) behind the
progress bar and header, and a bottom scrim behind the footer, on both platforms. Purely
visual, no behavioral risk.
**Conflicts:** iOS story cluster; 1.31, 1.34 (Android). Natural pairing with 2.4, which adds the same treatment to Clips.

### 1.37 — iOS: story caption never rendered
**Severity:** low · **Platform:** iOS
**Files:** `apps/ios/.../StoryViewerView.swift`

The caption exists on the model, is populated from the decrypted envelope with a proper
fallback, and is rendered on Android — but the iOS viewer never references it, so an iOS
viewer silently drops the sender's caption. Straight parity gap. Render it above the
footer, inside the bottom scrim from 1.36, matching Android's placement and styling.
**Conflicts:** iOS story cluster.

> **Sequencing note for the iOS stories cluster (1.27, 1.28, 1.29, 1.31, 1.33, 1.35,
> 1.36, 1.37).** Eight items land in one file. Do **not** parallelize them. Run as one
> sequenced workstream in this order: 1.27 (decode) → 1.28 (safe area) → 1.29 (backdrop)
> → 1.33 (player) → 1.35 (lazy pages) → 1.31 (prefetch) → 1.36 (scrim) → 1.37 (caption).
> The first three are the user-visible win and could ship as their own release.

---

# TIER 2 — Redesigns

## 2A. Reels / creator UI

### 2.1 — Creator-profile grid tiles are dead
**Severity:** high · **Platform:** both mobile
**Files:** `apps/ios/.../Clips/CreatorProfileView.swift`, `apps/ios/.../Clips/ClipFullscreenView.swift`, `apps/android/.../clips/CreatorProfileView.kt`, `apps/android/.../clips/ClipFullscreenView.kt`

Tiles have **no tap handling on either platform** — iOS builds a ZStack with
`.contentShape(Rectangle())` but no Button or gesture; Android's tile is a plain Box with
no `clickable`. Root cause: the fullscreen pager only indexes into the Explore feed, so
there was nothing to open. Generalize the pager to accept an injected clip list plus a
load-more closure (map the creator clip row into the pager row type; reuse the existing
player pool, the asymmetric `[i-1..i+2]` preload window, and the playback-URL TTL cache
unchanged — playback URL only needs a clip id). Then wrap each iOS tile in
`Button { openIndex }.buttonStyle(.plain)` presented via `fullScreenCover`, and add
`.softClickable` plus a nav destination on Android. This also lets the Following-feed tiles
open the clip rather than the current workaround of opening the creator. **Do not change
tile shape or grid geometry — 3 columns, 2pt gutters, 9:16 is founder-locked.**
**Conflicts:** 2.2 (CreatorProfileView both platforms), 2.4, 2.5 (ClipFullscreenView), 1.33 (iOS ClipFullscreenView).

### 2.2 — Modern creator-profile header
**Severity:** high · **Platform:** both mobile
**Files:** `apps/ios/.../Clips/CreatorProfileView.swift`, `apps/android/.../clips/CreatorProfileView.kt`

The header is a flat stack: bare 84pt circle avatar, a 13pt seal in `VoiidColor.primary` —
the same color as every button, so it does not read as a badge — and a full-width 44pt
Follow rectangle with no state animation. Redesign **using existing tokens only**: (1) 96pt
avatar with a 2.5pt `strokeBorder` linear-gradient ring (primary→accent, topLeading→
bottomTrailing) and a 3pt background gap; (2) stats keep their beside-avatar position (the
above-the-fold rationale is documented in-file), value in rounded 20 bold, 1×24pt divider
hairlines between, press style on each; (3) a new shared `VerifiedSeal` component at 16pt
in `VoiidColor.accent` — amber means rare/must-be-seen per the theme file — with
hierarchical rendering on iOS; (4) replace the full-width button with a two-up 40pt row:
Follow filled primary flipping to `fieldFill` + 1pt border "Following" with
`spring(response: 0.3, dampingFraction: 0.7)` and a success haptic, second slot "Edit
profile" (self) or "Share profile" (others); (5) 3-line bio clamp with a "more" expander
and a link row. **Never add a Message button** — the reachability rule is documented at
`CreatorProfileView.swift:12-16`. Keep the aspect-ratio-on-the-cell grid fix and its
comment intact.
**Conflicts:** 2.1, 2.3.

### 2.3 — Android parity: creator edit sheet, tappable profile link
**Severity:** medium · **Platform:** Android
**Files:** `apps/android/.../clips/CreatorProfileView.kt`, `apps/android/.../model/CreatorStore.kt`, `apps/android/.../net/CreatorService.kt`

Android renders nothing for your own profile — there is no Edit affordance — and has no
profile-edit sheet at all (the existing sheet edits a *clip*); iOS has both. Port
`CreatorEditSheet` as a `ModalBottomSheet` with display name, bio and link fields saving
through `CreatorStore` (add an `updateProfile` call to `CreatorService` if missing).
**Deliberately do not send the handle field** — iOS omits it to avoid burning the server's
30-day rename window, and the rationale is documented in-file. Also make `link_url`
tappable via `LocalUriHandler` **only when `Uri.parse(it).scheme != null`**, mirroring
iOS's parse-before-Link guard; today it is dead text.
**Conflicts:** 2.1, 2.2.

### 2.4 — Fullscreen player chrome: scrim, 44pt targets, like pop, inline Follow chip
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/ios/.../Clips/ClipFullscreenView.swift`, `apps/android/.../clips/ClipFullscreenView.kt`

Chrome is white text and icons drawn directly on video with no scrim, so captions are
illegible over bright clips. Add a bottom gradient covering ~40% height,
`[.clear, .black.opacity(0.8)]` — the exact pattern Signal-iOS uses in
`StoryItemMediaView` — plus a shallow ~120pt top gradient behind the back/mute row, and
fade the scrim together with the chrome on pause/hide as Signal does. Also give right-rail
actions 44pt hit frames with rounded 12 semibold counts; add a spring like-pop
(`scaleEffect` 1→1.3→1, `.symbolEffect(.bounce)` where available) — the heart already
flips to `VoiidColor.error`; add an inline Follow capsule chip after the author name when
not following, wired to the existing toggle and hidden when following. Mirror on Android.
**Do not touch the pager/preload/player-pool code or the tap-to-mute and hold-for-speed
gestures.**
**Conflicts:** 2.1, 2.5; 1.33 (iOS).

### 2.5 — Grid-to-player zoom transition
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/ios/.../Clips/ClipsFeedView.swift`, `apps/ios/.../Clips/ClipFullscreenView.swift`, `apps/android/.../clips/ClipsFeedView.kt`, `apps/android/.../clips/ClipFullscreenView.kt`

Tapping a grid tile presents the player as an unrelated modal with no visual connection to
the tapped thumbnail, unlike Instagram's shared-element zoom. iOS: adopt
`.navigationTransition(.zoom(sourceID:in:))` with `.matchedTransitionSource` on the tapped
tile, **availability-gated to iOS 18+** with the current `fullScreenCover` as fallback.
Android: wrap the feed grid and player route in `SharedTransitionLayout` (Compose 1.7+)
with `sharedElement` modifiers, default nav animation as fallback. **Medium risk** —
transition APIs interact badly with lazy-grid recycling. Ship behind availability checks
and **never let this block 2.1**, which is the actual playability fix. Grid geometry and
pager performance work must be unchanged.
**Conflicts:** 2.1, 2.4, 2.6.

### 2.6 — Unify the scope control as branded pills; clean up the feed header
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/ios/.../Clips/ClipsFeedView.swift`, `apps/android/.../clips/ClipsFeedView.kt`

iOS uses a stock UIKit segmented `Picker` for Explore/Following — the one visibly non-Voiid
control on the screen — while Android already ships branded pills. Replace the iOS Picker
with the same pill pair: capsule, selected = primary fill + textOnPrimary, unselected =
fieldFill + textSecondary, rounded 14 semibold, soft press style, with
`matchedGeometryEffect` sliding the filled capsule between labels. Header cleanup on both:
replace the generic `person.circle` button with the user's actual creator avatar in a 28pt
circle (reuse the thumbnail component plus the `creators.me` avatar, initial fallback) as
the identity anchor, and swap the unrecognizable my-clips glyph for `square.grid.3x3`,
aligning both platforms to the same arrangement. **Preserve the scope-switch lazy-load
behavior** — following loads on first switch only.
**Conflicts:** 2.5, 2.7, 2.8.

### 2.7 — Unify empty states; staggered grid fade-in
**Severity:** low · **Platform:** both mobile
**Files:** `apps/ios/.../Clips/ClipsUIKit.swift`, `apps/ios/.../Clips/ClipsFeedView.swift`, `apps/android/.../clips/ClipsUIKit.kt`, `apps/android/.../clips/ClipsFeedView.kt`

Empty states are a dimmed symbol plus two lines, and the iOS Following empty state bypasses
the shared component entirely — hand-rolled inline with no CTA — so scopes and platforms
drift. Add a `followingNobody` kind to the shared component on both platforms with an
"Explore creators" CTA that switches scope back to Explore, and route the iOS inline state
through it. Treatment: 72pt `fieldFill` circle behind the icon with the icon in primary,
`.symbolEffect(.pulse)` on iOS 17+, an infinite alpha pulse on Android; title upgraded from
17 to 22 semibold; CTA keeps the existing primary capsule. Add a ~250ms staggered opacity
fade-in when the first page lands. **Keep skeletons in exact final grid geometry as they
already are, and preserve the error-beats-empty ordering everywhere.**
**Conflicts:** 2.6, 2.8.

### 2.8 — Failed-upload tile: sub-44pt Retry/Dismiss targets
**Severity:** low · **Platform:** both mobile
**Files:** `apps/ios/.../Clips/ClipsFeedView.swift`, `apps/android/.../clips/ClipsFeedView.kt`

On the failed-upload tile overlay, Retry and Dismiss are 10pt text buttons — far below the
44pt/48dp minimum, **on the one tile where a mis-tap discards a video the user already paid
an export for.** Give both ≥44pt frames: Retry as a small capsule (`fieldFill` on the dark
overlay, rounded 12 semibold white text), Dismiss as a 44pt-frame quiet text button
beneath. Keep the existing ordering (Retry first, Dismiss quiet — deliberate per the
in-file comment) and the retry gating.
**Conflicts:** 2.6, 2.7.

## 2B. Clip camera and editor

### 2.9 — iOS: dedicated segmented `ClipCameraView`
**Severity:** high · **Platform:** iOS
**Files:** `apps/ios/.../Clips/ClipCameraView.swift` (new), `apps/ios/.../Clips/ClipComposerFlow.swift`, `apps/ios/.../Stories/StoryCameraView.swift`

The iOS clip camera was built as a *mode* of the single-shot story camera: it fires
`onCapture` and dismisses on the first finalize, and the composer accepts exactly one URL.
So iOS has no multi-take, no undo, and no banked progress, while Android already has all
three. Create a new `ClipCameraView.swift` reusing the proven `AVCaptureSession` +
private-serial-queue pattern from the story camera **including its salvage logic** — a
recording cut short by the cap sets `AVErrorRecordingSuccessfullyFinishedKey` and must be
kept, not discarded. Changes vs the story camera: (1) one `AVCaptureMovieFileOutput` take
per start/stop into `clip_seg_<uuid>.mov`, accumulating a `segments: [URL]` array with
banked-duration accounting; (2) undo-last-take that deletes the file and **re-derives**
banked duration from the remaining files rather than subtracting the last measured value,
which drifts; (3) replace the 1-second wall-clock Timer cap with
`movieOut.maxRecordedDuration = CMTime(seconds: 90 - banked)` per take, driving the pill
from `recordedDuration`; (4) on commit, concatenate takes into one
`AVMutableComposition` exported with `AVAssetExportPresetPassthrough` (all takes share
codec and session settings, so no re-encode), falling back to a 1080p preset if passthrough
fails, then pass the single URL to the **existing** `accept(url:)`. A single take must be
returned as-is with no transcode. Wire this in place of the `StoryCameraView(mode: .clip)`
cover; leave the stories camera otherwise untouched.
**Conflicts:** 2.12, 2.13, 2.14, 2.16 (same new file). This is the foundation — must land first among the iOS camera items.

### 2.10 — Android: record at FHD so in-app clips can reach the 1080p rung
**Severity:** high · **Platform:** Android
**Files:** `apps/android/.../clips/ClipCameraView.kt`, `apps/android/.../net/ClipQuality.kt`

Concrete latent bug with verified arithmetic. The Recorder is built with
`QualitySelector.from(Quality.HD)` = 1280×720. The export ladder skips a rendition when
`sourceEdge < quality.longEdge * 0.9`, and `FHD.longEdge = 1920`, so the FHD rung requires
a source long edge ≥1728. An in-app recording's long edge is 1280, which fails
unconditionally — **every clip recorded in-app on Android is silently capped at 720p while
gallery imports produce 1080p.** The code's own comment reasons about avoiding 4K and states
the ladder tops out at 1080p, which is an argument for `Quality.FHD`, not `HD`; comment and
code disagree. Change to
`QualitySelector.from(Quality.FHD, FallbackStrategy.higherQualityOrLowerThan(Quality.HD))`
— the fallback strategy is required so devices with no 1080p profile still bind. Update the
comment. Expect ~2× larger cache files per take; the 100MB cap and the per-rung byte-cap
drop already handle oversize output.
**Conflicts:** 2.11, 2.12, 2.13, 2.14.

### 2.11 — Android: one progress segment per take
**Severity:** low · **Platform:** Android
**Files:** `apps/android/.../clips/ClipCameraView.kt`

Comment/code mismatch: the comment promises "one bar per take," but the implementation
draws a **single** proportional box whose width is total/cap, so there are no per-segment
ticks and the undo affordance has no visual anchor. The enclosing Row already sets
`spacedBy(2.dp)`, which only matters with more than one child — confirming the intent.
Iterate the segments list and emit one box per finished segment proportional to its
duration, then one more for the in-flight segment while recording. **Hoist the duration
reads out of composition** — `MediaMetadataRetriever` on every recomposition is a
main-thread file read; cache duration alongside the File when the segment is added. Keep
the existing color rule (error while recording, white otherwise). Matches Instagram's
white segment ticks.
**Conflicts:** 2.10, 2.12, 2.13, 2.14.

### 2.12 — Both: viewfinder hardware controls
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/android/.../clips/ClipCameraView.kt`, `apps/ios/.../Clips/ClipCameraView.swift`

Neither camera has torch, pinch-to-zoom, tap-to-focus, or double-tap-to-flip — no
`CameraControl`, `videoZoomFactor`, `torchMode` or focus code exists in either file.
Instagram has all four. Purely additive control-plane code touching no recording or filter
logic. **Android:** the `Camera` returned by `bindToLifecycle` is currently discarded —
capture it into state first. Then add `pointerInput` blocks on the preview:
`detectTransformGestures` driving `setZoomRatio` clamped to the reported min/max, and
`detectTapGestures(onDoubleTap = flip when not recording, onTap = startFocusAndMetering
via meteringPointFactory)`. Add a torch button gated on `hasFlashUnit()`. This mirrors
Signal-Android's verified pattern in its `CameraScreen.kt`. **iOS:** pinch →
`videoZoomFactor` clamped to `activeFormat.videoMaxZoomFactor`, wrapped in
lock/unlockForConfiguration; tap → `focusPointOfInterest` and `exposurePointOfInterest`
converted via `captureDevicePointConverted(fromLayerPoint:)`; torch → `torchMode` guarded
by `hasTorch`.
**Conflicts:** 2.9 (must run after), 2.10, 2.11, 2.13, 2.14.

### 2.13 — Both: per-segment speed control (0.3×–3×) applied at export
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/android/.../clips/ClipCameraView.kt`, `apps/android/.../clips/ClipSegments.kt`, `apps/ios/.../Clips/ClipCameraView.swift`

No speed control exists anywhere. Instagram exposes 0.3/0.5/1/2/3× on the record rail,
captured **per segment**. Always record at 1× and store the chosen speed **next to** the
segment, applying it at join/export — this preserves the existing architecture where the
editor produces only an edit description and nothing re-encodes until export, and keeps the
shutter responsive. **Android:** change the segment list from `File` to a
`data class Take(file, speed, durationMs)`; a rail button cycles the speed for the *next*
take. **Critically, the 90s cap accounting must count output seconds** — divide each take's
recorded duration by its speed before adding to banked, or a 0.3× take overshoots the
backend cap. In `concatenate`, build each `EditedMediaItem` with
`Effects(listOf(SonicAudioProcessor().apply { setSpeed(s) }), listOf(SpeedChangeEffect(s)))`
— both classes are confirmed present in the pinned media3 1.4.1 artifacts. The single-take
passthrough shortcut must be skipped whenever speed ≠ 1, since that now requires a real
transcode; the composer's `List<File>` signature must move to the new take type.
**iOS:** after inserting each take's time range, call `composition.scaleTimeRange(range,
toDuration: CMTime(seconds: takeDuration/speed))`; passthrough export is invalid for scaled
segments, so use the 1080p preset when any speed ≠ 1. Audio pitch scales naively, which is
acceptable for v1 — Instagram's 2× audio is also pitched up.
**Conflicts:** 2.9 (after), 2.10, 2.11, 2.12, 2.14.

### 2.14 — Android: live filter carousel over the camera preview
**Severity:** medium · **Platform:** Android
**Files:** `apps/android/.../clips/ClipCameraView.kt`, `apps/android/gradle/libs.versions.toml`, `apps/android/app/build.gradle.kts`

The in-app camera's own docstring names this as a core reason it exists — "no way to ever
put the filter strip in the live preview" — yet the strip still only appears post-capture.
Root cause: CameraX is pinned at 1.3.4, predating stable CameraEffect/media3 interop.
Upgrade to 1.4.x and add `androidx.camera.media3:media3-effect`, which provides
`Media3Effect`, a `CameraEffect` running a media3 effect list on the camera stream. Bind it
into the `UseCaseGroup` with target **PREVIEW ONLY** and call `setEffects(...)` — reusing
the **existing** RgbMatrix/RgbFilter chains from the editor completely unchanged.
**Recording must stay clean (unfiltered):** return the selected filter alongside the
segments and use it to pre-populate the edit where the composer builds it, so the existing
exporter bakes the filter exactly once. This preserves non-destructive editing and avoids
double-applying the color matrix. UI: horizontal swipe pages through the filter list with
the label flashed center-screen. **Risk: the CameraX upgrade is the risky half** — the
stories camera shares those artifacts, so regression-test story capture too. If the upgrade
must wait, the fallback is a manual `CameraEffect` + `SurfaceProcessor` running the same
matrices in a GL shader: more code, identical contract. **Do not redesign the filter
values.**
**Conflicts:** 2.10-2.13 (same file); shared Gradle files make this a poor parallel candidate.

### 2.15 — iOS: live-filtered viewfinder via data output + AssetWriter
**Severity:** medium · **Platform:** iOS
**Files:** `apps/ios/.../Clips/ClipCameraView.swift`, `apps/ios/.../Clips/ClipEditor.swift`

iOS cannot show a filtered viewfinder with its current architecture: it records through
`AVCaptureMovieFileOutput` and previews through `AVCaptureVideoPreviewLayer`, which cannot
render CIFilters. In the new `ClipCameraView`, replace the preview layer with
`AVCaptureVideoDataOutput` (plus audio data output) → per-frame
`CIImage(cvPixelBuffer:)` → the **existing** `ClipFilter.apply(to:)` unchanged →
`CIContext.render` into an `MTKView`. Record by appending the **clean, unfiltered** sample
buffers to an `AVAssetWriter` configured from
`recommendedVideoSettingsForAssetWriter(writingTo: .mp4)`. This is Signal-iOS's proven
shape, verified in its `CameraCaptureSession.swift`, with separate video/audio/recording
queues. Note `AVCaptureMovieFileOutput` and `AVCaptureVideoDataOutput` do not usefully
coexist in one session, so this **replaces** the movie output inside the clip camera only —
stories untouched. Carry the selected filter into the edit so it is baked exactly once at
export. **Higher risk:** writer session timing, orientation/mirroring transforms, and
dropped-frame handling — which is why it is sequenced after the cheaper wins and copied
from a battle-tested source. Side benefit: the writer produces real `.mp4`, fixing the
container mislabel.
**Conflicts:** 2.9 (must run after), 2.12, 2.13, 2.16.

### 2.16 — Both: looping editor preview with a frame-filmstrip trim/cover scrubber
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/ios/.../Clips/ClipEditor.swift`, `apps/android/.../clips/ClipEditor.kt`

Two related weaknesses. (1) The editor preview is a **still frame**, not video — iOS renders
an image from `AVAssetImageGenerator`, Android a bitmap from `MediaMetadataRetriever`. You
cannot judge a trim, see a filter on motion, or hear audio at all, so the mute toggle is a
blind switch. (2) Trim is two abstract labelled sliders with no frame thumbnails, so there
is no visual anchor for where start/end land; the cover scrubber has the same problem.
**iOS:** replace the still with `AVPlayer`; drive the live filter preview by setting
`playerItem.videoComposition = AVVideoComposition(asset:applyingCIFiltersWithHandler:)`
using the **same closure already used for export**; loop the trimmed range with a periodic
time observer seeking back to trim start; bind mute to `player.isMuted`. Replace the sliders
with a filmstrip of ~10 generated thumbs under two draggable handle overlays.
**Android:** use ExoPlayer (already a dependency) in an `AndroidView(PlayerView)`; apply the
live filter with `setVideoEffects(edit.filter.effects())` — confirmed present in the pinned
media3 1.4.1 and reusing the existing effect chain untouched; loop the trim via
`ClippingConfiguration` rebuilt **on handle release only**, since rebuilding forces a seek —
debounce rather than doing it per frame; build filmstrip thumbs with
`getFrameAtTime(..., OPTION_CLOSEST_SYNC)` on `Dispatchers.IO`. The cover scrubber reuses
the same filmstrip with a **single** handle (exactly Instagram's "Edit cover"), and the
upload-wins precedence must stay untouched. Release the player on dispose and pause on
backgrounding.
**Conflicts:** 2.15 (iOS ClipEditor.swift), 2.9.

### 2.17 — Both: camera-first entry with an in-viewfinder gallery thumbnail
**Severity:** low · **Platform:** both mobile
**Files:** `apps/ios/.../Clips/ClipComposerFlow.swift`, `apps/android/.../clips/ClipComposerFlow.kt`

Both platforms open on a two-tile Camera/Gallery chooser, costing an extra screen and an
extra decision before the user can record; Instagram opens straight into the viewfinder with
the gallery as a small corner thumbnail. Make the camera the first screen and move gallery
access into the viewfinder, collapsing the tile menu. Imported videos must join the same
existing `accept()` path so duration validation and cap checks are unchanged. On Android the
SOURCE step disappears from the step enum, so the header back-stack logic must be updated —
EDIT now backs out to the camera. Ideally an import mid-session appends to the segment list
as Instagram does; v1 may keep import-replaces-takes behind a confirm dialog.
**IMPORTANT SEQUENCING: do this only after the camera is IG-grade (2.9-2.16)** — promoting
today's camera to the front door would showcase exactly the gaps this work closes.
**Conflicts:** 2.9 (iOS composer). Must run last in this group.

### 2.18 — iOS: StoryCameraView cap and container hygiene
**Severity:** low · **Platform:** iOS
**Files:** `apps/ios/.../Stories/StoryCameraView.swift`

Two small correctness issues in the shared story camera, independent of the clip work. (1)
The duration cap is a 1-second wall-clock Timer rather than a capture-time signal, so a
recording can overshoot by up to a second; today that survives only because the intake check
allows a second of tolerance. Replace with `movieOut.maxRecordedDuration` set before
`startRecording`, keeping the existing salvage path intact — hitting the max sets the
successfully-finished key and that branch already keeps the file correctly. The UI timer may
remain for display. (2) Container mislabel: the file is written as `.mov` while the callback
contract comment says `video/mp4`. Harmless today only because the exporter re-encodes, but
wrong the moment a caller trusts the label — correct the comment, and preferably let stories
keep `.mov` while the new clip camera owns real mp4. If 2.9 lands, the clip camera mode
becomes dead and should be removed along with its video-only branches.
**Conflicts:** 2.9 (reads this file). Run after 2.9.

## 2C. Game invite banner

### 2.19 — Banner shows the sender's profile name instead of the saved contact name
**Severity:** high · **Platform:** both mobile
**Files:** `apps/ios/Voiid/Voiid/Games/InviteBanner.swift`, `apps/android/.../main/games/InviteBanners.kt`

The banner was built off the server payload alone and never wired to the local
`UserDirectory`, so it prints the inviter's self-chosen profile name even when the invitee
has that person saved in their address book as something else. `inviter_id` **is** already
carried in the payload and unused on both platforms. This is internally inconsistent: the
push notification for the *same* invite already resolves through the directory, so a
backgrounded user sees "Mum" and a foregrounded user sees "Priya Sharma". iOS: replace the
raw name with `UserDirectory.shared.displayName(invite.inviter_id ?? "", fallback:
invite.inviter_name)`, mapping a resulting literal "Unknown" to "Someone" so the sentinel
never renders; the directory is `@MainActor` with a synchronous in-memory mirror, so calling
it inside the SwiftUI body is legal. Android: the same, calling the idempotent
`UserDirectory.init(LocalContext.current)` first if the composable cannot assume
initialization. Resulting precedence: saved contact → local full name → local phone → local
username → server-sent name → "Someone", **never the raw uuid**.
**Conflicts:** 2.21, 2.23, 2.24.

### 2.20 — `POST /games/matches` has no reachability gate
**Severity:** high · **Platform:** backend
**Files:** `backend/api/src/routes/games.ts`, `backend/api/src/routes/reachability.ts`

The endpoint validates only UUID shape and self-exclusion on `opponent_ids`, then the
catalog's seat count. It never checks a conversation, a contact link, or the reachability
model. **Any authenticated user who learns or enumerates a victim's user id can mint
"waiting" matches naming them**, and `GET /games/invites` — keyed only on
`player_ids @> [me]` — surfaces a banner carrying the stranger's name. This bypasses the
mutual-contact and username+PIN gates ordinary messages must pass. The E2EE invite *message*
would fail without a session so no chat bubble gets through, but the banner is driven purely
by the match row and appears anyway — a spam vector plus unearned profile-name disclosure.
Before the insert, verify every id in the filtered opponents array shares an accepted direct
conversation with the caller: join conversations to conversation_members twice on
`c.type = 'direct'` with both members `left_at is null` **and** `request_state = 'accepted'`
— the same join shape as the reachability idempotency query plus the request_state filter
that query omits. Return 403 if any opponent fails. Solo matches are unaffected since
opponents is empty. Low risk: the only legitimate client flow picks opponents from existing
direct conversations.
**Conflicts:** 3.13 (games.ts).

### 2.21 — No way to decline a live game invite anywhere in the app
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/ios/.../Games/InviteBanner.swift`, `apps/android/.../main/games/InviteBanners.kt`

The banner's live branch renders only a "Play" capsule; the dismiss affordance exists only
in the **dead** branch. The chat bubble likewise offers only "Tap to play," and the system
notifications carry no action buttons. So an invitee cannot turn down an invite until it has
already expired. Add a secondary "Decline" ghost button in `textSecondary` beside the Play
capsule in the live branch of both files, wired to the **existing** `onDismiss` closure each
screen already passes in — which already marks the id locally and calls the decline
endpoint. **No backend work is required:** the decline route is idempotent and only mutates
a row still in `waiting`, so a duplicate or racing tap is harmless.
**Conflicts:** 2.19, 2.23, 2.24.

### 2.22 — Chat invite bubble renders a sender-asserted name verbatim
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/ios/.../Main/ChatDetailView.swift`, `apps/android/.../main/ChatUI.kt`

The invite's `meta.from` is written by the **sender** from their own directory row and is
then rendered verbatim to the invitee as the bubble's "from X" line. The invitee's own saved
contact name never wins, and **a modified client can put any arbitrary string there,
including another person's name.** Signal by contrast attributes a message to the
authenticated sender from the envelope and resolves the display name from the local
recipient store at render time — a name arriving inside a payload is a profile record to
store, not a string to render as attribution. Voiid's own notification path already does the
right thing. Render `UserDirectory.displayName(message.senderId, fallback: meta.from)` on
both platforms; `senderId` is already on the message model. **Keep `meta.from` in the wire
format unchanged** for older clients and for the pre-marker human line.
**Conflicts:** 3.6 (ChatDetailView.swift, ChatUI.kt).

### 2.23 — Sender-side resolution encodes the literal "Unknown" as the inviter's name
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/ios/.../Networking/GamesEngine.swift`, `apps/android/.../net/GamesEngine.kt`

When building the invite meta, both engines resolve the sender's own name with an
empty-string fallback. An empty fallback is **rejected** by the resolver, so when the user's
own row is not yet in the local directory the call returns the literal sentinel "Unknown"
rather than an empty string. The encoder only guards against empty/blank, so the sentinel
sails through and the message reads "🎮 Unknown invited you to Tic Tac Toe," with the bubble
showing "from Unknown". The window is a fresh install that sends an invite before a profile
fetch has written the own-row — the code path is certain, the frequency is a hypothesis
needing a fresh-install repro. At both call sites, map a result equal to "Unknown" to `""`
so the existing empty-guard produces "Someone invited you to…". Optionally prefer the
session profile store's own full name before falling back to the directory.
**Conflicts:** 2.19.

### 2.24 — iOS invite banner flashes the grey "Missed" state on its first frame
**Severity:** low · **Platform:** iOS
**Files:** `apps/ios/.../Games/InviteBanner.swift`

`remaining` is initialized to zero and `dead` is computed as
`invite.missed || remaining <= 0`, but the `.task` that seeds `remaining` from
`expires_at` runs only **after** the first render — so every live invite renders one frame as
dead: grey card, "Missed invite" title, an ✕ instead of Play. Android does not have this bug
because it seeds the countdown inside `remember`. Either add an `init` seeding the state
directly, or make `dead` independent of the state by computing it as
`invite.missed || invite.expires_at <= GameInvite.nowMs()`. Keep the `.task` loop for the
per-second countdown.
**Conflicts:** 2.19, 2.21.

### 2.25 — iOS `PendingInvite` throws `keyNotFound` on any omitted key
**Severity:** low · **Platform:** iOS
**Files:** `apps/ios/.../Networking/GamesAPI.swift`

Known Swift Codable bug class: the struct declares property defaults for `overs`,
`sent_at`, `expires_at` and `missed`, but Swift's **synthesized** Decodable conformance
ignores property default values — each throws `keyNotFound` if the server omits the key. One
throw fails the entire array decode, and the failure is swallowed invisibly because the poll
wraps the call in `try?`, so the user would simply see no invite banners ever with no error
surface. Currently latent — the backend always emits every key — but Android is unaffected
because kotlinx defaults *do* apply, so the two platforms would fail asymmetrically. Give
the struct an explicit `init(from decoder:)` using `decodeIfPresent` for those four fields
with the current defaults, keeping `decode` for the genuinely required ones.
**Conflicts:** none.

### 2.26 — Android invite banner bypasses the `VoiidFont` token
**Severity:** low · **Platform:** Android
**Files:** `apps/android/.../main/games/InviteBanners.kt`, `apps/android/.../main/games/GamesHomeScreen.kt`

The file contains **zero** references to `VoiidFont` — it sets raw `sp` sizes with separate
weights. `VoiidFont.rounded` is the Nunito family, so the Android banner draws in the
platform default typeface while the equivalent iOS banner uses the brand font: the same
component rendering in two different typefaces across platforms. Colors, spacing and radii
**are** correctly tokenized; only typography drifted. Replace each size/weight pair with
`VoiidFont.rounded(...)` — 14 semibold title, 12 subtitle, 13 bold Play label. The same raw-sp
drift exists in the surrounding home screen and can be swept in the same pass. Visual-only,
moves Android toward the iOS rendering.
**Conflicts:** 2.19, 2.21, 2.24.

### 2.27 — Invite banner design spec (incl. the avatar blocker)
**Severity:** low · **Platform:** both mobile
**Files:** `apps/ios/.../Games/InviteBanner.swift`, `apps/android/.../main/games/InviteBanners.kt`, `apps/ios/.../DesignSystem/Components.swift`, `apps/android/.../ui/components/Components.kt`

Target design, entirely within existing tokens. **Live:** primary at 0.12 alpha on a large-
radius container, 48pt game-art tile with its runtime lookup and glyph fallback, title
"<resolved name> wants to play" at rounded 14 semibold, subtitle "<game> · <settings> ·
<m:ss> left" at rounded 12 secondary, trailing Play capsule plus the Decline ghost from 2.21.
The countdown may shift to `VoiidColor.warning` under 60 seconds so the deadline reads
without adding motion. **Missed:** flat surface card, single ✕. **Blocker on putting the
inviter's face on the banner:** `VoiidAvatar` is placeholder-only on **both** platforms — it
draws a wordmark and accepts only a `size` parameter, with no photo URL or initials. Extend
that shared component first rather than inlining an image loader into the banner.
**Name-disclosure rule for this surface:** saved contact name → profile full name →
@username, in that order; a phone number may appear **only** when this device's own address
book supplied it, because the backend never returns raw numbers to peers. **Do not add any
field to the push payload** — the content-free-wake-then-local-decrypt architecture is
deliberate and already Signal-grade.
**Conflicts:** 2.19, 2.21, 2.24, 2.26 (banner files).

---

# TIER 3 — New builds

## 3A. Conference calls (escalate 1:1 → group)

### 3.1 — Ad-hoc call-scoped rooms and escalation endpoints
**Severity:** high · **Platform:** backend
**Files:** `backend/api/src/routes/calls.ts`, `database/migrations/030_call_conference.sql`

Today the only multi-party room is keyed by conversation_id, so escalating a 1:1 would force
creating a group conversation — granting the added stranger persistent messaging rights,
which the product forbids (the same principle as "a follow is not a messaging right"). Add:
(1) `POST /calls/:id/escalate` — requester must be a participant of the live call **and**
allowed to reach the invitee (mutual contact via contact_sync, or an existing accepted
conversation membership — reuse the existing reachability helpers); creates room
`voiid-call-<call_id>`, upserts caller, peer and invitee into `call_participants` (a table
currently written by nothing), and pushes the invitee a content-free VoIP/wake meta. (2)
`POST /calls/:id/adhoc-token` — a LiveKit JWT for that room gated on a live participant row
instead of conversation membership, identity `<user_id>:<device_id>`, no name claim. (3) A
new migration adding a `state` column (invited/joined/left) with a **partial unique index on
(call_id, user_id)** — do **not** rely on the existing unique on (call_id, user_id,
device_id) for upserts, because a NULL device_id breaks `ON CONFLICT` (the known
Postgres-NULL-in-unique bug class this repo has already been bitten by).
**Neither endpoint may INSERT into conversations or conversation_members.**
**Conflicts:** 3.5 (calls.ts), 3.10 (calls.ts).

### 3.2 — New WS relay frames for escalation
**Severity:** high · **Platform:** backend
**Files:** `backend/websocket/src/index.ts`

The relay knows nine unicast 1:1 frame types; escalation needs five more, built with the
identical discipline — single `to_user_id`, `from_user_id` stamped from the socket JWT,
outbound frame rebuilt from a fixed field list, never logged. `call_invite` (inviter→
invitee), buffered in the existing per-user Redis offer hash keyed by call_id so a
push-woken invitee still receives it, cleared on resolution like offers;
`call_invite_accept` / `call_invite_decline` (invitee→inviter), with the decline also written
to the `call_taken` sibling buffer so the invitee's other devices stop ringing;
`call_migrate` (inviter→current peer); and `call_key` carrying opaque pairwise-ratchet
ciphertext — **apply the same base64-only structural opacity check the location relay uses**
so the relay can never carry readable key material.
**Conflicts:** 1.6 (same file). Must run after 1.6.

### 3.3 — Per-call secret distribution over the ratchet, with rekey on membership change
**Severity:** high · **Platform:** both mobile
**Files:** `apps/*/net/CallService.*`, `apps/*/net/GroupCallService.*`, `apps/*/net/ChatEngine.*`

The joiner must receive **call** keys, not conversation keys. `e2e-core` already exposes
everything needed and **nothing calls it**: `newCallSecret()` and `deriveSrtpKeys` are on the
uniffi surface on both platforms. On escalation the inviter mints a fresh CallSecret and
distributes it pairwise over the Double Ratchet — to the current peer over the existing 1:1
session, to the invitee by establishing sessions from prekey bundles using the existing
device-fanout path (session setup creates no conversation row) — carried in the new opaque
`call_key` frame, **not** the durable message path. All participants derive the LiveKit
passphrase as `base64(masterKey||masterSalt)`, the exact format group calls already use,
applied via the existing shared-key provider. **On every join and leave** the inviter
(fallback: lowest user_id present) mints a new secret and re-fans it; clients re-apply via
the existing rotation path, debounced like the MLS epoch rekey. **Never join without a key**
— both group clients already refuse. New Kotlin wire DTOs must use `@EncodeDefault` or
hand-built JSON (the shared Json has `encodeDefaults=false`); Swift decoders must treat every
new field as optional.
**Conflicts:** 3.4 (same files), 1.14, 1.15 (ChatEngine both platforms). Must run after the Tier-1 ChatEngine work.

### 3.4 — Make-before-break escalation engine
**Severity:** high · **Platform:** both mobile
**Files:** `apps/*/net/CallService.*`, `apps/*/net/GroupCallService.*`, `apps/*/main/CallScreens.*`, `apps/android/.../net/VoiidMessagingService.kt`, `apps/ios/.../VoiidApp.swift`

No escalation path exists: the 1:1 engine owns exactly one PeerConnection, group is marked
"OUT OF SCOPE" in-code, and the two stacks are **mutually exclusive by audio-session
design**. Implement inviter states CONNECTED→ESCALATING→CONFERENCE: during ESCALATING both
the 1:1 PC and the LiveKit room connection are alive (requiring a carve-out in both
mutual-exclusion gates for the same call_id); the 1:1 leg is hung up with a normal
`call_hangup` **only after both original participants report SFU-connected**, and SFU failure
falls back to the still-standing 1:1 call. The current peer receives `call_migrate`, shows
"Adding <name>…", and joins the room keeping 1:1 audio until SFU media flows. The invitee
gets the standard incoming-call surface via the existing ring-push path, labelled
"<inviter> is adding you to a call"; accept fetches the ad-hoc token and joins, decline sends
`call_invite_decline`. **Hardest risk: audio-session handover between the two coexisting
WebRTC builds** (RTC* vs LKRTC* on iOS, org.webrtc vs livekit.org.webrtc on Android).
**Conflicts:** 3.3 (same files), 1.2, 1.4, 1.5, 1.7 (Android call files). Sequence last in this group.

### 3.5 — Identity disclosure: unknown call participants show @username only
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/*/net/GroupCallService.*`, `apps/*/UserDirectory.*`, `backend/api/src/routes/users.ts`

Group-call rosters currently fall back to raw user-id prefixes — iOS shows the first 6 chars
of the uuid, Android shows the identity prefix — **violating the house rule "NEVER a raw user
id."** And the resolution precedence prefers full_name over username while
`GET /users/:id` returns full_name to **any** authenticated caller, so an added stranger
would today be labelled with the private-plane profile name. Route all call/conference roster
tiles through `UserDirectory`; for a participant who is neither a saved contact nor an
accepted-conversation peer, display **@username only** — no full name, no photo, no phone —
falling back to "Unknown" (never a uuid) when username is null. Tap-through on an unknown
tile goes to the @username profile whose Message action routes through the reachability
request with the PIN prompt unchanged. Optionally harden server-side by withholding
full_name/photo_url from non-contacts in `GET /users/:id` — **audit existing consumers
first.**
**Conflicts:** 3.3, 3.4 (GroupCallService); 3.17 (users.ts).

### 3.6 — Client-side reachability gate on inbound call offers
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/android/.../net/CallService.kt`, `apps/ios/.../Networking/CallService.swift`

*Reduced in scope: the server-side half of the original proposal is already shipped (see the
STRUCK note in Tier 1A), so this is now defense-in-depth.* Clients still ring for any offer —
neither `onRingPush`/`onRemoteOffer` on Android nor `handleIncomingOffer` on iOS has a
known-peer check. Drop or silently log offers whose `from_user_id` shares no accepted
conversation and is not in the local `UserDirectory`. **Roll out log-only first** to avoid
dropping legitimate not-yet-synced peers, and only promote to hard-drop once the logs are
clean.
**Conflicts:** 3.4, 1.5 (CallService both platforms).

### 3.7 — Guard tests: a shared call must never create a messaging edge
**Severity:** medium · **Platform:** backend
**Files:** `backend/api/test/callConference.test.ts`, `backend/api/src/routes/calls.ts`

Encode the "a follow is not a messaging right" principle for calls. Assert (1) no route under
`/calls` ever INSERTs into conversations or conversation_members — true today; verify it
stays true once escalate and adhoc-token land; (2) after a full simulated escalation
involving a stranger, a reachability request from that stranger **still** requires the PIN
and lands as `pending`; (3) nothing in reachability or conversations reads `call_participants`
to authorize anything. This keeps the contact-PIN gate intact by construction rather than by
review.
**Conflicts:** 3.1, 3.10 (calls.ts). Write the tests last, after those land.

### 3.8 — CallSecret-verified keying for plain 1:1 calls
**Severity:** low · **Platform:** both mobile
**Files:** `apps/*/net/CallService.*`, `apps/*/net/ChatEngine.*`

1:1 media today relies solely on DTLS-SRTP fingerprints carried in server-relayed SDP; the
code itself admits a colluding server can MITM. Once 3.3's pairwise `call_key` distribution
exists, reuse it for ordinary 1:1 calls: the caller sends `newCallSecret()` over the
established ratchet alongside the offer, both sides derive SrtpKeys via `srtpKeysFor1to1`,
and either key SRTP directly or use the secret as a key-commitment check against the
DTLS-negotiated keys. **Must be version-negotiated** (a capability flag in the `call_offer`
frame, absent-field-tolerant on both platforms) so old clients still complete calls.
**Conflicts:** 3.3, 3.4, 3.6. Run after 3.3.

## 3B. Groups at 1000

### 3.9 — Sync server conversation roster with MLS membership
**Severity:** critical · **Platform:** both mobile
**Files:** `apps/ios/.../Networking/GroupEngine.swift`, `apps/android/.../net/GroupEngine.kt`

**Neither client ever calls the backend membership endpoints** — grepping for `/members`
across both apps returns zero call sites — because the engines predate them; a stale comment
still claims the endpoint "isn't in the current contract," but it exists. Both engines do
MLS-only work on add/remove. Consequence: a user added after group creation is **missing from
the server roster**, so message fan-out target resolution never includes them and the group
call token endpoint 403s them; a removed user **keeps receiving ciphertext and keeps call
access.** Call `POST /conversations/:id/members` before distributing the MLS Welcome, and
`DELETE /conversations/:id/members/:userId` after broadcasting the removal commit. Both
endpoints are idempotent. Note this is filed under Tier 3 because it is scoped to the
groups-at-scale build, but it is a **correctness bug affecting groups today** — consider
pulling it forward.
**Conflicts:** 3.12 (same files), 3.3 (engines).

### 3.10 — Enforce 1000-member, 50-admin, one-owner model server-side
**Severity:** high · **Platform:** backend
**Files:** `database/migrations/030_group_roles.sql`, `backend/api/src/routes/conversations.ts`

**No member limit exists anywhere**, and role is unconstrained text defaulting to 'member'
with the creator as 'admin'. Add migration 030: a CHECK constraining role to
owner/admin/member; a partial unique index guaranteeing **at most one active owner** per
conversation; backfill `created_by` rows to owner. In the route add MAX_GROUP_MEMBERS=1000
and MAX_GROUP_ADMINS=50, insert the creator as owner, validate member_ids length at create,
and in the add-members endpoint count active members **inside a transaction holding
`select … for update` on the conversations row** to avoid the concurrent-add race. Signal's
equivalent is a hard limit of 1001 via remote config. **Beware the reinstate path**
(`on conflict … set left_at = null`) resurrecting a former owner as a second owner and
tripping the unique index.
**Conflicts:** 3.11 (both files), 1.16 (conversations.ts).

### 3.11 — Role-change and ownership-transfer endpoints with structured system events
**Severity:** high · **Platform:** backend
**Files:** `backend/api/src/routes/conversations.ts`, `database/migrations/030_group_roles.sql`, `backend/api/src/routes/messages.ts`

No endpoint exists to change a role or transfer ownership, and membership changes are
**silent** — nothing produces the system messages both apps can already render. Add
`PATCH /conversations/:id/members/:userId/role` (owner or admin promotes; only owner demotes
an admin; reject if the admin count would exceed 50) and
`POST /conversations/:id/transfer-ownership` (owner-only; atomically demote self and promote
target **in one transaction** so the one-owner index never trips). Emit events as
server-created message rows with `ciphertext = null`, `content_type = 'system'`, and a new
`system_event` jsonb column carrying `{kind, actor_id, target_id, new_role}` — the fan-out
path already writes null-ciphertext canonical rows, and the opacity assertion only guards
client-sent bodies. Also emit add/remove events from the existing membership endpoints, and
publish on the normal user channel. **Structured payloads, not pre-baked English** — mirror
Signal's update-message producer, which localizes client-side. Roles are already server-side
plaintext metadata, so this does not weaken E2EE.
**Conflicts:** 3.10 (same files), 1.13 (messages.ts). Run after both.

### 3.12 — Render real roles and system messages; wire the stubbed group-info actions
**Severity:** high · **Platform:** both mobile
**Files:** `apps/android/.../net/ChatService.kt`, `apps/android/.../main/GroupInfoView.kt`, `apps/ios/.../Main/GroupInfoView.swift`, `apps/ios/.../Networking/ChatService.swift`, `apps/ios/.../Main/ChatDetailView.swift`, `apps/android/.../main/ChatUI.kt`

Android **never displays real roles**: the member DTO has no role field even though the API
returns it, so every member is built with the default role and the admin badge is dead code.
Add `val role: String = "member"` — **a default value, not a bare nullable**, since kotlinx
throws on absent keys (the known receipts/stories bug class) — and thread it through the
fetch. Both platforms' "Make group admin"/"Dismiss as admin" actions are **no-ops** (an empty
closure on iOS, a dialog that only dismisses on Android) — wire them to the new PATCH
endpoint. iOS "Add members" and "Invite via link" are empty closures though the engine method
exists; "Exit group" on both platforms **only dismisses the screen** — wire to the DELETE
endpoint plus MLS handling, and **block an owner's exit until ownership is transferred**
(successor-picker flow, per Signal's last-admin pattern). Map `content_type == 'system'` plus
the event payload into the existing centered-pill renderers, composing localized text
client-side including "You" variants. Also show the owner badge on iOS, which currently maps
only 'admin'.
**Conflicts:** 3.9 (engines), 3.11 (must land first), 2.22 (ChatDetailView.swift, ChatUI.kt).

### 3.13 — Fix MLS event delivery for multi-device and O(N²) commit fan-out
**Severity:** high · **Platform:** all
**Files:** `backend/api/src/routes/mls.ts`, `database/migrations/011_mls.sql`, `backend/api/src/routes/messages.ts`, `apps/*/net/GroupEngine.*`

The MLS crypto core scales to 1000 (OpenMLS 0.8, RFC 9420, no cap in the Rust) but **the
transport does not.** (a) `GET /mls/group-events` marks **all** of a user's undelivered rows
delivered on first fetch, keyed by recipient **user**, so a second device permanently loses
commits — and a lost commit kills the group irrecoverably, since `max_past_epochs = 0`.
Migrate to per-device delivery. (b) Group creation posts one commit row **per already-added
member per add**, inserted row-by-row — O(N²), roughly 500k rows at N=1000; store one commit
row per (conversation, epoch) with a delivery-tracking table instead of N copies. (c) Batch
the per-row insert loops with `unnest` — the message path does 1000+ sequential inserts per
group message at target scale. (d) Devices publish only 10 KeyPackages at bootstrap and the
fetch endpoint 409s when drained, causing adds to **silently skip users** — add a count
endpoint and low-water client top-up mirroring the prekey flow. **Do not change any crypto:
this is storage and delivery only.**
**Conflicts:** 1.13, 3.11 (messages.ts); 3.9, 3.12, 3.14 (GroupEngine); 3.16 (mls.ts).

### 3.14 — Expose MLS `epoch()`/`clear_pending()` and add a 1000-member scale test
**Severity:** medium · **Platform:** all
**Files:** `packages/e2e-core/src/api.rs`, `apps/ios/.../voiid.swift`, `packages/e2e-core/tests/soak.rs`, `apps/*/net/GroupEngine.*`

`GroupSession::epoch()` and `clear_pending()` exist in Rust as the documented building blocks
for losing a concurrent-commit race but are **not on the uniffi surface** — the iOS engine
says so explicitly — so apps cannot implement Signal-style rebase-and-retry (Signal retries
up to 5×, re-basing on conflict). **With up to 50 admins, concurrent adds and removes will
race the single-committer engines.** Expose both through the bindings and add lost-race
reconciliation: detect a foreign commit for the epoch just committed against, clear pending,
reprocess. Also add an `#[ignore]`d soak test growing a group to 1000 leaves, measuring
Welcome and serialized ratchet-tree size — **X-Wing/ML-KEM-768 leaf keys make multi-MB
Welcomes plausible and this is currently unmeasured; no existing test exceeds 3 members** —
and commit-processing time. Client group-creation pickers should cap selection at 999 others.
**Conflicts:** 3.13, 3.9, 3.12 (GroupEngine).

### 3.15 — Group call UI overhaul
**Severity:** medium · **Platform:** all
**Files:** `apps/*/main/GroupCallScreen*.{swift,kt}`, `apps/*/net/GroupCall*.{swift,kt}`, `backend/api/src/routes/calls.ts`, `apps/*/ChatDetailView.*`

The current UI squeezes every participant into one non-scrolling grid — 3 fixed columns for
5+ on iOS, weighted rows on Android — with no active-speaker priority, no roster, and
push-only discovery: the ring push deep-links **straight into joining**, with no
accept/decline screen. Build: (1) a dominant active-speaker tile plus a paged thumbnail strip
past 8 participants, keeping the never-scroll rule below that — speaking state already exists
on the participant model; (2) a participant roster bottom sheet with mute/video/speaking
state; (3) an in-chat "ongoing call — Join" banner backed by a new
`GET /calls/group/active?conversation_id=` using a short-TTL Redis key refreshed by connected
clients; (4) an incoming group-ring accept/decline card instead of instant join. **Do not
touch the E2EE path** — passphrase derivation and epoch rekey stay as-is. While in these
screens, convert the **non-lazy** group member lists (a `ForEach` in a `ScrollView` on iOS, a
`forEach` in a vertical scroll on Android) to lazy lists for 1000-member groups.
**Conflicts:** 3.1, 3.7, 3.10 (calls.ts); 3.3, 3.4, 3.5 (GroupCallService); 2.22, 3.12 (ChatDetailView).

## 3C. Communities

### 3.16 — Migration: communities container, members, channels, invites, host threads
**Severity:** high · **Platform:** backend
**Files:** `database/migrations/030_communities.sql`

*Note: three separate proposals all claim migration number 030 (`030_call_conference.sql`,
`030_group_roles.sql`, `030_communities.sql`). **Renumber before any of them lands** — assign
sequential numbers in merge order.* Create the Phase-1 schema: `communities` (client-supplied
uuid pk like clips, owner_id, handle in the shared namespace, name/description/avatar key,
discoverable default false, join_policy open|approval|invite_only, trigger-maintained
member_count, suspended_at), `community_members` (**pk (community_id, user_id)** so upserts
have no NULL columns, role, state), `community_channels` (conversation_id pk, kind
announcement|chat), `community_invites` (crypto-random token pk, expires_at, max_uses,
revoked_at), and `community_host_threads`. Extend the cross-table handle-availability trigger
from the creator-profiles migration to also check community handles, and widen the
`opened_via` check constraint to allow 'community'. **The file header must carry a NOT-E2EE
block** modeled on the clips migration, declaring that community metadata, roster, search,
invites, tournaments and tickets are server-readable while channel messages and host DMs
remain E2EE.
**Conflicts:** 3.10, 3.1 (migration numbering).

### 3.17 — Backend communities routes
**Severity:** high · **Platform:** backend
**Files:** `backend/api/src/routes/communities.ts`, `backend/api/src/index.ts`

New Express router: `POST /communities` creates the container plus two group conversations
(announcement + general) **in one transaction**, reusing the group-create shape;
`GET /communities/search?q=` does ILIKE over discoverable, non-suspended communities
returning only the public card; `GET /communities/:handle` returns the info card **to
non-members** — this is precisely why the container is not a conversation, since
`GET /conversations/:id` is member-only; `POST /communities/:id/join` handles open (active
immediately), approval (pending), and invite_only (validate token expiry/uses/revocation,
bump use count) and inserts conversation_members rows for the channels — **the client then
completes MLS Welcome/Commit via the existing /mls routes**, the same division of labor
already documented for group conversations; plus leave, admin approve/ban/remove, and
owner/admin invite mint/revoke.
**Conflicts:** 3.18, 3.19, 3.21 (same file).

### 3.18 — Member-to-host private DM: scoped reachability exception
**Severity:** high · **Platform:** all
**Files:** `backend/api/src/routes/communities.ts`, `backend/api/src/routes/messages.ts`, `apps/ios/.../MessageActionWire.swift`, `apps/*/net/ChatEngine.*`

`POST /communities/:id/host-thread`: caller must be an active member, target is the community
**owner only**; idempotently create or reuse a direct conversation with
`opened_via='community'` and `request_state='accepted'` on both membership rows, recorded in
the host-threads table, rate-limited on creation. This is an ordinary Double-Ratchet 1:1, so
it stays fully E2EE with **zero new crypto**. **CRITICAL SCOPE RULE: this grants
member→owner only, never member→member** — the creator-profiles migration states that any
code reading a social graph to authorize messaging is a bug. Client UX: "Message host" on the
info card, and a long-press "Ask host about this" on an announcement message which sends the
**existing** reply envelope into the host thread — the quoted id is the server message id of
the announcement, which resolves for the host because both are members of the announcement
channel, and the quoted preview renders even when the original is gone. Host side groups
`opened_via='community'` conversations into a Community inbox section.
**Conflicts:** 3.17 (communities.ts), 1.13, 3.11, 3.13 (messages.ts), 1.14, 1.15, 3.3 (ChatEngine).

### 3.19 — Server-side posting restriction for announcement channels
**Severity:** high · **Platform:** backend
**Files:** `backend/api/src/routes/messages.ts`, `backend/api/src/routes/communities.ts`

**MLS grants every member both decrypt and send capability**, so admin-only announcement
channels must be enforced server-side: in the send path, if the target conversation has a
channel row with `kind='announcement'`, reject unless the sender's community role is owner or
admin. Without this check any member can post to the announcement channel regardless of what
the UI shows. Keep the check on a conversation_id lookup (one indexed probe) so ordinary
chat sends pay nothing.
**Conflicts:** 1.13, 3.11, 3.13, 3.18 (messages.ts). This file is the single most contended in the plan — serialize all of its items.

### 3.20 — Cap E2EE channel size and batch MLS fan-out before open discovery ships
**Severity:** high · **Platform:** backend
**Files:** `backend/api/src/routes/mls.ts`, `backend/api/src/routes/communities.ts`

The MLS route inserts one event row per recipient in a per-event loop and consumes
KeyPackages with one UPDATE per device in a loop; **every community join triggers a Commit
fanned to all members**, so a 5,000-member open community would generate thousands of rows
plus Redis publishes per join. Enforce a **512-active-member cap per E2EE channel** in the
join route at MVP, and convert both loops to multi-row inserts with pipelined Redis publishes
before raising the cap toward WhatsApp-order 1024. **Do not promise E2EE megagroups.**
**Conflicts:** 3.13 (mls.ts), 3.17, 3.18, 3.19 (communities.ts). Overlaps heavily with 3.13 — consider merging.

### 3.21 — Invite deep links for community join
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/android/.../net/DeepLinkRouter.kt`, `apps/android/app/src/main/AndroidManifest.xml`, `apps/ios/Voiid/Voiid` (scene/app delegate)

Handle `https://voiid.app/c/<handle>?i=<token>` as a join link: Android needs a manifest
intent filter and routing through `DeepLinkRouter` (which today only bridges notification
deep-links); iOS needs universal-link handling in the scene/app delegate. The link opens the
community info card — which works for non-members — with a Join button passing the token to
the join endpoint. The token is a plain revocable server-side capability, **deliberately not**
Signal's scheme of putting key material in the URL fragment: Signal does that because its
group state is E2EE, whereas Voiid's roster is server-visible by design, so a server token is
simpler and more honest.
**Conflicts:** 1.2 (DeepLinkRouter.kt). Run after 1.2.

### 3.22 — Tournaments on the existing games stack
**Severity:** medium · **Platform:** backend
**Files:** `database/migrations/031_tournaments.sql`, `backend/api/src/routes/games.ts`, `backend/games/src/matches.ts`

New tables: `tournaments` (community_id, game_id, format single_elim|round_robin, status,
starts_at) and `tournament_players` (pk (tournament_id, user_id), seed, eliminated_in_round);
plus ALTER `game_matches` adding a nullable tournament_id and round. Routes: create (community
owner/admin), register, start — seeding the bracket by creating round-1 match rows exactly as
the existing endpoint does, after which invites flow client-side over E2EE. When a match
carrying a tournament_id finalizes, pair winners into the next round. Standings are SQL over
the existing results table scoped by tournament_id — **community-scoped leaderboards are
acceptable because members consented by joining**, unlike the deliberately opponent-scoped
global leaderboard. Game state stays server-readable per the scoped exception already declared
in the games migration; nothing else gains readability.
**Conflicts:** 2.20 (games.ts). Run after 2.20.

### 3.23 — Phase 2: events, orders, tickets with webhook-idempotent payments
**Severity:** medium · **Platform:** backend
**Files:** `database/migrations/032_events_tickets.sql`, `backend/api/src/routes/events.ts`, `backend/api/src/routes/payments.ts`, `backend/api/src/index.ts`

**No payments code exists anywhere in the repo.** Build `community_events` (title, starts_at,
free-text location — **not** an E2EE location share — capacity, price_minor default 0,
currency default INR, draft|published|cancelled), `event_orders` (provider and provider_ref
**both NOT NULL** with a unique on the pair as the webhook idempotency key — NOT NULL
specifically to avoid the Postgres NULL-in-unique upsert bug class this repo has hit before),
and `event_tickets` (order_id, holder_id, unique qr_nonce, checked_in_at). Flow: create a
pending order, provider checkout (Razorpay first behind a provider-agnostic interface so
Stripe slots in), webhook flips to paid and mints tickets idempotently. The ticket QR is an
HMAC-signed `{ticket_id, event_id, exp}` verified by a host scan endpoint. **Ship free RSVP
(price 0) before wiring money.** Tickets and orders are declared non-E2EE in the migration
header: refunds, disputes and door validation require server-readable rows.
**Conflicts:** none (all new files) except `index.ts` route mounting.

### 3.24 — Guard new wire types against the repo's serialization bug classes
**Severity:** medium · **Platform:** both mobile
**Files:** `apps/android/.../net/ChatEngine.kt`, `apps/android/.../model/Models.kt`, `apps/ios/.../Models/Models.swift`

Any new community envelope or API model must follow the two client-side rules already
documented in-repo: on Android, **every discriminator or defaulted field in a kotlinx
`@Serializable` wire struct needs `@EncodeDefault`**, because the shared Json has
`encodeDefaults = false` and silently omits default-valued fields — the exact bug class called
out in ChatEngine and ChatService, with the existing reply wire as the correct template; on
iOS, **every new field in a Codable response model must be Optional** so absent keys do not
throw `keyNotFound` on older servers. Applies to community cards, membership rows, invite
payloads, tournament standings, and any new discriminated E2EE envelope. Note 2.25 is the same
bug class already latent in the games API — treat this as the general rule, that as the
instance.
**Conflicts:** 1.14, 1.15, 3.3, 3.18 (ChatEngine.kt).

## 3D. Admin / DPDP

*(0.1–0.4 above are the urgent subset of this workstream, pulled into Tier 0.)*

### 3.25 — Build the DPDP erasure worker; stop retaining phone numbers forever
**Severity:** critical · **Platform:** backend
**Files:** `backend/workers/src/erasure.ts` (new), `backend/workers/src/index.ts`, `backend/api/src/routes/users.ts`, `database/migrations/001_users.sql`

`DELETE /users/me` sets `deleted_at` and nulls profile fields, and its response literally says
"hard purge runs via erasure job (DPDP)" — **but that job does not exist**; the workers
directory contains only story reaping, and the workers README lists DPDP erasure under "Still
to build." The soft delete **retains phone_number and username indefinitely**. A phone number
is the primary personal identifier in this system, so indefinite retention after an erasure
request is the largest DPDP exposure in the codebase (Act s.8(7): erase when the purpose is no
longer served). Also, the route comment claims prekeys are removed at request time but the
code only revokes devices — fix the mismatch by actually deleting prekeys there. Create the
worker and register it in the tick loop alongside story reaping. After a grace period (**30
days is an engineering placeholder requiring legal sign-off**), for each user with an expired
`deleted_at`: delete devices, prekeys, otp_sessions by phone, contact_sync rows,
location_shares, stories plus their R2 objects, clips and comments plus R2 objects (or
anonymize the author), and message_ciphertexts addressed to their devices; then either delete
the users row or overwrite phone_number with a random tombstone. Most children already
cascade. **Mirror the "R2 objects first, then the row" ordering** used by the admin purge, and
make the job idempotent and safe to run concurrently on two boxes per the workers contract.
**Depends on 0.2** — do not run this while stale JWTs still authenticate.
**Conflicts:** 0.2, 3.17, 3.27 (users.ts); 3.26 (workers/index.ts).

### 3.26 — DPDP consent is never captured
**Severity:** critical · **Platform:** all
**Files:** `backend/api/src/routes/users.ts`, `apps/ios/.../Onboarding/OnboardingFlow.swift`, plus the Android equivalent, new migration

`POST /users/consent` exists and writes `consent_given_at`, but **grepping both mobile apps
for it returns zero callers** — the endpoint shipped without its client leg, so
`consent_given_at` is null for every user in production despite its "DPDP: lawful consent
capture at signup" comment. Separately the record itself is inadequate: a bare timestamp
captures no notice version, no language, no itemized per-purpose flags, and no withdrawal
path. Add a migration creating a `consent_records` table (user_id, notice_version, language,
purposes jsonb, given_at, withdrawn_at) rather than relying on the single column, update the
endpoint to write it, and **wire a real affirmative action in both onboarding flows**. On iOS
the consent checkbox currently renders "Terms & Conditions" and "Privacy Policy" as
**non-tappable text — users agree to documents they cannot open.** Sequence consent before
profile completion, and add a backfill prompt on next launch for existing users.
**Conflicts:** 3.25, 3.17, 3.27 (users.ts); 3.31 (OnboardingFlow.swift).

### 3.27 — DPDP data-principal request console and metadata-only export
**Severity:** high · **Platform:** backend
**Files:** `backend/api/src/routes/users.ts`, `backend/api/src/routes/admin.ts`, `apps/admin-web/app/dpdp/page.tsx`, new migration

Voiid has **no mechanism to receive, track, or fulfil DPDP data-principal requests** (access,
correction, erasure, grievance — Act ss.11-13). Add a `dpdp_requests` table (kind, status,
opened_at, due_at, closed_at, handled_by, notes). Add `POST /users/dpdp-request`, plus
`GET /users/me/export` returning a **metadata-only** JSON document: the profile row, device
rows, consent records, and the user's clips list. **The export must contain no message, call,
location, or moment content** — the server holds only ciphertext and no key — **and the
payload should say so explicitly**, since a DPDP access request that silently omits content
would otherwise look incomplete. Signal's equivalent reports account fields plus per-device
id/created/lastSeen/userAgent and nothing else — a good shape to mirror. Add the admin-side
queue with audited status transitions and an admin-web page with SLA timers. Erasure-kind
requests should trigger the 3.25 worker path. **Response content and SLA durations need legal
sign-off.**
**Conflicts:** 3.25, 3.26, 3.17 (users.ts); 0.3, 3.29 (admin.ts).

### 3.28 — No retention sweep on any table holding IPs or phone numbers
**Severity:** high · **Platform:** backend
**Files:** `backend/workers/src/retention.ts` (new), `backend/workers/src/index.ts`

**Nothing ever deletes rows from three tables holding directly identifying data.**
`security_events` stores ip_address and phone_number and grows forever; `otp_sessions` stores
phone_number with an `expires_at` that is never acted on; `admin_sessions` stores user_agent
and ip, and the only delete is the per-token logout, so every expired session row persists
with its IP. DPDP storage limitation (s.8(7)) requires a stated and enforced retention period.
The codebase already documents this pattern as intentional-but-unenforced elsewhere — the
call-metrics migration suggests a 90-day delete as an ops cron that was never wired up. Add
the worker and register it in the tick loop: delete otp_sessions past expiry + 24h,
security_events older than 90 days, admin_sessions past expiry, and call_metrics per the
existing comment. **Keep the periods as named constants in code so the retention policy is
reviewable in a diff** — that is the stated rationale for the workers process. Pure idempotent
deletes; **the specific durations need legal sign-off.**
**Conflicts:** 3.25 (workers/index.ts).

### 3.29 — No user-facing report flow and no admin report queue
**Severity:** high · **Platform:** all
**Files:** `backend/api/src/routes/clips.ts`, `backend/api/src/routes/admin.ts`, `apps/admin-web/app/reports/page.tsx`, new migration

There is **no way for a user to report content and no queue for moderators to work** — no
reports table exists in any migration, and moderation today is entirely admin-initiated
scrolling of the clips list. Add a `clip_reports` table (clip_id, reporter_user_id, reason
enum, note, created_at, resolved_at, resolved_by, resolution) with a unique on
(clip_id, reporter_user_id) to prevent report-bombing — **note that if any nullable column is
added to that unique key, Postgres NULLs will silently permit duplicate rows, so keep both
columns NOT NULL.** Add `POST /clips/:id/report` (authed, rate-limited via the existing clips
bucket), `GET /admin/reports` (keyset-paginated with per-clip counts) and
`POST /admin/reports/:id/resolve`, both writing the audit log via the existing helper. Add the
admin-web page and a report button in the iOS and Android clips UI. **Reuse the keyset
pagination pattern rather than OFFSET**, for the reason documented in the existing route.
**This concerns Clips only, which are deliberately public non-E2EE content — do not extend
reporting to messages, which the server cannot read.**
**Conflicts:** 0.3, 3.27, 3.30 (admin.ts).

### 3.30 — Admin panel: users list, device/session viewer, audit UI, role system
**Severity:** medium · **Platform:** backend + admin-web
**Files:** `backend/api/src/routes/admin.ts`, `apps/admin-web/app/{page,users,audit}/**`, new migration

The admin app has exactly three pages — dashboard, login, clips moderation. There is no users
page, no device/session viewer, and **no audit-log page even though the audit endpoint already
exists and works.** There is also **no role system**: the admin_users table has no role
column, so every admin row has identical full power **including the irreversible purge.** Add
`GET /admin/users?search=` (id, **masked** phone, username, created_at, deleted_at, clip
count), `GET /admin/users/:id` (device metadata plus recent security events), and
`POST /admin/users/:id/revoke-devices`. Add a migration adding
`role text not null default 'moderator'` and gate clip purge, user-affecting actions, and the
DPDP console behind an 'admin' role. Build the users and audit pages and add nav links.
**Mask phone numbers by default in the UI** — moderators reviewing clips do not need them, and
data minimisation applies to the admin plane too. Audit every new mutation. **Note the device
viewer will show `last_seen_at` as null for every device**: grepping the backend shows it is
only ever read, never written — so either write it on authenticated requests or omit the
column rather than displaying a permanently empty field.
**Conflicts:** 0.3, 3.27, 3.29 (admin.ts).

### 3.31 — No privacy policy or terms reachable in-app
**Severity:** medium · **Platform:** all
**Files:** `apps/ios/.../Main/Settings/AboutView.swift`, `apps/ios/.../Onboarding/OnboardingFlow.swift`, plus Android equivalents

DPDP s.5 requires a notice at or before consent, and **there is nothing to link to.** On iOS
the privacy-policy, terms and help URLs are declared `nil` and the whole Legal section is
behind `if let`, so nothing appears; the file carries an explicit "ACTION REQUIRED FROM
PRODUCT" comment noting that filling in those three constants is the entire iOS change and
that whoever supplies them must in the same change fix the onboarding flow, where the consent
strings are non-tappable text. Set the three constants, make the onboarding strings tappable
links, and apply the Android settings and onboarding equivalents. Host the documents. **The
document content — notice text, grievance officer designation, children's-data stance, breach
runbook, retention table — must come from India-qualified counsel** and is already tracked as
an open question in `docs/LEGAL_QUESTIONS.md`. No technical risk, **but this blocks public
launch.**
**Conflicts:** 3.26 (OnboardingFlow.swift). Pairs naturally with it.

### 3.32 — Minimal lawful device-type collection (os_version, app_version)
**Severity:** medium · **Platform:** all
**Files:** `backend/api/src/routes/devices.ts`, `database/migrations/002_devices.sql`

The devices table captures no OS or app version, making support and crash triage guesswork.
Add a migration with two nullable text columns, accept them in the register handler, and send
them from both registration call sites. Note the backend **already parses client platform and
app version from request headers** for the force-update gate, so the values are available at
the edge if header-based population is preferred over body fields. **Do not add an IP column
to devices:** IP belongs only in short-retention security telemetry, which is the posture
Signal takes — its server device record stores only lastSeen and userAgent with no IP, and
forwarded-for appears only in request-scoped plumbing used transiently for rate limiting.
Declare the two new fields in the privacy notice when it is written.
**Conflicts:** 0.1, 1.9 (devices.ts). Run last of the three.

---

## Appendix: dropped and merged items

**Struck as already shipped (2):** "Require conversation membership on POST /calls/ring" and
"Authorize POST /calls/ring and gate inbound call offers on reachability." Verified complete
at `calls.ts:46-62` (both-party check), `calls.ts:101` (enforced pre-insert), and
`websocket/src/index.ts:51-55` (ring-grant enforcement). The client-side offer-gating half
survives as 3.6, downgraded to defense-in-depth.

**Merged (6→3):** the two overlapping ring-authorization items above collapsed into the strike
note; the iOS and Android "empty state" items merged into 2.7; the MLS fan-out batching
appears in both the groups doc (3.13) and the communities doc (3.20) — kept separate because
the caps differ, but **they touch the same loops and should be executed together.**

**Corrections to source descriptions (3):**
1. The Android story decode (1.30) was described as if it stalls the main thread; it actually
   runs on `Dispatchers.IO`. The real defect is memory — full-resolution decode into an
   unbounded, never-evicted, size-agnostic shared cache. Fix is unchanged; the rationale is.
2. Three migrations all claim number `030`. Renumber in merge order (flagged in 3.16).
3. `docs/research/09_reels_editor.md` (486 bytes) is a stub superseded by
   `09_reels_editor_ig.md`; all editor items derive from the latter.

**Items needing non-engineering sign-off before they can close:** 3.25, 3.26, 3.27, 3.28
(retention durations and consent notice text — India-qualified counsel) and 3.31 (document
content). Start the legal thread now; these are launch-blocking and have the longest lead time.
