# Voiid Location — Spec (v1)

Two distinct features, one shared substrate.

- **(A) Location in conversations** — a one-off pin and time-bounded live sharing, inside 1:1 and group chats.
- **(B) The Map** — a dedicated Snapchat-Map-style surface showing contacts who have explicitly chosen to be visible to you.

**(B) is materially more dangerous than (A) and is designed as such: you appear to no one until you name individual people.**

Everything here is buildable today with zero changes to `packages/e2e-core`.

---

## 0. The one-paragraph summary

Coordinates never leave a device unencrypted. A static pin is an ordinary E2EE message with a
JSON envelope as its plaintext — 1:1 over the Double Ratchet, group over MLS. A live share mints a
fresh random 32-byte key (`generateMasterSecret`), ships that key to the audience inside a durable
E2EE control message, and then streams position fixes as `encryptBackup(shareKey, fix)` blobs over
the ephemeral WebSocket relay — no DB rows, no pushes, no ratchet advance per fix. The server stores
one small row saying "a share exists between A and B until T" and nothing else. The Map is the same
machinery with a coarse cadence, an empty-by-default allow-list, and Ghost Mode.

---

## 1. Transport

Three payload classes with three different transports. This split is the whole design.

### P1 — Static pin (one-off) → existing message path

Durable content that belongs in chat history, so it is a message. Zero new transport.

- **1:1**: `ChatEngine.encryptFanout` → `POST /messages/send` with `content_type: "location"`.
- **Group**: `GroupEngine.sendGroupMessage` → one MLS ciphertext replicated to every member device,
  `content_type: "group"` (unchanged).
- Plaintext = the `LocationEnvelope` below with `k:"pin"`.
- Cost: one message. One `messages` row, one `message_ciphertexts` row per device, one content-free
  wake push. Identical to sending a text message.

**This is the v1 core. If live sharing is deferred, the pin ships alone and is a complete feature.**

### P2 — Share control (start / stop / rekey / map-key) → existing message path

Rare (a handful per share) and **must be durable**, because durability is what lets a *stop* reach a
recipient who is offline. Same transport as P1, `content_type: "location"` (1:1) or the group MLS path.

Control messages carry the share key. **The key distribution is where authorization actually happens** —
the server never sees it, and only devices with a live ratchet/MLS session get it.

### P3 — Position fixes (the stream) → WebSocket relay ONLY

High-rate, ephemeral, worthless when stale. **Never a `messages` row, never a push, never persisted
client-side beyond the single most recent fix.**

The crypto scout measured what the message path costs at one update per 10 s for 5 recipients ×
2 devices: 3,600 wake pushes/hour to *recipients'* phones, 3,600 Keychain pickle writes, 5,400 HTTP
round-trips, 1,800 permanent DB rows, and a full rewrite of the plaintext message store per append.
That is disqualifying, and the push storm drains the recipients, not just the sharer. So P3 does not
touch it.

**How P3 stays E2EE with one ciphertext for the whole audience:**

1. At share start the sender calls `generateMasterSecret()` → 32 random bytes = `shareKey`.
2. `shareKey` travels to the audience inside the P2 `live_start` control message (over the ratchet /
   MLS). The server never sees it.
3. Every fix is `encryptBackup(shareKey, fixJSON)` → **one** ciphertext, decryptable by every
   authorized recipient on every one of their devices.
4. That one blob is relayed to each recipient's `channel:user:<id>`.

Why this and not per-device `Session.encrypt`:

| | per-device ratchet | shared `shareKey` |
|---|---|---|
| encrypts per fix | N devices | 1 |
| Keychain pickle writes per fix | N | 0 |
| ratchet advance per fix | yes | none |
| `MAX_MESSAGE_GAP=2000` landmine (5.5 h of one-way streaming) | **yes** | none |
| `MAX_MESSAGE_KEYS=40` skipped-key trap | **yes** | none |
| post-compromise-security not refreshed on a one-way stream | **yes** | n/a |
| violates "never put a device's ciphertext on the shared user channel" | **yes** | no — it is audience-wide material, not per-device |
| revocation | drop the device from fan-out | mint a new key, one control message per remaining device |

The shared-key design also resolves the user-channel problem cleanly: Redis channels are per-**user**,
and `routes/messages.ts` states the rule that a device's ciphertext is never placed on the shared user
channel. A shared-audience blob is not per-device material, so the rule is respected rather than
excepted.

**The honest cost, which must be documented in-app and in code comments:** there is no exposed KDF in
`e2e-core` (no 32→32 derivation), so a key *chain* is impossible. One share = one key for its whole
duration. There is **no forward secrecy within a single share**: whoever holds `shareKey` can decrypt
every fix in that share. Forward secrecy *across* shares is preserved, because every share mints a
fresh random key. Since fixes are never stored anywhere, the exposure window is the live stream only.

**Trap:** `encryptBackup` derives its AES key via `HKDF-SHA256(secret, info="VOIID backup key v1")` —
the same label as real account backups. A `shareKey` **MUST** come from `generateMasterSecret()` and
**MUST NEVER** be a user's backup master secret, or the two purposes derive the same AES key.

### What a single update contains

Plaintext of one fix (≈100–160 bytes):

```json
{ "_vloc": 1, "k": "fix", "s": "<share_id uuid>", "n": 417, "t": 1753257600123,
  "lat": 12.97163, "lon": 77.59460, "acc": 18.0,
  "alt": null, "hdg": null, "spd": null }
```

`_vloc` is the envelope discriminator (see §4). `n` is a monotonic sequence so an out-of-order relay
frame is dropped rather than rendered as a jump backwards. `alt`/`hdg`/`spd` are reserved and not drawn
in v1. Coordinates are rounded to **5 decimals (~1.1 m)** for live shares and **4 decimals (~11 m)**
for Map presence — rounding at the source, before encryption.

WS frame in:

```json
{ "type": "loc_update", "share_id": "<uuid>", "recipient_ids": ["<uuid>", ...], "ciphertext": "<b64>" }
```

WS frame out (rebuilt field-by-field, sender stamped from the JWT — never echoed):

```json
{ "type": "loc_update", "share_id": "<uuid>", "from_user_id": "<uuid>", "ciphertext": "<b64>", "ts": 1753257600123 }
```

**Metadata the server sees on the wire:** `from_user_id`, `share_id` (an opaque UUID), the recipient
list, and the frame timing. It does not see position, movement, or accuracy. This is the same class of
metadata as a typing indicator. Stated, not hidden.

