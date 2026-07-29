# Maps & Avatars Upgrade Plan

**Status**: ✅ implemented 2026-07-28 (all five features; both trees build clean) · **Scope**: iOS + Android + (one small backend read already exists — no schema changes expected)

> **Execution notes (2026-07-28).** All five features are implemented. Two plan assumptions turned out
> differently against the real code, and the implementation follows the code, not the plan:
>
> - **Feature 5 / Android `AvatarCache`** — the plan said to port iOS's disk-cache semantics from
>   scratch. Android already had `MediaCache` (memory + `files/media`, SHA-256 keyed) and a working
>   presigned-download path in `ProfileAvatar`. The new `net/AvatarCache.kt` is therefore a thin
>   *resolver* over those tiers (adding ref-kind resolution, single-flight de-duplication and negative
>   caching) rather than a second cache — so sign-out still wipes everything through one path.
> - **Feature 2 G1 / Android observability** — the plan flagged that `LiveShareView.lastFix` might need
>   promoting to Compose state. It was already fine: `inboundViews` is a `mutableStateMapOf` and
>   `onFixFrame` replaces entries via `copy()`. G1 was purely a view-layer fix on Android. iOS drives
>   the same thing off the engine's `@Published version` counter.
> - **Feature 3b / iOS** — `contactMarker` already loaded real photos via `ProfileAvatarButton`; it was
>   swapped to the new shared `MapAvatarPin` so both platforms and both surfaces (Map tab + live detail)
>   use one component.
> - **Feature 4 / Android** is shipped **gated**: the code, dependency and UI are complete, but
>   **Places API (New) must be enabled on the Maps key in Cloud Console** before it returns results.
>   Verified live on-device: the SDK initializes and issues a real request, the API returns
>   `9011: ...AutocompletePlaces are blocked`, and the app degrades to an empty suggestion list with a
>   logcat hint — no crash, no error UI. See LOCATION.md §7 "Place search".
>
> **Not changed, deliberately**: no cadence, interval, accuracy, encryption or foreground-service edits
> anywhere in the diff (`git diff` over `CADENCE|PRESENCE_INTERVAL|MIN_DISTANCE|startUpdatingLocation|
> ForegroundService|desiredAccuracy` is empty). Ghost mode and the kill switch are untouched.
>
> **Pre-existing issue noticed, not fixed** (out of scope): `AndroidManifest.xml` declares the
> `com.google.android.geo.API_KEY` meta-data **twice** (~L117 and ~L166). It builds today, but the
> duplicate should be removed in a separate change.
**Audience**: any AI agent or engineer executing this work. Everything referenced below was verified against the codebase on 2026-07-28.

This document covers five features. Each section has: current behavior, root cause (verified, with file/line refs), the fix, and acceptance criteria. Read the **Architecture primer** and **Invariants** first — they constrain every fix.

---

## Architecture primer (read first)

Location in Voiid is **end-to-end encrypted** and spec'd in [docs/LOCATION.md](LOCATION.md). Key facts an agent must know before touching anything:

- **Three payload kinds** (LOCATION.md §1): P1 static pin (a normal E2EE message), P2 share control (start/stop/rekey, normal E2EE message path), P3 position fixes (a symmetric-key encrypted stream relayed over **WebSocket only**, never stored server-side in plaintext).
- **Two distinct sharing systems** that must never be conflated:
  - **(A) Conversation live share** — explicit, timer-bounded, high-cadence (10–15 s / 25 m filter). Engine: `LocationShareEngine` (both platforms). Rendered by the in-chat bubble.
  - **(B) Map presence** — ambient, coarse (5 min / 250 m filter), foreground-only, ghost-by-default. Engine: `MapPresenceEngine` (both platforms). Rendered by the Map tab.
- **The tile-leak rule** (LOCATION.md §4): maps are rendered **on-device by each viewer**; we never upload rendered map thumbnails. Any fix that adds a map image upload is wrong.
- **Android Maps key**: build-time secret via `${MAPS_API_KEY}` manifest placeholder, sourced from `local.properties` / `-PMAPS_API_KEY` / env (`apps/android/app/build.gradle.kts:37-47`). `BuildConfig.MAPS_CONFIGURED` gates all GoogleMap instantiation. **The key is configured and working on the dev machine** — the world map renders in the Map tab and lite tiles render in chat (verified live on device 2026-07-27). Do not "fix" the key.

