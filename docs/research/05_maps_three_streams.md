# Maps — the three location streams, and where stopping one disturbs the others

Research write-up, 2026-08-05. Every claim below is cited to the current code (`main`, 41eefc7).

The three streams under investigation:

- **(A1) chat 1:1 live location** — a timer-bounded live share inside a direct conversation.
- **(A2) GROUP live location** — the same feature inside an MLS group.
- **(B) friends-Map presence** — ambient, coarse, allow-list-gated visibility on the Map tab.

Headline: the streams are architecturally separated *better than reported* — each platform runs
chat sharing and Map presence on **separate location-manager instances**, and the known past
regression fixes (the `stop()` vs `stopForeground()` split, the share-id guard on the Map's stop
handler) are in place. The remaining interference is not "one manager torn down under another";
it is **stop-signal cross-talk**: the server's `loc_stop` frame carries only a `share_id` and a
`from_user_id`, is broadcast to every location surface on both platforms, and three handlers
disambiguate it imperfectly. The single worst finding: on iOS, **adding a person to your Map
audience erases you from every existing viewer's map, permanently**, because the server-side
supersede publishes `loc_stop` for the old map share and the fresh key is handed only to the
newly-added member (§ B1 below).

---

## 1. What exists today (per stream, per platform)

### 1.1 Transport shared by all three streams

- Durable control (`pin`, `live_start`, `live_stop`, `live_rekey`, `map_key`, `map_off`) rides the
  E2EE message path: 1:1 Double Ratchet or group MLS
  (`apps/ios/Voiid/Voiid/Networking/LocationShareEngine.swift:396-414`,
  `apps/android/.../net/LocationShareEngine.kt:401-407`).
- Ephemeral fixes (`loc_update`) and instant stops (`loc_stop`) ride the WS relay. Both platforms
  **fan every frame out to every location surface**:
  - iOS: `WebSocketClient.swift:306-324` calls the `onLocationUpdate`/`onLocationStop` closures
    (consumed by `MapPresenceEngine.wireWebSocket()`, `MapPresenceEngine.swift:189-201`) **and**
    posts `.voiidLocationRelayUpdate` / `.voiidLocationRelayStop` (consumed by
    `LocationShareEngine.configure()`, `LocationShareEngine.swift:89-109`).
  - Android: `WebSocketClient.kt:369-383` dispatches into `LocationRelay`
    (`net/LocationRelay.kt:51-64`), to which **both** `LocationShareEngine.init`
    (`LocationShareEngine.kt:112-114`) and `MapPresenceEngine.subscribe`
    (`MapPresenceEngine.kt:165-169`) are subscribed.
- Server: `backend/api/src/routes/location.ts` owns share rows. Ending/revoking publishes a
  `loc_stop` frame per target and hdel's the buffered last fix (`signalStop`, location.ts:82-100;
  `endShare`, location.ts:103-114). **The `loc_stop` frame carries no `kind`** — a receiver cannot
  tell a map stop from a conversation stop, or a supersede from a "went dark", except by looking
  up the share id locally. This is the root enabler of every cross-talk bug below.

### 1.2 iOS — two CLLocationManagers, three logical streams

| Stream | Engine | Manager | Started by | Stopped by |
|---|---|---|---|---|
| A1 + A2 | `LocationShareEngine` (singleton, `LocationShareEngine.swift:33`) | its own `LocationService` instance (`LocationShareEngine.swift:42`, manager at `LocationService.swift:28`) | `startLiveShare` → `service.startLive()` (`LocationShareEngine.swift:235`); resume via `resumeOutboundIfNeeded` (`:116-130`) | `stopLiveShare` → `service.stopUpdating()` **only when `emitting.isEmpty`** (`:269`) — correct refcount |
| B | `MapPresenceEngine` (`MapPresenceEngine.swift:44`) | `MapLocationProvider.shared` — a **separate** `CLLocationManager` (`MapLocationProvider.swift:33`) | `goVisible` → `provider.start()` (`:339`); cold-launch resume (`:98-100`); foreground restart (`:249`) | ghost/kill → `stopEmitting()` → `provider.stop()` (`:452-454`, `MapLocationProvider.swift:169-178`) |