### Offline recipients on P3

Redis pub/sub has zero persistence — a frame published while the recipient holds no socket evaporates.
Mirror the existing `call:offers:<user>` buffer, with one deliberate difference:

- Key `loc:last:<recipient_user_id>`, a hash, field `share_id` → the outbound frame.
- `hset` on every update (so it always holds the **latest only** — never a queue; a replay of stale
  historical positions is worse than useless), `expire(key, LOC_BUFFER_TTL)` where
  `LOC_BUFFER_TTL = 300` seconds (env `VOIID_LOC_BUFFER_TTL_SECONDS`).
- `flushPendingLocation(userId, ws)` runs on socket connect alongside `flushPendingOffers`.
- **Unlike offers, do NOT delete on flush** — a second device of the same user reconnecting also needs
  it, and replaying an idempotent latest-fix is harmless. Let the TTL reap it.
- `loc_stop` does `hdel`, so a stopped share can never be resurrected from the buffer.

The buffered value is ciphertext. The server buffers a blob it cannot read.

---

## 2. Never plaintext server-side — structural enforcement

`assertOpaque` (`packages/common-utils/src/crypto.ts`) rejects only `plaintext | text_content | body |
message_text`. **A `latitude` field sails straight past it.** So:

Add `assertNoCoordinates(obj)` next to it — a recursive guard throwing on any key matching
`lat | lon | latitude | longitude | coords | coordinates | accuracy | altitude | speed | heading |
geo | position`. Call it at the top of **every** handler in `routes/location.ts`, on the whole body.

No location endpoint accepts or returns a coordinate. **There is deliberately no `POST /location/update`
HTTP route** — if one existed, someone would eventually put a coordinate in it. Fixes are WS-only, and
the WS handler treats `ciphertext` as an opaque base64 string it copies and never parses.

---

## 3. Duration and revocation

### Durations

- Conversation live share: **15 minutes / 1 hour / 8 hours**. No indefinite option.
- Map presence: no fixed timer, but a **hard 24-hour auto-ghost** — if the app has not been foregrounded
  in 24 h the client stops emitting and the server row expires. Visibility is never something you forget
  about for a week.

### How a share ends

1. **Timer expiry — the primary guarantee.** Both sides hold `expiresAt` locally. The recipient hides
   the live marker at `expiresAt` **with zero further network contact**. This works if the sender is
   dead, offline, uninstalled, or hostile. Everything else below is an optimisation on top of it.
2. **Explicit stop.** Three things fire, in this order: (a) a `loc_stop` WS frame for instant effect on
   live sockets; (b) a durable `live_stop` control message over the message path — *this is how a stop
   reaches an offline recipient*, and it is the reason P2 uses the durable transport; (c)
   `DELETE /v1/location/shares/:id`, which sets `ended_at`, publishes a routing signal, and `hdel`s the
   last-fix buffer.
3. **Revoke one recipient.** `DELETE /v1/location/shares/:id/targets/:user_id`, then send `live_stop` to
   that recipient only, then mint a **new** `shareKey` and send `live_rekey` to the remaining audience.
   One extra control message per remaining device, once. After the rekey the removed recipient's key
   decrypts nothing further.
4. **Recipient opts out.** `POST /v1/location/shares/:id/leave` — a viewer can stop seeing someone
   without asking them.
5. **Degradation.** OS permission revoked, app uninstalled, phone off: the sender simply stops emitting.
   The recipient sees *Stale*, then *Ended* at `expiresAt`.

### Three recipient-visible states — never conflated

| State | Condition | Rendering |
|---|---|---|
| **Live** | last fix newer than `2 × cadence + 30 s` | solid accent marker, "Updated 12s ago" |
| **Stale** | older than that, but `now < expiresAt` and no stop received | desaturated marker, dashed halo, "Last seen 4 min ago · may have lost signal". Last known position still shown. |
| **Ended** | a `live_stop` arrived, **or** `now >= expiresAt` | marker removed from the map. The chat bubble collapses to a static "Shared live location · ended 14:32" with the final known pin frozen. **Never a live marker.** |

"Lost signal" and "stopped sharing" are different words, different colours, different marker shapes.
That distinction is a safety property, not polish.

---

## 4. The static pin, and how location renders in a conversation

### Envelope

The plaintext of a location message. Versioned and self-describing, because no AEAD here accepts AAD —
the discriminator and identifiers live *inside* the authenticated plaintext, where GCM covers them.

```jsonc
{
  "_vloc": 1,                 // discriminator; distinguishes from a plain text body
  "k": "pin",                 // pin | live_start | live_stop | live_rekey | map_key | map_off | fix
  "s": "<share_id>",          // omitted for k:"pin"
  "t": 1753257600123,
  "lat": 12.97163, "lon": 77.59460, "acc": 18.0,
  "label": "Outside the blue gate",   // optional, user-typed. NEVER reverse-geocoded (see §10).
  "expiresAt": 1753261200000, // live_start / map_key only
  "key": "<base64 32 bytes>", // live_start / live_rekey / map_key only — the shareKey
  "cadence": 15               // seconds; live_start / map_key
}
```

Decoding rule, added to `decodeEnvelope` on both platforms: if `content_type == "location"` **or** the
plaintext parses as JSON with `_vloc == 1`, it is a location envelope. The `_vloc` marker is what makes
this safe for the group/MLS path, where `content_type` is always `"group"`.

Rendering rule: `k` in `{pin, live_start, live_stop}` **renders a bubble**. `k` in
`{live_rekey, map_key, map_off}` is **silent control** — consumed by `LocationShareEngine` and never
appended to the message store.

### The bubble (identical layout in 1:1 and group; group adds the sender-name row above, as existing bubbles do)

- 220 × 140 pt/dp, `VoiidRadius.md` (12).
- A **locally rendered** map thumbnail centred on the coordinate at ~600 m span, POIs suppressed, with a
  `VoiidColor.accent` pin glyph at centre.
  - iOS: `MKMapSnapshotter`, off-main, cached in an `NSCache` keyed by (rounded coord, span).
  - Android: Maps Compose `GoogleMap(googleMapOptionsFactory = { GoogleMapOptions().liteMode(true) })`.
    Lite mode renders a static bitmap — correct and cheap inside a scrolling list.
- Footer strip: `label ?? "Location"`, plus "Accurate to ~250 m" when `acc > 100`.
- **Live variant**: same frame, plus a pulsing accent dot, "Live until 15:42" counting down, and — if it
  is yours — an inline **Stop** button. On `live_stop`/expiry it becomes the frozen final pin with
  "ended 14:32".