### Key files

| Concern | Android | iOS |
|---|---|---|
| In-chat location bubble | `apps/android/.../main/LocationViews.kt` (`LocationPinBubble`, `LocationMap`) | `apps/ios/.../Main/LocationPinBubble.swift` |
| Full-screen location detail | `apps/android/.../main/LocationDetailView.kt` | `apps/ios/.../Main/LocationDetailView.swift` |
| Map tab | `apps/android/.../main/MapTabView.kt` | `apps/ios/.../Main/MapTabView.swift` |
| Conversation live share engine | `apps/android/.../net/LocationShareEngine.kt` | `apps/ios/.../Networking/LocationShareEngine.swift` |
| Map presence engine | `apps/android/.../net/MapPresenceEngine.kt` | `apps/ios/.../Networking/MapPresenceEngine.swift` |
| Background location FGS | `apps/android/.../net/LocationForegroundService.kt` | (iOS: background mode, LOCATION.md §5) |
| User directory (names/photos) | `apps/android/.../store/UserDirectory.kt` | `apps/ios/.../` (directory + `Networking/AvatarCache.swift`) |
| Chat home grid | `apps/android/.../main/ChatsHomeView.kt` (`GridCard`) | `apps/ios/.../Main/ChatsHomeView.swift` (`gridCard`) |

---

## Invariants — do not violate

1. **Never** send plaintext coordinates through anything the server stores. P3 fixes go over WS with the share's symmetric key only.
2. **Never** upload a rendered map tile/thumbnail (viewer-side rendering only).
3. Map presence stays **coarse and foreground-only** (no FGS for the Map tab; no cadence increase beyond what §5 of LOCATION.md allows — see Feature 3 for the compliant "live-ish" approach).
4. A missing/broken Maps key must degrade to `MapUnavailableCard`, never crash, never silent grey tiles.
5. Ghost mode and the kill switch must keep working exactly as they do (`MapPresenceEngine.goGhost/killSwitch`).
6. Match existing code style: file-header comment blocks explaining *why*, Compose/SwiftUI idioms already in the files you touch.

---

## Feature 1 — Android: in-chat map tap launches the Google Maps app instead of opening in-app

### Current behavior
Tapping the map thumbnail inside a location bubble in a chat opens the **external Google Maps app**. The in-app full-screen detail (`LocationDetailView`, which has the interactive SDK map + explicit "Open in Maps"/"Directions" buttons) never appears.

### Root cause — verified
`LocationViews.kt:202-208`: the bubble is a `Column` with `.clickable { showDetail = true }`, containing `LocationMap(lite = true)`. `LocationMap` (line 104-127) instantiates a real `GoogleMap` composable with `GoogleMapOptions().liteMode(true)` (line 109).

**Google Maps lite mode's documented default click behavior is to launch the Google Maps mobile app.** The `GoogleMap` child view consumes the touch before the parent `Column`'s `clickable` ever fires, and the SDK executes its default intent. The parent clickable is dead code for any tap landing on the map surface (i.e., ~all of them). This is why the in-app detail never opens.

(iOS is unaffected: `LocationPinBubble.swift:95` opens `LocationDetailView` via `fullScreenCover`, MapKit has no such default.)

### Fix
In `LocationMap` (`LocationViews.kt`), when `lite = true`, make the map **non-interactive and let the parent receive the tap**. Two changes:

1. Pass a click-through: the maps-compose library exposes `GoogleMap(... , onMapClick = ...)` but for lite mode the robust approach is to **overlay a transparent `Box` that intercepts all input** above the map, so the SDK never sees the tap:

```kotlin
Box(modifier) {
    GoogleMap(/* existing params, liteMode(lite) */) { Marker(...) }
    if (lite) {
        // Lite mode's default tap action launches the external Google Maps app and steals
        // the touch from the bubble's own clickable — swallow input here so the parent
        // (LocationPinBubble) opens the in-app LocationDetailView instead.
        Box(Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures { /* consumed; parent clickable handles it */ } })
    }
}
```

   Note: a plain input-swallowing overlay also blocks the parent `clickable`. The correct wiring is to give `LocationMap` an optional `onClick: (() -> Unit)?` parameter, have the overlay call it, and have `LocationPinBubble` pass `{ if (hasCoord) showDetail = true }` — then remove/keep the Column's `.clickable` as a fallback for the non-map ("Locating…", ended) states. Check the STALE/ENDED desaturated overlay (line 122-125 in `LocationMap`) still renders above the map but below the tap overlay.