A1 and A2 are one stream at the manager level: both multiplex through the `emitting` dictionary
(`LocationShareEngine.swift:53`), and `handleOutboundFix` iterates all active shares per fix
(`:289-308`). The background split pattern holds on the Map manager: backgrounding calls
`noteBackgrounded()` (drops only `startUpdatingLocation`, keeps significant-change,
`MapLocationProvider.swift:151-154`), while only ghost/kill call `stop()` (drops everything incl.
`allowsBackgroundLocationUpdates`, `:169-178`). Lifecycle is observed app-wide in the engine, not
the tab view (`MapPresenceEngine.swift:107-120`).

### 1.3 Android — two FusedLocationProviderClient wrappers + one FGS

| Stream | Engine | Provider | Started by | Stopped by |
|---|---|---|---|---|
| A1 + A2 | `LocationShareEngine` (object, `LocationShareEngine.kt:51`) | its own `LocationProvider` (`:109`, client at `LocationProvider.kt:26-27`) + `LocationForegroundService` for background | `startLiveShare` → `LocationForegroundService.start` + `provider.startLive` (`:206-207`) | `stopShare` → `provider.stop()` + FGS stop **only when `outbound.isEmpty()`** (`:260-264`) — correct refcount |
| B | `MapPresenceEngine` (object, `MapPresenceEngine.kt:48`) | its own `MapLocationProvider` (`:57,138`) — in-process callback + a PendingIntent/`MapLocationReceiver` background registration (`MapLocationProvider.kt:54-86,140-157`) | `goVisible` → `openShare` → `provider.start` + `startBackground` (`:374-382`); cold-start resume (`:155-161`); foreground restart (`:317-319`) | ghost/kill → `provider.stop()` (both halves, `:267`); backgrounding → `provider.stopForeground()` **only** (`:329-340`) |

The past regression ("onBackground once cancelled the background registration") is fixed and
holds: `MapLocationProvider.stop()` = `stopForeground()` + `stopBackground()`
(`MapLocationProvider.kt:95-98`), `onBackground()` calls only `stopForeground()`
(`MapPresenceEngine.kt:329-340`), and `MainActivity.onStop`/`onStart` own the transitions
(`MainActivity.kt:111-133`) with `MapTabView`'s `DisposableEffect` deliberately empty
(`MapTabView.kt:126-131`). Group shares don't interact with this split at all — chat sharing
(1:1 and group alike) has no background/foreground split; its background survival is the FGS.

### 1.4 The Map ↔ chat-share merge (read-only, by design)

Both Map tabs overlay active inbound conversation shares on the presence map without touching
cadence: iOS `MapTabView.swift:187-204` merges `shareEngine.activeInboundShares()` (which filters
ended shares, `LocationShareEngine.swift:361-365`); Android `MapTabView.kt:113-116` merges
`LocationShareEngine.inboundViews` via `asMapSubject`, which returns null for `ENDED`
(`MapTabView.kt:645-660`). Both merges are clean — an ended chat share correctly falls back to
the ambient presence pin.

---

## 2. What is broken or weak (root-caused, ordered by severity)

### B1 — iOS: `addToAudience` permanently erases you from every *existing* viewer's map (critical)

Chain, every step cited:

1. `addToAudience` re-creates the server row under the **current** key:
   `MapShareAPI.createMapShare(targetUserIds: audienceIds)` (`MapPresenceEngine.swift:390-392`).
2. The server supersedes: any prior active `(owner, kind='map')` share is ended and `loc_stop`
   for the **old share id** is published to **all of its targets** — including every retained
   viewer (`location.ts:233-240` → `endShare` :103-114 → `signalStop` :82-100).
3. On each existing viewer, `MapPresenceEngine.receiveStop(oldShareId, owner)` runs: the sender
   holds a map key (guard at `:522` passes), the tracked presence share id **matches** the old id
   (`:527` does not return), so the viewer **erases the inbound map key — which is keyed by
   SENDER, not share id — and the cached position** (`:531-533`,
   `MapKeyStore.swift:56-68` sender-keyed).