- Tap → full-screen `LocationDetailView`: the map, **Open in Maps** (`maps://` / `geo:` handoff), and
  Directions. No in-app routing.

**We never upload a rendered thumbnail as media.** That would be a second R2 blob and a second key for
zero benefit, and it would make the sender's device leak to Apple/Google on behalf of every viewer.
Each viewer renders locally. **Location creates no R2 objects at all** — which is why, unlike Stories,
this feature needs no reaper and no `deleteObject` helper.

### The map-tile leak, stated plainly

Rendering a map — thumbnail or full screen — sends the viewport to Apple or Google. Voiid's server stays
blind; the tile provider does not. Signal accepted exactly this tradeoff for its place-share feature.
We disclose it rather than imply privacy we don't have:

- A one-time in-app sheet the first time a user sends or opens a location message.
- **Settings → Privacy → Load map tiles** (default ON). OFF renders a coordinate card with an
  "Open in Maps" button and issues **zero** tile requests. Sending and receiving still work fully.

Self-hosted / offline vector tiles are out of scope for v1 (§10).

---

## 5. Battery and OS constraints

### Cadence — the decisive answer to "continuous or coarse"

| Mode | Cadence | Accuracy target | Background | Est. drain |
|---|---|---|---|---|
| **Static pin** | one fix, 10 s timeout | best available | no | negligible |
| **(A) Live share** | 10–15 s, 25 m distance filter | ~10 m | **yes** | ~4–8 %/h |
| **(B) Map presence** | significant-change / 5 min fg, 15 min bg, 100 m filter | ~10–100 m | **yes, coarse** | <1 %/h |

**The Map is coarse and last-known. A continuously-broadcasting map is not shipped.**

UPDATED: the Map now keeps delivering while backgrounded or killed, because the previous
foreground-only design had a failure worse than showing nothing — the pin FROZE wherever the
user last had Voiid open, telling their contacts they were somewhere they had left. It is
still the cheap ambient stream (significant-change on iOS, a 15-minute PendingIntent request
on Android), NOT the continuous mode, and the <1 %/h figure is unchanged.

Accuracy was ALSO tightened in the same pass: the distance filter went 250 m → 100 m and the
coordinate rounding 3 decimals (~110 m) → 4 (~11 m). At 250 m you could cross a campus without
the pin moving, and a ~110 m grid put two people standing together a block apart — more
imprecision than the privacy model asks for, since the real defence is the coarse cadence, the
audience gate and the encryption rather than blurring the coordinate past usefulness.
Ghost Mode and the kill switch tear down background delivery along with everything else, and
both platforms re-read visibility from disk on a cold wake so a kill cannot resurrect a
share the user ended.
It is the single largest battery and safety difference between (A) and (B), and it is deliberate: (A) is
a short, explicit, timer-bounded act; (B) is an ambient standing state, and an ambient state must be cheap
and imprecise.

### iOS

**`apps/ios/Voiid/Voiid/Info.plist`** — the *file*, not `INFOPLIST_KEY_*` build settings. That file
already exists precisely because Xcode's generated-plist mechanism silently drops `UIBackgroundModes`,
and it avoids editing two duplicated config blocks in `project.pbxproj`.

- `NSLocationWhenInUseUsageDescription` —
  *"Voiid uses your location only when you choose to share it in a chat or on the Map. Your location is
  end-to-end encrypted — Voiid's servers never see it."*
- `NSLocationAlwaysAndWhenInUseUsageDescription` — **required in addition** (iOS 11+ needs both strings
  present before Always can ever be requested) —
  *"Allow Always so live location keeps updating while Voiid is in the background, for as long as you
  set. Sharing stops automatically when your timer ends."*
- Append `location` to the **existing** `UIBackgroundModes` array (currently `voip`, `audio`,
  `remote-notification`).

Runtime:

- `allowsBackgroundLocationUpdates = true` — **the app traps without the background mode declared.**
- `showsBackgroundLocationIndicator = true` — we *want* the system blue pill. It is free privacy UX.
- `pausesLocationUpdatesAutomatically = false` while a share is active; `activityType = .other`.
- Live share: `desiredAccuracy = kCLLocationAccuracyNearestTenMeters`, `distanceFilter = 25`.
- Map presence: `startMonitoringSignificantLocationChanges()` (~500 m / ~5 min, essentially free — it
  rides the cell/wifi radio the OS already runs) plus one `requestLocation()` on foreground.
  **No `startUpdatingLocation` for the Map, ever.**

Authorization ladder:

1. `requestWhenInUseAuthorization()` at the moment of first share — in-context, not at onboarding.
2. Escalate to `requestAlwaysAuthorization()` **only** when the user picks a duration > 15 minutes.
   Denial is not fatal: the share runs foreground-only and the banner reads *"Live location pauses when
   you leave Voiid — allow Always to keep it running."*
3. `accuracyAuthorization == .reducedAccuracy` → the share still works, labelled **Approximate**
   throughout. Optionally declare `NSLocationTemporaryUsageDescriptionDictionary` with key
   `LiveLocationShare` and offer a temporary precise escalation once at share start.

**App Review justification** — this is where these features die. State in the review notes, and make sure
the code matches: sharing is **off by default**; every background session is started by an explicit user
action with an explicit end time; the system background indicator is enabled; a persistent in-app banner
is shown; sharing auto-terminates on a timer. Never start background location on launch, for analytics,
or for anything the user did not just tap.

### Android

Manifest additions:

```xml
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<!-- API 29+: only requestable AFTER foreground is granted, in a separate prompt. -->
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
<!-- API 34+: the FGS type must be permitted as well as declared. -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
```

```xml
<service android:name=".net.LocationForegroundService"
         android:foregroundServiceType="location"
         android:exported="false" />
```

Mirror `CallForegroundService` — its own comment already documents the trap that declaring a type in the
manifest is necessary but **not sufficient**, because the type is asserted at runtime and the process must
hold the matching permission. Notification: ongoing, non-dismissible, channel `location_share`, importance
LOW, with a **Stop sharing** action.

Runtime permission flow — **three steps, in this order. Android 11+ forbids requesting background in the
same prompt as foreground, and bolting this onto `PermissionsScreen`'s one-shot array silently fails:**

1. `RequestMultiplePermissions([ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION])` at the moment of first
   share — in-context, **not** in `PermissionsScreen`.