2. Same treatment anywhere else `LocationMap(lite = true)` is used (grep for `lite = true`).

Also verify `MapUiSettings` in `LocationMap` keeps `mapToolbarEnabled = false` (it does today, line 112) — the toolbar is a second path to the external app.

### Acceptance
- Tapping a static-pin bubble in a chat opens the full-screen in-app `LocationDetailView` (SDK map, close button, coordinates, "Open in Maps"/"Directions" buttons at the bottom).
- Tapping a live-location bubble does the same.
- The external Google Maps app opens **only** from the explicit "Open in Maps" / "Directions" buttons.
- The "Locating…" (no fix yet) bubble state does nothing on tap (no coords), as today.

---

## Feature 2 — Make conversation live location WhatsApp-grade (both platforms)

### Current behavior & gaps — verified
The pipeline (P2 control + P3 fix stream, 10–15 s cadence, FGS on Android, background mode on iOS) **exists and works**. What's missing is the *presentation* layer polish that makes WhatsApp's feel live:

| Gap | Evidence |
|---|---|
| **G1 — Detail view is a frozen snapshot.** | `LocationDetailView.kt:42-63` receives `ref: ChatEngine.LocationRef` and renders `ref.lat/ref.lon` once. It never observes `LocationShareEngine.inbound(shareId)` — a friend walking across town stays pinned where they were when you opened the sheet. (Contrast: the *bubble* (`LocationPinBubble`, line 196-198) does read `inbound.lastFix`.) iOS `LocationDetailView.swift` has the same gap (no `inbound`/`onReceive` observation — verified by grep). |
| **G2 — No camera follow / marker animation.** | Marker position jumps between fixes; camera never re-centers. WhatsApp animates the marker between fixes and offers a recenter affordance. |
| **G3 — No countdown / freshness in the detail view.** | WhatsApp shows "Live until 14:32" + "updated just now". The bubble has state (LIVE/STALE/ENDED via `ShareState`) but the detail view shows none of it. |
| **G4 — No "share my live location back" affordance** in the detail view (WhatsApp shows your own share state + a start button on the same screen). Optional, ship last. |
| **G5 — Multiple sharers in one conversation render as separate bubbles only.** WhatsApp shows all active sharers of that chat on ONE detail map. `LocationShareEngine` already tracks all inbound shares (`inboundViews`) — filter by `conversationId`. |

### Fix plan (Android first, then mirror on iOS)

**G1 (the core fix):** in `LocationDetailView`, resolve the live view and recompose on new fixes:

```kotlin
val inbound = ref.shareId?.let { LocationShareEngine.inbound(it) }
// LiveShareView.lastFix must be observable — if it is a plain var today, promote it to
// a MutableState/StateFlow inside LocationShareEngine so Compose recomposes on each fix.
val fix = inbound?.lastFix
val lat = fix?.lat ?: ref.lat ?: return-early
```

Check how `LiveShareView.lastFix` is stored (`LocationShareEngine.kt`, `onFixFrame` line 296): if it isn't backed by Compose state, that's the first change — make fix delivery observable (a `mutableStateOf` per inbound share, or a `StateFlow` collected with `collectAsState()`). The bubble currently recomposes because message-list recomposition happens for other reasons; make it explicit for both.

On iOS, mirror with an `@Observable`/`ObservableObject` inbound share view consumed by `LocationDetailView.swift`.

**G2:** in the detail map:
- Animate the marker: Android — `rememberMarkerState` + animate position between old and new `LatLng` (e.g. `ValueAnimator`-style interpolation over ~1 s, or use the maps-compose `MarkerState.position` with an `animate*AsState` wrapper). iOS — `withAnimation` on the annotation coordinate.
- Camera: auto-follow while the user hasn't panned; the first manual pan sets a `userPanned` flag; add a small "recenter" FAB that clears it. (Detect pan: `cameraPositionState.cameraMoveStartedReason == Gesture` on Android; `MapCameraChangeContext`/`onMapCameraChange` on iOS 17 MapKit.)