4. The sender keeps emitting under the *same* key but the *new* share id, and redistributes the
   key **only to the newly-added members**: `distributeMapKey(key, to: targets)` where `targets`
   is the added set (`MapPresenceEngine.swift:381-393`).
5. Every subsequent fix from the sender is dropped on existing viewers with
   "no inbound map_key (not authorized to us yet)" (`:467-469`) — forever, until the sender
   ghosts and re-shares.

So "I added one more friend to my map" reads, to everyone already watching, as "they vanished
from the map". Android does **not** have the permanent form: `setAudience` → `openShare(rekey =
true)` rekeys and `broadcastControl(map_key)` to the **entire** audience
(`MapPresenceEngine.kt:214-217`, `:366-371`), so viewers are erased by the supersede `loc_stop`
and then restored by the fresh durable `map_key`.

### B2 — both platforms: every Map re-open blips all viewers to "erased" for up to one presence interval (high, design)

Because `POST /location/shares` supersede *ends* the old share and `endShare` treats that
identically to "owner went dark" (`location.ts:233-240,103-114`), **every** `goVisible`,
`setAudience`, `addToAudience` and Android `openShare` retry causes each viewer to run the
explicit-stop path — which by design **erases the cached position** (iOS
`MapPresenceEngine.swift:529-534`; Android `MapPresenceEngine.kt:552-570` + `eraseSubject`).
The viewer then waits for a fresh `map_key` (durable message) plus the next fix (5-minute
foreground cadence, `MapConstants.PRESENCE_INTERVAL_MS`) before the pin returns. The
erase-vs-age-out distinction is a real safety property for a *genuine* stop, but a supersede is
not "went dark" — the server just cannot say so, because `loc_stop` has no reason/kind field.

### B3 — iOS: stopping a chat live share can tear a sender off the friends Map (high)

`MapPresenceEngine.receiveStop` guards cross-feature stops by *sender*, then only conditionally
by share id:

- `guard MapKeyStore.inboundKey(forSender: fromUserId) != nil else { return }`
  (`MapPresenceEngine.swift:522`) — passes whenever the sender is **also** map-visible to us.
- `if let known = MapPresenceStore.presence(for: fromUserId)?.shareId, known != shareId { return }`
  (`:527`) — protects **only if a presence row exists**. If the sender is map-visible but we hold
  no presence row — "waiting for their first fix" (`inboundSenders` without a fix,
  `:54-56`), or their row was pruned by the 8-hour age-out (`MapPresenceStore.pruneAged`, called
  at `:84` and `:206`) — the `if let` doesn't bind, and the chat share's `loc_stop` falls through
  to `clearInboundKey` + `erasePresence` + `forgetInboundSender` (`:531-533`).

Concretely: a friend shares live in your 1:1 chat *and* is visible to you on the Map, their
15-minute chat share expires (owner-side auto-stop sends WS `loc_stop`,
`LocationShareEngine.swift:380-389,252-254`), and if their map fix hasn't landed yet (or is >8 h
old) they silently drop off your Map with their key erased — the exact "stopping stream A kills
stream B" the founder describes. Android is immune: its guard is keyed by share id membership in
`inbound` (`MapPresenceEngine.kt:564`), the fix the iOS comment at `:511-521` *claims* to mirror
but doesn't fully.

### B4 — iOS: Map presence never resumes emission after process death (high)

`outboundShareId` is in-memory only (`MapPresenceEngine.swift:59`) and is never persisted or
reconciled from `GET /location/shares`. The cold-launch resume path restarts the *provider*
(`init`, `:98-100`) — and significant-change even relaunches the killed app, as the comment
celebrates (`:87-97`) — but every delivered fix then dies in
`emitFix`'s `guard let sid = outboundShareId` (`:437-439`), and `noteForegrounded`'s server
extend is skipped for the same reason (`:251-253`). Result: after any kill, the server row stays
active (viewers see "sharing"), the provider burns fixes, and nothing is emitted until the user
manually re-runs `goVisible`. Android persists and restores `share_id`/`share_key`/`expires_at`
(`MapPresenceEngine.kt:640-683`) and resumes correctly (`:155-161`).

### B5 — Android: shares reconciled by `refresh()` can never send their durable stop; groups misrouted (medium)

`refresh()` rebuilds outbound context with `isGroup = false, peerUserId = null` for **every**
share, group or 1:1 (`LocationShareEngine.kt:380-384`, comment admits it). `stopShare` then
builds the durable `live_stop` with that context, and `sendControl`'s 1:1 branch hits
`conv.peerUserId ?: return` (`:405`) — the durable stop is **silently skipped**. Offline
recipients keep rendering the share until `expiresAt` (the WS stop and server `loc_stop` reach
only live sockets). For a group share the correct route (`group.sendGroupLocationControl`,
`:404`) is never taken after a process restart.

### B6 — iOS: 2-member-group shares resume as 1:1 and misroute their durable stop (medium)

`resumeOutboundIfNeeded` infers `isGroup: targets.count > 1` (`LocationShareEngine.swift:118-127`).
A group with exactly one *other* member resumes as a 1:1, so `stopLiveShare`'s durable
`live_stop` goes down `ChatEngine.sendLocation` with the **group** `conversationId` on the 1:1
ratchet path (`:257-261`, `:396-414`) — a Double-Ratchet message addressed into an MLS
conversation. The share's WS stop and expiry still work; the durable stop for that case does not.

### B7 — iOS: sending a pin mid-share starves and then degrades the live stream (low-medium)

While a one-shot is pending, the shared delegate swallows **every** fix into the one-shot branch
and returns before `onFix` (`LocationService.swift:135-160`), so an active live share emits
nothing for up to the 10 s timeout each time a pin is captured. `requestOneShot` also sets
`manager.desiredAccuracy = .Best` (`:92`) and `fireOneShot` never restores the live profile's
`nearestTenMeters` (`:117-128`), so a share that outlives one pin runs at full-GPS accuracy
(the "4–8 %/h live-share profile" the file's own comments reserve for something else) until it
is restarted. The `isLiveStreaming` guard (`:115,121`) correctly prevents the *stop* from
killing the share — this is the disturbance that remains.

### B8 — both: the chat engines consume Map stops with no ownership guard (low, latent)

- iOS `handleInboundStop` runs for **every** `loc_stop`, including a friend's Map ghost:
  `stopped.insert(mapShareId)`, `LocationStore.end(id:)`, `LocationKeyStore.deleteKey`
  (`LocationShareEngine.swift:99-103,328-333`). Today these are no-ops only because chat keys are
  share-id-named in a different Keychain service (`LocationKeyStore.swift:31-50`) and
  `LocationStore.end` updates a nonexistent row (`LocationStore.swift:75-82`).
- Android `endInbound` likewise: `keyStore.remove(mapShareId)` on the chat prefs +
  `dao.markEnded` on a missing row (`LocationShareEngine.kt:113,361-365`).

Neither mirrors the explicit guard the Map engines have. Any future overlap in key naming or a
DB upsert-on-end would turn this from hygiene into a repeat of B3 in the other direction.

### B9 — Android: a Map stop is ignored (and "waiting" goes stale) when the key was background-captured (low)

`onStop` tests `inbound.containsKey(stopShareId)` only (`MapPresenceEngine.kt:564`) and does
**not** consult the background-capture fallback `MapInboundKeyStore` the fix path uses
(`:503`, `restoreInboundKey` :543-550). If a contact's `map_key` arrived while the app was dead
(captured by `ChatEngine` into `MapInboundKeyStore`, `ChatEngine.kt:1155-1163`) and no fix has
decrypted in-process yet, their WS `loc_stop` is dropped: the key survives in
`MapInboundKeyStore` and the contact stays in the persisted `waiting_senders` list
(`:658,677`). Similarly, a durable `map_off` processed only by the background `ChatEngine.sync`
removes the key (`ChatEngine.kt:1164`) but can never touch the engine's persisted
`waiting_senders`, leaving "sharing — waiting for location" showing for someone who went dark.

### B10 — platform divergence worth stating (informational)

- Swiping Voiid from Recents on Android ends **all** chat live shares
  (`LocationForegroundService.onTaskRemoved` → `stopAllFromSystem`,
  `LocationForegroundService.kt:56-64`); iOS continues emitting in the background. Both are
  defensible; they are just different promises.
- iOS wires chat inbound consumption and outbound resume only from the Chats tab
  (`ChatsHomeView.swift:168-169` → `configure()`/`resumeOutboundIfNeeded`), so a cold launch
  that never visits Chats streams Map presence but resumes no chat share. The Map engine, by
  contrast, is constructed at app start (`VoiidApp.swift:49`).
- `docs/LOCATION.md` §5 ("No `startUpdatingLocation` for the Map, ever", LOCATION.md:333-335)
  is stale: `MapLocationProvider.start()` deliberately added a filtered `startUpdatingLocation`
  foreground feed (`MapLocationProvider.swift:120-137`). The code documents why; the spec should
  be updated to match.

---

## 3. How WhatsApp + Signal do it

- **Signal ships no live location and no presence map at all.** The entire location surface in
  Signal-Android is a one-shot picker/`LocationRetriever` (`Signal stack/Signal-Android/app/src/
  main/java/org/thoughtcrime/securesms/maps/LocationRetriever.java`, `.../mms/LocationSlide.java`)
  and in Signal-iOS a `LocationPicker.swift` sending a static pin. One ephemeral request, no
  session, no stop signal — the interference class investigated here cannot exist. Voiid's P1
  static pin matches this shape.
- **WhatsApp live location** (public engineering write-ups; no source to cite) multiplexes every
  active share through a single owning location client per platform with per-session fan-out —
  exactly the pattern Voiid's chat engines already implement (`emitting` map over one manager,
  `LocationShareEngine.swift:53,289-308`; `outbound` map over one provider,
  `LocationShareEngine.kt:84,214-240`) with correct empty-check teardown (`:269` / `:260-264`).
  Session-end signals are keyed by *session*, and ending one chat's share cannot affect
  another's because no handler is keyed by sender. That is precisely the property Voiid's Map
  stop handlers violate on iOS (B1/B3: `MapKeyStore` inbound keys are sender-keyed,
  `MapKeyStore.swift:56-68`, so a share-scoped signal triggers a sender-scoped erase).
- The Signal-Server pattern for "superseded, not stopped" state changes is to carry the reason
  in the frame rather than reuse the terminal signal — the analogue here is adding a
  `kind`/`reason` to `loc_stop`, which the client can already route on (`WebSocketClient.swift:
  318-324` and `LocationRelay.kt:56-59` pass frames through untouched).

---

## 4. Recommended fixes (ordered)

1. **iOS — hand the current key to the whole audience on `addToAudience` (fixes B1).**
   Platform: iOS. Files: `apps/ios/Voiid/Voiid/Networking/MapPresenceEngine.swift` (change
   `distributeMapKey(key, to: targets)` at :393 to distribute to `audience.map(\.userId)`, as
   `goVisible` does at :334). Risk: minimal — re-sending the same key to holders is idempotent
   on the receiver (`ChatEngine.swift:1704-1717` overwrites the same Keychain entry).

2. **Backend — distinguish supersede from stop in the `loc_stop` frame (fixes B2, hardens B1).**
   Platform: backend + both mobile. Files: `backend/api/src/routes/location.ts` (add
   `reason: 'superseded' | 'ended'` and the share `kind` to the frame built in `signalStop`
   :82-100, threaded from `endShare` :103-114 and the supersede loop :233-240);
   `apps/ios/Voiid/Voiid/Networking/MapPresenceEngine.swift` `receiveStop` :511-535 and
   `apps/android/.../net/MapPresenceEngine.kt` `onStop` :552-570 (on `superseded`, retire the
   share id but keep the key and cached position). Risk: low — additive fields; old clients
   ignore them and keep today's behaviour.

3. **iOS — key the Map stop guard by share id, not sender (fixes B3).**
   Platform: iOS. Files: `apps/ios/Voiid/Voiid/Networking/MapPresenceEngine.swift` (:511-535):
   track the inbound map share id alongside the sender (persist next to `inboundSenders`,
   :594-599, populated from the `map_key` envelope's `s` — already delivered through
   `ChatEngine.swift:1714-1716`, which currently drops it for `map_key`) and require
   `stopShareId` to match before erasing; treat "sender known, no share id recorded, id
   unknown" as not-ours, mirroring Android `MapPresenceEngine.kt:564`. Risk: low; also pass the
   share id through the `voiidMapControlReceived` post for `map_key` in `ChatEngine.swift:1714`.

4. **iOS — persist and reconcile the Map outbound session (fixes B4).**
   Platform: iOS. Files: `apps/ios/Voiid/Voiid/Networking/MapPresenceEngine.swift` (persist
   `outboundShareId` + expiry beside `MapVisibilityState`/`MapKeyStore`; on `init` :77-100 and
   `noteForegrounded` :236-259 restore it, or reconcile via a `GET /location/shares` call added
   to `apps/ios/Voiid/Voiid/Networking/MapShareAPI.swift`, matching Android
   `MapPresenceEngine.kt:640-683`). If the row lapsed, re-run the `goVisible` path. Risk: low —
   the ghost hard-gate (`visibility.isVisible` read from store) still governs.

5. **Android — persist enough context to route the durable stop after a restart (fixes B5).**
   Platform: Android. Files: `apps/android/app/src/main/java/com/voiid/app/net/
   LocationShareEngine.kt` (`refresh()` :369-397 — read `isGroup`/`peerUserId` from the Room row
   it already writes at :196-201 (`LocationShareRow.peerUserId`, `kind`) or from the
   conversation store, instead of hardcoding `isGroup = false, peerUserId = null` at :381; make
   `sendControl` :401-407 log instead of silently `return` when 1:1 context is missing). Risk:
   minimal.

6. **iOS — store `isGroup` durably instead of inferring it (fixes B6).**
   Platform: iOS. Files: `apps/ios/Voiid/Voiid/Storage/LocationStore.swift` (persist an
   `is_group` column on outbound upsert, :30-55 region) and
   `apps/ios/Voiid/Voiid/Networking/LocationShareEngine.swift` (`resumeOutboundIfNeeded`
   :116-130 reads it instead of `targets.count > 1` at :124-126). Risk: needs a small SQLite
   migration in `apps/ios/Voiid/Voiid/Storage/LocationSchema.swift`.

7. **iOS — isolate the one-shot from the live profile (fixes B7).**
   Platform: iOS. Files: `apps/ios/Voiid/Voiid/Networking/LocationService.swift` — either give
   `requestOneShot` its own short-lived `CLLocationManager`, or (smaller) in the delegate
   `:132-163` forward fixes to `onFix` even while `oneShot != nil` when `isLiveStreaming`, and
   have `fireOneShot` :117-128 restore `desiredAccuracy = kCLLocationAccuracyNearestTenMeters`
   when `isLiveStreaming`. Risk: minimal.

8. **Both — add explicit ownership guards to the chat engines' stop handlers (fixes B8).**
   Platform: both-mobile. Files: `apps/ios/Voiid/Voiid/Networking/LocationShareEngine.swift`
   (`handleInboundStop` :328-333 — return unless `LocationStore.hasActiveInbound(shareId:)` or
   the id is in `emitting`/`stopped`); `apps/android/.../net/LocationShareEngine.kt`
   (`endInbound` :361-365 — return unless `inboundViews.containsKey(shareId)` or the chat
   keystore holds it). Risk: none; converts accidental no-ops into intentional ones.

9. **Android — consult the background key store in `onStop`, and reconcile `waiting_senders` (fixes B9).**
   Platform: Android. Files: `apps/android/.../net/MapPresenceEngine.kt` (`onStop` :552-570 —
   fall back to `MapInboundKeyStore.get(ctx, stopShareId)` like `onFix` does at :503, erase the
   store entry and the subject on match; in `onForeground`/`recomputeSubjects` :286-327, drop any
   `waiting_senders` entry whose key no longer exists in either registry);
   `apps/android/.../net/MapInboundKeyStore.kt` unchanged. Risk: minimal.

10. **Docs — update `docs/LOCATION.md` §5 iOS Map bullet** (LOCATION.md:333-335) to describe the
    current filtered `startUpdatingLocation` + significant-change design of
    `MapLocationProvider.swift:120-143`, so the spec stops contradicting the shipped provider.
    Platform: all (docs only). Risk: none.