2. Only if step 1 granted **and** the user chose a duration > 15 min or enabled Map presence: show a
   rationale sheet explaining why, then `RequestPermission(ACCESS_BACKGROUND_LOCATION)`. On API 30+ the
   system routes this to app Settings ("Allow all the time") — **the sheet must say so, because the user
   leaves the app** and will otherwise think it is broken.
3. API 33+: `POST_NOTIFICATIONS` (already handled at onboarding) is required for the FGS notification to
   be visible.

Denials never crash. Foreground-only share, banner reads *"Live location pauses when Voiid is in the
background."*

Provider: **`play-services-location` / `FusedLocationProviderClient`**, not the platform
`LocationManager`. Justification: fused batches, fuses sensors, and coalesces requests across apps — it is
materially more battery-efficient, which is the entire point. The app already ships GMS
(`play-services-auth`, Firebase), and the dependency adds ~300 KB to a 140 MB APK.

- Live share: `Priority.PRIORITY_BALANCED_POWER_ACCURACY`, `setIntervalMillis(15_000)`,
  `setMinUpdateIntervalMillis(10_000)`, `setMinUpdateDistanceMeters(25f)`,
  `setWaitForAccurateLocation(false)`.
- Map presence: `PRIORITY_BALANCED_POWER_ACCURACY`, `setIntervalMillis(300_000)`,
  `setMinUpdateDistanceMeters(250f)`, **foreground only — no FGS for the Map in v1.**

Doze: an FGS is exempt while running; with no active share nothing runs. **Never** use `AlarmManager`
or `WorkManager` wakeups to poll location.

---

## 6. Data model

### What the server stores — and the honest admission

`database/migrations/018_location_shares.sql`:

```sql
create table if not exists location_shares (
  id              uuid primary key default gen_random_uuid(),
  owner_user_id   uuid not null references users(id) on delete cascade,
  kind            text not null check (kind in ('conversation','map')),
  conversation_id uuid references conversations(id) on delete cascade,  -- kind='conversation' only
  started_at      timestamptz not null default now(),
  expires_at      timestamptz not null,
  ended_at        timestamptz
);

create table if not exists location_share_targets (
  share_id       uuid not null references location_shares(id) on delete cascade,
  target_user_id uuid not null references users(id) on delete cascade,
  revoked_at     timestamptz,
  primary key (share_id, target_user_id)
);
```

Plus partial indexes on active shares by owner and by target.

**No coordinates. No key. No ciphertext. No update count. No last-seen timestamp.** That is the entire
server-side footprint of both features.

**Why store even this?** Two reasons, both load-bearing: (a) the WS process has **no database**, so
`POST /location/shares` is the only place conversation membership can be validated and abuse rate-limited;
(b) it lets a device that reinstalls or relinks discover "you still have an outbound share running —
stop it", rather than broadcasting silently forever.

**The honest metadata statement, which goes in the privacy policy and in the app's Map explainer:**

> Voiid's servers know that a share exists, who it is with, and when it ends. They never know where you
> are, whether you moved, or how often you updated.

If the product owner wants that reduced further, the only removable piece is `location_share_targets`,
at the cost of losing server-side membership validation and cross-device stop. **Recommendation: keep
it and disclose it.** The in-app line should be plain: *"Voiid's servers know that a share exists and
when it ends. They never know where you are."*

### What the clients store

Everything else. Local tables only.

**iOS** — GRDB migration `v2_location`, in a **new file** so the shared `VoiidDatabase.swift` edit is one
line: `enum LocationSchema { static func register(_ m: inout DatabaseMigrator) }`, called after the
`v1_core` closure and before `return m`. Migrations are append-only; registration order is execution
order; GRDB records applied identifiers so `v1_core` never replays.

**Android** — Room `version = 1 → 2` with an **explicit additive `Migration(1, 2)` plus
`.addMigrations(MIGRATION_1_2)`**. This is **mandatory, not optional**: `fallbackToDestructiveMigration()`
is currently active, so bumping the version without a Migration will not crash — it silently **drops and
recreates every table**, destroying `call_history` and the address-book `saved_name`/`phone_e164` columns
in `users`, which are **not** recoverable from ChatEngine's file store. The migration does only
`CREATE TABLE IF NOT EXISTS` + `CREATE INDEX` and touches no existing table. Keep the fallback (the
"a broken cache must never be worse than no cache" rationale still holds for a corrupt file) but **update
its comment** to state that every version bump from here on must ship a Migration, and that
`call_history` is no longer recoverable from elsewhere.

Tables (same shape both platforms; Android columns hold epoch **seconds**, models hold millis — the
existing `LocalStore` boundary convention, or timestamps will be off by 1000×):

- `location_shares` — `id, kind, direction ('out'|'in'), conversation_id, peer_user_id, started_at,
  expires_at, ended_at, cadence_seconds, state`.
- `location_share_targets` — `share_id, user_id, revoked_at` (outbound only).
- `location_last_fix` — `share_id, sender_user_id, lat, lon, acc, seq, fixed_at`. **Exactly one row per
  (share, sender), overwritten in place.** No history, no trail, ever.
- `map_audience` — `user_id, added_at` (the (B) allow-list).

**Share keys live in the platform secure store, never in SQLite** — iOS Keychain via the existing
`SharedStore`/`E2EManager` idiom, Android `SecurePrefs`. Deleted on stop, on expiry, and on rekey.

Static pins are messages and persist in the existing store as a `DecryptedMessage` with a new
`location: LocationRef?` field, exactly parallel to `media: MediaRef?`. **Do not put live fixes in that
store** — `ChatEngine.persist()` JSON-encodes and atomically rewrites the *entire* decrypted-message file
on every append, so a 10-second stream would give quadratic write amplification against the file that also
holds the user's whole chat history.

---

## 7. Map rendering

### iOS — MapKit

No dependency; `import MapKit` auto-links.

- Bubble thumbnail: `MKMapSnapshotter`, async, off-main, `NSCache`-backed. On failure → the coordinate-card
  fallback.
- Detail + Map tab: SwiftUI `Map(position:)` with `Annotation` per subject (iOS 17+). **The implementer
  must read `IPHONEOS_DEPLOYMENT_TARGET` from `project.pbxproj` and, if it is below 17, use
  `Map(coordinateRegion:annotationItems:)` instead. Do not hand-edit `project.pbxproj`.**
- `.mapStyle(.standard(pointsOfInterest: .excludingAll))` — calm and on-brand. The app is pinned
  `.preferredColorScheme(.light)`, so design for the light map only.