**G3:** header/footer chrome in the detail view: `"Live · ends in 43 min"` computed from `ref.expiresAt` (tick with a 1 s/1 min `LaunchedEffect` timer), plus `"Updated Xs ago"` from the last fix timestamp, plus the STALE (grey) and ENDED (terminal card) states already defined by `ShareState` — reuse the bubble's state derivation (extract it into a shared helper rather than duplicating).

**G5:** `LocationShareEngine` — add `inboundForConversation(conversationId): List<LiveShareView>`; detail view renders one marker per sharer (each with the avatar-pin from Feature 3's shared component) and fits camera bounds to all of them until the user pans.

**Do not touch cadence, encryption, or the FGS** — 10–15 s / 25 m is already the WhatsApp-comparable spec (LOCATION.md §5) and the battery/App-Review posture depends on it.

### Acceptance
- Open a live-location detail while the sharer moves (simulate: second device or `adb emu geo fix` on the emulator): the pin moves without reopening, animated, camera follows until you pan, recenter button restores follow.
- Countdown to expiry visible and ticking; "updated Xs ago" visible; STALE at >90 s without a fix; ENDED terminal state on stop/expiry.
- Two people sharing in the same group render on one detail map.
- Battery/cadence measurements unchanged (no new wakeups; verify no `startUpdatingLocation`/interval changes in the diff).

---

## Feature 3 — Map tab: friends' pins with profile photo, updating live

### Current behavior — verified
- **Android** `MapTabView.kt:288-296`: subjects render as the **default red Google marker** (`Marker(state, title, snippet, alpha)`) — no avatar, no profile.
- **iOS** `MapTabView.swift:127-190` already renders a custom `contactMarker` (circle avatar with state-colored stroke) — use it as the design reference, but check it loads the **real photo** via `AvatarCache` and not just initials.
- Updates: `MapPresenceEngine` receives P3 fixes over WS (`onFix`, Android line 402) and updates `MapSubject`s — the plumbing for on-screen movement exists; markers move only as often as senders publish (5 min / 250 m — **by design**, see below).

### What "live like WhatsApp" means here — read carefully
The Map tab is **presence (B)**, deliberately coarse (LOCATION.md §5: "The Map is coarse, last-known, and foreground-driven"). Do **not** raise the ambient cadence — that's the battery/safety line the spec draws, and "one small pin that updates live" at WhatsApp fidelity is what **conversation live share (A)** is for.

The compliant way to get live movement on the Map tab: **when a contact has an active conversation live share with me (A), surface THAT share's high-cadence fix stream on the Map tab too** — same decrypted stream the chat bubble uses, no new publishing, no cadence change for anyone. A contact sharing "to all contacts using the map section" moves at presence cadence (minutes); a contact actively live-sharing with you moves at 10–15 s. That matches WhatsApp's own split (their map is also built from explicit live shares).

### Fix plan

**3a — Avatar pins (Android)**: replace the default marker with a custom `BitmapDescriptor`:
- Build a `MarkerIconFactory`: circular avatar bitmap (~44 dp) with a 2 dp state-colored ring (LIVE = `VoiidColor.primary`, STALE = grey, matching iOS `contactMarker`), a small pointer nub, drawn via `Canvas` into a `Bitmap` → `BitmapDescriptorFactory.fromBitmap(...)`.
- Photo source: `UserDirectory.photoUrl(userId)` → download/cache (this is the same avatar pipeline Feature 5 builds — **build Feature 5's Android `AvatarCache` first and reuse it here**). Fallback: initials on a colored disc (deterministic color from userId hash), never the red default pin.
- Marker icons must be generated off the composition (remember + LaunchedEffect per subject; regenerate only when photo or state changes — bitmap generation on every recomposition will jank the map).
- Tap on a pin → the existing behavior (title/snippet today) becomes a small bottom card: avatar, name, "Updated X min ago", and an "Open chat" button.

**3b — Avatar pins (iOS)**: verify `contactMarker` uses `AvatarCache.cached(...)` for the real photo; if it renders initials only, wire the photo in. Add the same tap card if missing.

**3c — Live share surfacing on the Map**: in the Map tab view model, merge two sources:
1. `MapPresenceEngine` subjects (as today).
2. Active inbound **conversation** shares from `LocationShareEngine` (`inboundViews`), mapped to the same `MapSubject`-like shape with `state = LIVE` and the high-cadence fix.
   Dedupe by userId (conversation share wins — it's fresher). Movement animation: same marker-position animation component as Feature 2 G2 — build it once, share it.

**3d — "Sharing personally with me" visibility**: this is exactly 3c — a personal live share already reaches you as an inbound (A) share; it just isn't drawn on the Map tab today.

### Acceptance
- Every subject on the Map renders as a circular profile photo pin (photo when available, initials fallback), state ring color matches LIVE/STALE.
- A contact actively live-sharing with you (from any chat) appears on the Map tab and moves at the share's cadence with animation; when the share ends they fall back to presence state (or disappear if not presence-visible).
- Presence-only contacts still update at presence cadence — **verify no cadence/interval change** in `MapPresenceEngine` in the diff.
- Ghost mode/kill switch unaffected.

---

## Feature 4 — Map tab: place search + directions (both platforms)

### Current behavior
No search, no directions anywhere. External handoff exists only from location bubbles ("Open in Maps"/"Directions", `LocationDetailView`).

### Design decision (make it consistent on both platforms)
- **Search: in-SDK.** Both platforms can do this natively without shipping a routing engine.
- **Directions: hand off to the system maps app in v1.** In-SDK turn-by-turk routing requires the Google Directions/Routes **web API** (billing per request, needs a server-side proxy to avoid shipping an unrestricted key) on Android and is nontrivial to draw/maintain; MapKit directions are free on iOS but Android has no free equivalent — shipping asymmetric quality is worse than a clean handoff. LOCATION.md §10.10 already states "No in-app routing — hand off to the system map app". **Optional v2** (only if explicitly asked): iOS `MKDirections` polyline in-SDK + Android via a backend `/maps/route` proxy to the Routes API.

### Fix plan

**iOS** — all native, no new keys:
- Search UI: a search field pinned above the map (match the existing frosted-pill header style from `MapTabView.swift`); results via `MKLocalSearchCompleter` (autocomplete) + `MKLocalSearch` (resolve). Selecting a result drops a POI pin + camera move + a bottom card (name, address).
- Bottom card buttons: **Directions** → `MKMapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: .driving])` (Apple Maps, free, native), and **Share** → optional: send as a static pin (P1) into a chosen chat (reuses `LocationShareEngine.sendPin`).

**Android** — needs one new dependency + one Cloud Console toggle:
- Enable **Places API (New)** for the existing Maps key in Google Cloud Console; add `com.google.android.libraries.places:places` (Places SDK for Android). Autocomplete via `PlacesClient` + `FindAutocompletePredictionsRequest` (session tokens per search session to keep billing in the cheap autocomplete tier), resolve via `FetchPlaceRequest` (fields: ID, NAME, LAT_LNG, ADDRESS only).
- Same UI as iOS: search field above the map, result list, pin + bottom card on select.
- **Directions** button → `Intent(ACTION_VIEW, "google.navigation:q=$lat,$lon")` with fallback to `geo:` — the exact pattern already in `LocationDetailView.kt:72-79`; extract that into a shared helper (`Handoffs.kt`) instead of duplicating.
- Key restriction check: the API key's app restriction (package `com.voiid.app` + SHA-1) already exists; ensure "Places API (New)" is in the key's allowed-API list or Places calls will silently return errors.
- Gate the whole search UI behind `BuildConfig.MAPS_CONFIGURED` like everything else.

### Acceptance
- Typing in the Map tab search shows autocomplete suggestions; selecting one moves the camera and shows the place card.
- Directions button opens the system maps app in navigation mode to the selected place (Google Maps on Android, Apple Maps on iOS).
- No search → no network calls (session tokens; no idle Places traffic).
- With no Maps key configured (Android), search is hidden and the existing `MapUnavailableCard` behavior is unchanged.

---

## Feature 5 — Chat home grid: other people's profile photos never show

### Current behavior & root cause — verified
Both platforms' chat grid tiles show the faint Voiid wordmark placeholder for every conversation, always:

- **Android** `ChatsHomeView.kt:679-691` (`GridCard`): renders `VoiidWordmark(...)` **unconditionally** — it never even looks at a photo field.
- **iOS** `ChatsHomeView.swift:342-346` (`gridCard`): `if let name = conv.photoName, let ui = UIImage(named: name)` — `photoName` is a **bundled-asset name from the old dummy data**. For every real conversation it's nil (or names no asset), so `UIImage(named:)` fails and the wordmark shows. Real peers' photos live at `photo_url` (an absolute URL or an R2 object key) via the user directory — this render path never consults it.

The data + plumbing already exist: `UserDirectory.photoUrl(userId)` (Android, `UserDirectory.kt:108`) and iOS `AvatarCache` (`Networking/AvatarCache.swift` — memory + disk cache, resolves both absolute URLs and R2 keys via presigned GET; header comment explicitly lists "chat grid" as an intended consumer). Other surfaces (chat header, stories) already use them — the home grid was simply never wired.

### Fix plan

**iOS** (small — cache exists):
- In `gridCard`, resolve the peer's photo: for a direct conversation, `directory.photoUrl(conv.peerUserId)` → `AvatarCache.cached(ref)` for instant paint + async fetch for a miss (follow the exact pattern of an existing `AvatarCache` consumer, e.g. `ProfileAvatarButton`). Keep `photoName` as a legacy fallback, wordmark as final fallback.
- Groups: use the group's `photoName`/photo if set; wordmark otherwise (group photos may be a separate feature — don't block on it).

**Android** (needs the cache built — this is the prerequisite for Feature 3a):
- Port iOS `AvatarCache` semantics into `apps/android/.../net/AvatarCache.kt`: memory `LruCache<String, Bitmap>` + disk cache in app files dir keyed by SHA-256 of the ref; resolve `photo_url` that is either an absolute URL (plain GET) or an R2 object key (presigned GET via the existing `MediaService`/API — see how iOS `AvatarCache` does the two-request presigned download, and how Android `ProfileService`/`ProfileAvatar` (SettingsScreen.kt:476) currently loads the *own* photo — reuse that fetch path rather than inventing one).
- `GridCard`: `UserDirectory.photoUrl(conv.peerUserId)` → AvatarCache → render bitmap scaled to fill the rounded square; wordmark fallback while loading/absent. Load with `remember(conv.peerUserId)` + `LaunchedEffect`, never blocking composition.
- Check `VConversation` exposes `peerUserId` for direct chats (it's already passed to calls at `ChatsHomeView.kt:329`) — for groups, wordmark fallback as on iOS.
- Then reuse this cache in `ChatUI.kt:198` (in-chat header avatar already calls `UserDirectory.photoUrl` — make sure it goes through the cache too) and in Feature 3a's marker factory.

### Acceptance
- Chat home grid shows real profile photos for direct chats where the peer has one set (verify with the existing accounts: Nehal/Darshan have photos if set on their profiles); wordmark only for photo-less peers and groups.
- Photos paint instantly on second app launch (disk cache) and offline.
- No per-frame network requests (open/close chats home repeatedly; watch logcat for repeated presign calls — there must be none after first load).
- Own profile avatar (top-left) unaffected.

---

## Suggested execution order

1. **Feature 5 Android AvatarCache** (prerequisite for 3a) + Feature 5 iOS — isolated, low-risk, high-visibility.
2. **Feature 1** — one-file Android fix, unblocks in-app map UX.
3. **Feature 2** — G1 first (observable fixes + live detail view), then G2/G3 polish, then G5.
4. **Feature 3** — 3a/3b avatar pins (reusing AvatarCache + the G2 animation component), then 3c/3d live-share surfacing.
5. **Feature 4** — additive, independent; needs the Places API enabled in Cloud Console before the Android half can be tested.

## Build & verify

```bash
# Android (JAVA_HOME is mandatory; /usr/libexec/java_home is empty on this machine)
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
cd apps/android && ./gradlew installDebug        # installs on connected device(s) + emulator

# iOS
xcodebuild -scheme Voiid -project apps/ios/Voiid/Voiid.xcodeproj \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/voiid-dd build

# Simulating movement for Features 2/3 without a second phone:
# Android emulator:  adb -s emulator-5554 emu geo fix <lon> <lat>   (repeat with changing coords)
# iOS simulator:     Features > Location > Freeway Drive / Custom Location, or `xcrun simctl location`
```

Both trees currently build clean (verified 2026-07-27/28). Backend is deployed and healthy at `https://api-dev.voiid.app/health`; both `main` and `dev` deploy automatically on push (they share one Vultr box — see the repo's deploy workflows).