### Android — Google Maps

`gradle/libs.versions.toml`:

```toml
[versions]
playServicesMaps     = "19.0.0"
mapsCompose          = "6.4.1"
playServicesLocation = "21.3.0"

[libraries]
play-services-maps     = { group = "com.google.android.gms",  name = "play-services-maps",     version.ref = "playServicesMaps" }
play-services-location = { group = "com.google.android.gms",  name = "play-services-location", version.ref = "playServicesLocation" }
maps-compose           = { group = "com.google.maps.android", name = "maps-compose",           version.ref = "mapsCompose" }
```

`app/build.gradle.kts` — three `implementation(...)` lines, plus in `defaultConfig`:

```kotlin
// Maps API key is a BUILD-TIME secret supplied by the developer, never committed.
// Sources, in order: -PMAPS_API_KEY, local.properties, MAPS_API_KEY env var.
// An absent key is a supported state — the app must degrade visibly, not crash.
val mapsKey = (project.findProperty("MAPS_API_KEY") as String?)
    ?: System.getenv("MAPS_API_KEY").orEmpty()
manifestPlaceholders["MAPS_API_KEY"] = mapsKey
buildConfigField("boolean", "MAPS_CONFIGURED", mapsKey.isNotBlank().toString())
```

Manifest, inside `<application>`:

```xml
<meta-data android:name="com.google.android.geo.API_KEY" android:value="${MAPS_API_KEY}" />
```

### A missing Google Maps API key must degrade visibly — never crash, never grey out silently

With an empty key the Maps SDK renders a blank grey tile grid and logs an auth failure to logcat. That is
a silent, baffling failure and is unacceptable. So:

1. **Build-time gate.** If `BuildConfig.MAPS_CONFIGURED == false`, the app **never instantiates
   `GoogleMap`**. Every map surface renders `MapUnavailableCard`: a `VoiidColor.fieldFill` panel with a
   `VoiidColor.fieldBorder` border, a map-pin-slash icon, the headline *"Maps aren't set up in this
   build"*, and the sub-line *"Add MAPS_API_KEY to local.properties and rebuild — see docs/LOCATION.md."*
2. **Location sharing itself keeps working.** Pins send and receive, live shares run, positions decrypt —
   you get coordinates and an **Open in Maps** button (`Intent(ACTION_VIEW, Uri.parse("geo:<lat>,<lon>?q=..."))`
   handed to whatever map app is installed) instead of an inline map.
3. **Runtime gate for the more common real failure.** A key that *exists* but is restricted to the wrong
   package or SHA-1 also renders grey tiles. Register `setOnMapLoadedCallback` plus a 6-second watchdog;
   if the map never reports loaded, swap in the same card with *"Map failed to load — check the API key's
   restrictions."*
4. **Never invent, guess, or hardcode a key.** `local.properties` is gitignored; verify before shipping.
   The key must be restricted in Google Cloud to package `com.voiid.app`, to the release signing SHA-1
   **and the debug keystore SHA-1** (omit the latter and every developer sees grey tiles), and to the
   *Maps SDK for Android* + *Places API (New)* APIs only (see the next section for Places).

### Android: `kind` must be encoded explicitly on `POST /location/shares`

`ApiClient`'s `Json` uses `encodeDefaults = false` (the kotlinx default), which **omits any
property still sitting at its default value**. `MapPresenceService.CreateBody` declares
`kind: String = "map"`, so `kind` was silently dropped from the request body and every Map
"go visible" failed with `400 kind must be 'conversation' or 'map'`. The UI surfaced that as
*"Couldn't start sharing your location. Check your connection and try again."* — pointing the
user at their network while the real fault was serialization.

The field is annotated `@EncodeDefault`. **Any future request body that relies on a Kotlin
default value to carry a constant must do the same**, or it will not reach the server. iOS is
unaffected: `LocationAPI`/`MapShareAPI` pass `kind` explicitly and Swift's `Encodable` always
emits it.

### Accuracy is stated on every location surface

A marker drawn as a single point reads as an exact doorstep, and it is not. Every surface that
draws a position — chat bubble, full-screen detail, Map contact card — carries
*"Accurate to about N m — GPS is approximate"*, produced by ONE helper per platform
(`LocationAccuracy.note` on iOS, `accuracyNote` in `LocationDetailView.kt` on Android) so the
wording cannot drift.

`N` is the accuracy **the sender's device reported for that fix**, not a fixed marketing
figure, rounded so it reads as an estimate (never "37 m"). A payload carrying no accuracy falls
back to 30 m. Note the two features legitimately differ and the copy must not paper over it:
conversation live share (A) carries real device accuracy (typically 10–30 m), while Map
presence (B) coarsens accuracy to **≥100 m before transmission** (§5), so the Map honestly
reads "about 100 m". This is unrelated to the 5-decimal coordinate rounding (≈1 m), which is a
privacy measure far finer than the fix's own error.

### Place search — one Cloud Console step is required

The Map tab's place search (`MapPlaceSearch.kt`, `MapSearchBar`) uses the **Places SDK for Android**
(`com.google.android.libraries.places:places`) against the **same key** as Maps. It needs one console
change that cannot be made from the repo:

1. Enable **Places API (New)** on the project.
2. Add **Places API (New)** to that key's *API restrictions* list — a key restricted to "Maps SDK for
   Android" only will fail every Places call while the map itself keeps rendering, which looks like a
   code bug and is not one.

Until that is done the feature degrades quietly and deliberately: `MapPlaceSearch` catches the failure,
logs a hint to logcat, and returns **an empty suggestion list**, so the worst case is a search box that
finds nothing — never a crash or an error dialog over the map. With no key at all,
`BuildConfig.MAPS_CONFIGURED` is false and the search field is not composed in the first place.

**Billing.** Autocomplete is billed per *session*, not per keystroke, when a single
`AutocompleteSessionToken` spans predictions → fetch. `MapTabView` mints one token per search
interaction and mints a fresh one after each resolve; requests are additionally debounced 250 ms, and an
empty query issues no request at all. `FetchPlaceRequest` asks for `ID`, `NAME`, `LAT_LNG`, `ADDRESS`
only — more fields would move the call into a pricier SKU for data we do not render.

**iOS needs none of this**: it uses `MKLocalSearchCompleter`/`MKLocalSearch` (`MapSearchModel.swift`),
which requires no key, no billing and no backend proxy.

---

## 8. Privacy UX

### (A) Conversation live share

- The compose sheet names the audience explicitly above the duration picker:
  *"Everyone in **Design Team** (7 people) will see your live location for 1 hour."*
- While any share is active, a **persistent banner**: accent background, pulsing dot,
  *"Sharing live location · 42 min left · **Stop**"* — pinned below the header on `ChatsHomeView` **and**
  at the top of the relevant `ChatDetailView`. One tap on **Stop** ends it; with multiple shares it opens
  a compact list with **Stop all**.
- iOS: the system blue background-location indicator is on. Android: the ongoing FGS notification with a
  Stop action.
- A purely local notification at T−2 minutes: *"Live location ends in 2 minutes. Extend?"*
- **No push ever says where you are.** Live location adds **no** new `PushMeta` key and **no** new entry
  to `ALLOWED_PUSH_KEYS` — deliberately, because a `share_id` in a payload would tell APNs and FCM that a
  location share began. The durable `live_start` control message already rides the normal message path and
  gets the standard content-free wake push with `message_id`/`conversation_id`. That is enough.

### (B) The Map — the safety-critical surface

**Default: you appear to no one.** `map_visibility` defaults to `ghost`. **No server row exists until you
opt in.** First open of the Map tab is a full-screen explainer with exactly two buttons: **Browse only**
(default, dismisses) and **Choose who can see me** (opens the picker). There is **no** "share with
everyone" and **no** one-tap "share with all contacts". The picker starts **empty** and requires explicit
per-contact selection.

**Granularity: per-contact allow-list.** "Members of *Design Team*" exists as a convenience but **expands
to individuals at selection time and is stored as individuals** — so leaving the group never silently
keeps someone on your list. A block-list ("everyone except…") mode is **not** shipped, because its default
is "visible to everyone I haven't excluded", which is precisely the Snapchat failure mode.

*Constraint:* the audience picker offers only contacts you already have a 1:1 conversation with, because
the `map_key` control message needs a `conversation_id`. Starting a chat is a normal app action. This
keeps the backend surface at zero new message routes.

**Ghost Mode:**

- A single toggle at the top of the Map, mirrored in Settings → Privacy.
- Turning it **on** is instant and local-first: the client stops emitting, sends `loc_stop` over WS,
  sends a durable `map_off` control message to the audience, and `DELETE`s the share.
- Ghost is a **hard local gate — no location request is issued at all while it is on.** Not "we filter it
  server-side". The fix is never taken.
- Turning it **off** mints a **fresh `mapKey`** and redistributes it, so the ghosted period is
  cryptographically dark: anyone holding the old key sees nothing new.
- Timed ghost: *1 hour / until tomorrow / until I turn it off*. Tapping the toggle defaults to
  **until I turn it off**.

**Persistent, unmissable visible-indicator:**

1. The Map **tab icon carries a filled accent dot** whenever you are visible; a hollow ghost glyph when
   ghosted. Visible from every screen in the app.
2. A **persistent pill** at the top of the Map: *"Visible to 4 people"* on accent, tappable → the audience
   list. When ghosted: *"Ghost Mode — hidden from everyone"* on grey.
3. iOS: the Map uses significant-change in the background, which does NOT show the blue pill
   (that is for `startUpdatingLocation`). A pill during Map-only use still means something is wrong — if
   one appears, that is a bug.
4. Android: still **no** FGS and **no** ongoing notification for the Map. Background fixes arrive by
   PendingIntent broadcast, which needs neither — a permanent notification for an ambient state would be
   wrong. An FGS appearing for Map-only use still means something is misrouted —
   there is nothing to disclose while the app is closed. That is the honest version of the indicator.
5. A **weekly local reminder** if you have been continuously visible for 7 days: *"You've been visible on
   the Map to 4 people all week. Review?"* Purely local; the server is not involved.

**Offline vs stopped, on the Map:**

| State | Condition | Rendering |
|---|---|---|
| **Live** | fix < 15 min old | full-colour avatar bubble on the map |
| **Stale** | fix 15 min – 8 h old | desaturated avatar, clock badge, "Last seen 2 h ago", last known position retained |
| **Not sharing** | `map_off` arrived, or the share expired | **the cached fix is discarded**, the avatar leaves the map entirely and appears in a "Not sharing" list below it — **no last position shown at all** |
| **Aged out** | fix > 8 h old, no stop received | avatar leaves the map, moves to the list as "Last seen 9 h ago" |

The load-bearing distinction: an explicit stop **erases** the cached position; an age-out **keeps** it.
A recipient can therefore always tell "they turned it off" from "their phone is dead".

**No history, ever.** Voiid never draws a trail, never stores more than the single most recent fix per
contact, and wipes the local cache on ghost, on stop, and on cold start for anything older than 8 h.

**Symmetric by construction.** You see exactly the people who added you; they see exactly the people they
added. There is no hidden asymmetry to discover. There is deliberately **no** "who viewed your location"
feature — view receipts would need a receipt channel and would expose browsing behaviour.

### Kill switch

**Settings → Privacy → Stop all location sharing** — one destructive-red row that ends every outbound
share and turns Ghost Mode on. Also reachable by long-pressing the Map tab.

**Governance note:** `SettingsSheet.swift:17-27` carries an explicit design ruling that Maps has no rows
because "absent features get no pixels". Shipping this **requires revising that comment in the same
change** — otherwise the code contradicts itself.

---

## 9. API and file plan

### HTTP — `backend/api/src/routes/location.ts`

House style throughout: `Router` per file, `requireAuth` first, `asyncHandler` around every async body
(never bare `async (req,res)` — Express 4 does not catch async rejections and the client hangs),
`UUID_RE` declared once at module top, hand-rolled inline validation, flat `{ error: string }`, the
canonical `left_at is null` membership query copied from `calls.ts`, `query()` with parameterized SQL.

Mounted in `index.ts`: `api.use('/location', rateLimit({ max: 60, windowSeconds: 60, bucket: 'location' }), locationRoutes);`

Every handler calls `assertOpaque(req.body)` **and** `assertNoCoordinates(req.body)` first.

| Method | Path | Body / result |
|---|---|---|
| `POST` | `/v1/location/shares` | `{ kind, conversation_id?, target_user_ids[], duration_seconds }` → `201 { share_id, expires_at }` |
| `GET` | `/v1/location/shares` | → `{ outbound: [...], inbound: [...] }` — active, unexpired, unrevoked |
| `POST` | `/v1/location/shares/:id/extend` | `{ duration_seconds }` → `{ expires_at }` (owner only) |
| `DELETE` | `/v1/location/shares/:id` | → `{ ended: true }` (owner only) |
| `DELETE` | `/v1/location/shares/:id/targets/:user_id` | revoke one target (owner only) |
| `POST` | `/v1/location/shares/:id/leave` | a target stops seeing this share |

Validation on `POST /shares`: `duration_seconds ∈ {900, 3600, 28800}` for `kind='conversation'`,
`≤ 86400` for `kind='map'`; `kind='conversation'` requires a uuid `conversation_id` with the caller an
active member (403 otherwise) and every target an active member; `kind='map'` caps targets at 200.
Creating a share auto-ends any prior active share with the same `(owner, kind, conversation_id)`.
**The share key appears in neither the request nor the response.**

`DELETE /shares/:id` also publishes a `loc_stop` routing signal to each target's `channel:user:<id>` and
`hdel`s the last-fix buffer.

**No background worker is required.** `expires_at` is on the row and *every read path filters
`expires_at > now() and ended_at is null`*, so expiry is correct even with no reaper running. Rows are
tiny and bounded, and this feature creates **zero R2 objects**, so none of the Stories expiry machinery
(a worker process, a `deleteObject` helper, a bucket lifecycle rule) is needed. An opportunistic
`delete from location_shares where expires_at < now() - interval '7 days'` inside `GET /location/shares`
is sufficient housekeeping.

### WebSocket — `backend/websocket/src/index.ts`

New block in the existing `ws.on('message')` switch, placed after `typing` and before call signaling.
Follow the `typing` shape: the client supplies `recipient_ids` because the WS process has no database.
Rebuild the outbound frame from a **fixed list of known fields**, never echoing client extras, and stamp
`from_user_id` from the JWT.

- `loc_update` → relay + `hset(loc:last:<rid>, share_id, out)` + `expire(key, LOC_BUFFER_TTL=300)`.
- `loc_stop` → relay + `hdel(loc:last:<rid>, share_id)`.
- `flushPendingLocation(userId, ws)` on connect, alongside `flushPendingOffers`. Does **not** delete
  (unlike offers) — replaying an idempotent latest fix to a sibling device is harmless; the TTL reaps it.
- **Per-socket token bucket for `loc_update`: 12 frames per 60 s per share.** There is no WS rate
  limiting in the codebase today. Excess frames are dropped silently — a flooding stream is a bug or an
  attack, and dropping an ephemeral fix costs nothing.

**Stated gap:** the WS process has no DB and therefore **cannot** verify that `recipient_ids` are
authorized share targets — identical to `typing` and the call frames, which guarantee only sender
identity. Membership is enforced at `POST /location/shares`. A malicious client can relay `loc_update`
frames at arbitrary users, but gains nothing: the payload is encrypted under a key those users do not
hold, so it decrypts to garbage. **The receiving client MUST discard any `loc_update` whose `share_id` is
not in its local inbound-share table.** That client-side check is the actual authorization — exactly the
posture Signal takes for story delivery, where the server does no authorization at all.

### File plan — backend

- **NEW** `backend/api/src/routes/location.ts`
- **NEW** `database/migrations/018_location_shares.sql` (applied by `infrastructure/deployment/migrate.mjs` on push to `dev`)
- **NEW** `backend/api/test/location.test.ts` — asserts a body containing `latitude` is rejected
- **EDIT** `backend/api/src/index.ts` — two lines (import + `api.use('/location', …)`)
- **EDIT** `backend/websocket/src/index.ts` — the new frame block, `flushPendingLocation`, `LOC_BUFFER_TTL`
- **EDIT** `packages/common-utils/src/crypto.ts` — add `assertNoCoordinates`

### File plan — iOS

New `.swift` files under `apps/ios/Voiid/Voiid/` are auto-included. **Never hand-edit `project.pbxproj`
to add a source file.**

New:
- `Networking/LocationService.swift` — `CLLocationManager` wrapper, authorization ladder, cadence profiles
- `Networking/LocationShareEngine.swift` — share lifecycle, key mint + distribution, WS emit/receive, the live/stale/ended state machine
- `Networking/LocationAPI.swift` — the six endpoints
- `Models/LocationModels.swift` — `LocationEnvelope`, `LocationRef`, `LocationShare`, `LocationFix`, `ShareState`
- `Storage/LocationSchema.swift` — `enum LocationSchema { static func register(_ m: inout DatabaseMigrator) }`
- `Storage/LocationStore.swift` — `@MainActor enum`, raw SQL, the `LocalStore` idiom
- `Main/LocationPinBubble.swift`, `Main/LocationDetailView.swift`, `Main/LocationComposeSheet.swift`
  (mirror `PollComposeSheet.swift`), `Main/LocationBanner.swift`, `Main/MapTabView.swift`,
  `Main/MapAudienceSheet.swift`, `Main/Settings/LocationPrivacySettingsView.swift`
- `Assets.xcassets/TabMap.imageset` — template-rendering PNG, mirror `TabClips.imageset/Contents.json`

Edits (each tightly scoped):
- `Info.plist` — two `NSLocation*` keys, `location` appended to `UIBackgroundModes`
- `Storage/VoiidDatabase.swift` — **one line**: `LocationSchema.register(&m)` after the `v1_core` closure
- `Main/RootTabView.swift` — a 4th `Tab` case; convert the `Tab.asset` / `Tab.label` **chained ternaries
  (lines 17-18)** to switches, since they are hardcoded for exactly three cases; one more `tabItem(_:)`
  call. The `matchedGeometryEffect` pill generalises to N tabs for free.
- `Main/ChatsHomeView.swift` — mount `LocationBanner` between `tabs` (line 37) and the loadError banner
- `Main/ChatDetailView.swift` — attachment entry + render the `.location` bubble
- `Networking/ChatEngine.swift` — add `var location: LocationRef?` to `DecryptedMessage`; handle `_vloc`
  in `decodeEnvelope`. **Do not restructure this file.**
- `Networking/WebSocketClient.swift` — route `loc_update` / `loc_stop` to `LocationShareEngine`
- `Main/Settings/SettingsSheet.swift` — revise the lines 17-27 ruling, add the Privacy row

### File plan — Android

New:
- `net/LocationProvider.kt` — `FusedLocationProviderClient` wrapper + cadence profiles
- `net/LocationShareEngine.kt` — `object` singleton with its own `CoroutineScope(SupervisorJob() + Dispatchers.IO)`
- `net/LocationService.kt` — the six endpoints, `ApiClient` idiom with inline `@Serializable` DTOs
- `net/LocationForegroundService.kt` — `foregroundServiceType="location"`, Stop action (mirror `CallForegroundService.kt`)
- `net/LocationPermissions.kt` — the two-step foreground→background flow
- `model/LocationModels.kt`, `model/LocationStore.kt` (`AndroidViewModel`, Compose state, created in
  `VoiidRoot` and passed down as an explicit parameter)
- `store/LocationEntities.kt` — entities + `abstract class` DAO, snake_case `@ColumnInfo`, named indices,
  no foreign keys, epoch **seconds**
- `store/Migrations.kt` — `val MIGRATION_1_2: Migration` (the app's first migration; own file so future
  ones append)
- `main/LocationPinBubble.kt` (lite-mode `GoogleMap`), `main/LocationDetailView.kt`,
  `main/LocationSheets.kt` (`ModalBottomSheet`, mirror `ClipsSheets.kt`), `main/LocationBanner.kt`,
  `main/MapTabView.kt`, `main/MapAudienceSheet.kt`, `main/MapUnavailableCard.kt`

Edits:
- `AndroidManifest.xml` — four permissions, the FGS `<service>`, the `com.google.android.geo.API_KEY` meta-data
- `app/build.gradle.kts` — three deps, `manifestPlaceholders`, `buildConfigField MAPS_CONFIGURED`
- `gradle/libs.versions.toml` — three versions + three libraries
- `store/VoiidDatabase.kt` — `version = 2`, new entities, `.addMigrations(MIGRATION_1_2)`, **and update
  the `fallbackToDestructiveMigration` comment**
- `main/RootTabView.kt` — a 4th `Tab` entry, **and fix `val slot = maxWidth / 3` →
  `maxWidth / Tab.entries.size`**. The `Row` uses `Tab.entries.forEach { Modifier.weight(1f) }` and adapts
  by itself, so leaving the divisor at 3 is a **silent** pill-misalignment bug.
- `main/ChatDetailView.kt` — a "Location" `DropdownMenuItem` in the attachment menu (~lines 375-390) + bubble rendering
- `main/ChatsHomeView.kt` — mount `LocationBanner` between `Tabs(tab)` and `DraggableChatGrid`
- `model/Models.kt` — add `LOCATION` to `MessageKind`
- `model/Stores.kt` — handle `LOCATION` in `ChatStore.refresh()`'s kind-mapping `when`
- `net/ChatEngine.kt` — `LocationRef` in the envelope decode; widen nothing else
- `net/WebSocketClient.kt` — route `loc_update` / `loc_stop`
- `main/SettingsScreen.kt` — Privacy rows + kill switch

### Docs

- **NEW** `docs/LOCATION.md` (this file)
- **EDIT** `docs/DEPLOYMENT.md` — `MAPS_API_KEY` is a **build-time** secret (not a server env var); note
  explicitly that location needs **no** new worker process and **no** R2 lifecycle rule

### Collision warning

`ChatEngine.{swift,kt}`, `RootTabView.{swift,kt}`, `ChatsHomeView.{swift,kt}`, `ChatDetailView.{swift,kt}`,
`WebSocketClient.{swift,kt}`, `VoiidDatabase.{swift,kt}`, `SettingsSheet.swift`, `Models.kt`, `Stores.kt`,
`backend/api/src/index.ts` and `backend/websocket/src/index.ts` are **shared with the Stories
workstream**. Re-read each immediately before editing and keep to the named single-line insertions.
**If Stories also adds a tab, exactly one agent converts the `Tab.asset`/`Tab.label` ternaries and the
`maxWidth / 3` divisor — coordinate before touching them.**

---

## 10. Out of scope for v1

1. **Location history, trails, breadcrumbs.** Only the single most recent fix is ever stored.
2. Geofences, arrival/departure alerts, "notify me when X gets home".
3. **Reverse-geocoding a shared coordinate to a street address** — it would leak a *friend's* position to
   a geocoder. A location pin carries an optional **user-typed** label only, and we never resolve an
   address for one.
   *(Amended: forward **place search** on the Map tab IS now shipped — `MapSearchModel.swift` /
   `MapPlaceSearch.kt`. The distinction is load-bearing: a search sends the user's OWN typed query for a
   public place, never a contact's coordinate. §7 covers the Android key requirement.)*
4. Sharing to a non-contact, or link-based sharing.
5. Self-hosted or offline vector tiles (§4's third-party leak stands, disclosed and switchable).
6. Web / desktop clients.
7. Block-list ("everyone except") Map audience mode.
8. Location inside Stories.
9. View receipts / "who looked at your location".
10. In-app routing or ETA. We hand off to the system map app.
11. **Forward secrecy within a single live share** — impossible: `e2e-core` exposes no 32→32 KDF, so a
    key chain cannot be built. A fresh random key per share is what exists.
12. **Server-side verification that a WS `loc_update` recipient is an authorized target** — the WS process
    has no DB. Enforced client-side by dropping unknown `share_id`s.
13. Live location during calls / on the call screen.
14. Rendering altitude, speed, or heading (fields reserved in the envelope, not drawn).
15. Two of your own devices emitting for one share simultaneously — v1 allows one emitting device, and
    `POST /shares` auto-ends a prior share of the same kind.

---

## 11. Honesty ledger

Things this design does **not** give you, collected in one place so nobody ships UI that promises them:

- **No forward secrecy inside a share.** One key for the whole share. No exposed KDF; not fixable here.
- **The server learns share existence, audience, and duration.** Not coordinates, not movement, not update
  frequency — but it is real metadata and must be disclosed.
- **Map tiles leak the viewport to Apple / Google.** Voiid's server stays blind; the tile provider does
  not. Disclosed once in-app, with an off switch that falls back to coordinate cards.
- **WS relay authorization is client-side only.** The receiving client must drop unknown `share_id`s.
- **A recipient can screenshot or record a position.** Nothing prevents this, and no "revoke" wording may
  imply otherwise. Revocation stops *future* fixes; it cannot un-see a past one.
- **`encryptBackup`'s HKDF label is shared with account backups.** Share keys must come from
  `generateMasterSecret()` and must never be a backup master secret.
- **`live_stop` is best-effort; `expiresAt` is the guarantee.** A recipient who never receives the stop
  message still hides the share at the timer, offline, with no network at all. Every UI state must be
  derivable from `expiresAt` alone.
