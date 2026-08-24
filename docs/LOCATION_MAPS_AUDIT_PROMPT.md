# Prompt: Full Location & Maps Audit for Voiid (WhatsApp + Snapchat parity)

Copy everything below the line into a fresh AI coding agent session with this repo checked out.

---

## Role

You are a senior mobile + backend engineer specialising in **background location, geospatial data and live-location systems**. You have shipped location sharing at scale on iOS and Android. You know exactly how WhatsApp Live Location and Snap Map behave — including their failure modes — and you know what the OS actually permits when an app is backgrounded, suspended, or force-killed.

## Objective

Audit **every location and map feature** in the Voiid codebase and produce **one detailed markdown document**. This is a **documentation-only task**.

**Do not modify, create, refactor, or delete any source file.** The only file you write is the report. No code changes, no migrations, no config edits, no "small fixes along the way". If you find something catastrophic, write it in the report with a severity marker — do not fix it.

## Scope — where the code lives

Explore all of these; do not assume the list is complete, follow imports and call sites outward until you have the full graph.

**iOS** (`apps/ios/Voiid/Voiid/`)
- `Networking/LocationService.swift`
- `Networking/LocationShareEngine.swift`
- `Networking/MapPresenceEngine.swift`
- `Networking/MapLocationProvider.swift`
- `Storage/MapPresenceStore.swift`
- `Models/MapModels.swift`
- `Main/MapTabView.swift`, `Main/MapSearchModel.swift`, `Main/LocationDetailView.swift`, `Main/LocationComposeSheet.swift`, `Main/LocationPinBubble.swift`, `Main/ChatDetailView.swift`
- `Info.plist` / entitlements / background modes / capability declarations
- App delegate & scene lifecycle, push handling, any `BGTaskScheduler` registration

**Android** (`apps/android/app/src/main/`)
- `java/com/voiid/app/net/LocationProvider.kt`
- `java/com/voiid/app/net/MapLocationProvider.kt`
- `java/com/voiid/app/main/MapTabView.kt`, `LocationViews.kt`, `LocationSheets.kt`, `LocationDetailView.kt`
- `AndroidManifest.xml` — permissions, services, foreground service types, receivers
- `app/build.gradle.kts`, `gradle/libs.versions.toml` — Play Services Location / Maps versions, target SDK

**Backend**
- `backend/api/src/routes/location.ts`
- `backend/api/test/location.test.ts`
- `backend/api/src/push.ts`, `pushPayload.ts`, `index.ts` (route wiring, rate limits, auth middleware)
- `backend/websocket/src/index.ts` — realtime fanout of live location
- `backend/workers/src/retention.ts`, `erasure.ts` — location data lifecycle

**Data**
- `database/migrations/018_location_shares.sql` and the mirror in `supabase/migrations/`
- `019_privacy.sql`, `030_dpdp.sql`, `031_consent_notice.sql`, `032_erasure.sql`, `034_dpdp_requests.sql` — how they constrain location retention/consent
- RLS policies touching any location table

**Web / Admin** — `apps/web`, `apps/admin-web`: any map render or location display.

## What to determine for every feature

First, **enumerate the features you actually find** (do not assume this list — correct it). Likely set:
1. One-shot "send my current location" pin in chat
2. Live location sharing for a duration (WhatsApp-style)
3. Map tab / friend presence (Snap Map-style)
4. Place search & geocoding
5. Location detail view / place cards
6. Map rendering, tiles, clustering, camera behaviour

For each, document:

- **What it does today** — the actual call graph: UI → provider → engine → transport → API → DB → fanout → other client. Cite `file.ext:line`.
- **Accuracy & power configuration** — desired accuracy, distance filter, update interval, and whether it adapts to motion/battery/foreground state.
- **Permission model** — what is requested, when, with what rationale, and how each denial state (denied, reduced/coarse-only, when-in-use only, provisional/temporary, "Ask every time", background revoked later) is handled.
- **Lifecycle behaviour** — an explicit matrix. See below.
- **Server contract** — endpoints, payload shape, auth, rate limits, idempotency, clock skew handling, ordering guarantees.
- **Storage & privacy** — what is persisted, precision, retention, who can read it (RLS), erasure/DPDP compliance, whether stale rows leak position after a share ends.

## The lifecycle matrix (this is the core of the task)

For **each** of the six lifecycle states below, on **both** iOS and Android, state what currently happens, what *should* happen, and the exact mechanism required:

| State | Question to answer |
|---|---|
| Foreground, screen on | Update cadence, UI smoothness, battery cost |
| Foreground, screen off / device locked | Do updates continue? Should they? |
| Backgrounded (app switched away, still resident) | Does the share survive? What keeps it alive? |
| Suspended by OS (memory pressure, long background) | Recovery path when resumed; is the share silently dead while the recipient still sees a stale dot? |
| Force-killed by user (swipe from app switcher) | **Be honest and precise here.** iOS: significant-location-change / region monitoring relaunch, `UIApplicationLaunchOptionsLocationKey`, what is genuinely impossible after force-kill. Android: how Android 12+ treats swipe-kill vs Foreground Service, `START_STICKY`, why the app cannot simply respawn |
| Device reboot | iOS: SLC/region relaunch behaviour. Android: `BOOT_COMPLETED` receiver, and whether the OEM (Xiaomi/Oppo/Vivo/Samsung) will actually allow it |

Also cover: **Doze / App Standby buckets**, **Chinese-OEM aggressive task killers**, **iOS Low Power Mode**, **Background App Refresh disabled**, **network offline → queued updates and replay**, **airplane mode**, **GPS off while permission granted**, **mock-location / spoofing**, **timezone & clock skew**, **crossing from Wi-Fi to cellular mid-share**.

For every "should happen" cell, say **which OS mechanism** delivers it: iOS `allowsBackgroundLocationUpdates`, `pausesLocationUpdatesAutomatically`, `CLBackgroundActivitySession`, `startMonitoringSignificantLocationChanges`, region monitoring, `CLLocationUpdate.liveUpdates`, silent pushes as a heartbeat/wake, `BGProcessingTask`; Android Foreground Service with `location` type + notification, `FusedLocationProviderClient` vs `LocationManager`, `WorkManager` for retry, `PendingIntent` updates so the OS delivers to a killed process, battery-optimisation exemption prompts.

## Parity benchmarks

Two explicit gap analyses.

**WhatsApp Live Location parity** — timed sharing (15m/1h/8h), a persistent notification while sharing, the ability to stop from the notification, accurate arrival/ETA-free simple dots, sharing surviving background reliably, and a hard, trustworthy stop at expiry (recipients must never see a dot after expiry, even if the sender is offline — this must be enforced **server-side**, not by the client).

**Snap Map parity** — passive/ambient presence updates rather than continuous streaming, Ghost Mode, per-friend and audience-scoped visibility, last-seen decay ("updated 3h ago" and eventual disappearance), clustering at zoom-out, smooth marker interpolation rather than teleporting dots, battery cost low enough to run all day.

For each benchmark, produce a table: **Capability | Voiid today | WhatsApp/Snap | Gap | Severity**.

## Also assess

- **Battery** — estimate current drain per scenario; identify every place that requests more accuracy or frequency than needed.
- **Network efficiency** — payload size, batching, compression, whether every fix triggers a request.
- **Correctness** — coordinate precision and rounding, altitude/heading/speed handling, horizontal-accuracy filtering, stale-fix rejection, jitter smoothing/Kalman, geodesic vs planar distance, antimeridian and polar edge cases, PostGIS vs naive lat/lng math in SQL.
- **Realtime fanout** — websocket reconnect and backfill, delivery to a recipient whose app is killed, push fallback, and ordering.
- **Security & abuse** — can a user share another user's location, forge coordinates, or read shares they were never granted? Enumerate RLS gaps and IDOR risks.
- **Privacy compliance** — consent capture, DPDP alignment, retention windows, erasure of location history, precision reduction for coarse-permission users.
- **Testing** — what exists (`backend/api/test/location.test.ts`), and what is missing: simulated routes, permission-state matrices, background/kill scenarios, clock skew, offline replay.
- **Observability** — is there any way to tell, today, that a user's live share silently died? Propose the metrics and logs needed.

## Output

Write exactly one file: `docs/LOCATION_MAPS_AUDIT.md`.

Structure it as:

1. **Executive summary** — 10–15 lines: current maturity level, and the three things that most break parity.
2. **Feature inventory** — table of every location/map feature with file references and a one-line state assessment.
3. **Per-feature deep dives** — one section each, following the "what to determine" list above.
4. **The lifecycle matrix** — the full grid, iOS and Android, with mechanisms.
5. **Parity gap analysis** — the WhatsApp and Snapchat tables.
6. **Findings register** — every issue as `[SEV-1..4] Title` with: evidence (`file:line`), why it matters, user-visible symptom, and the fix. Sort by severity. SEV-1 = user-visible breakage or privacy/security hole; SEV-4 = polish.
7. **Three-tier remediation roadmap:**
   - **Make it work** — correctness and reliability bugs; the minimum for a location feature that does not lie to the user.
   - **Make it good** — WhatsApp parity: reliable background, server-enforced expiry, sane battery.
   - **Make it best** — Snap-tier: ambient presence, Ghost Mode, clustering, interpolation, adaptive cadence, full observability.
   Each item gets: effort estimate, files touched, dependencies, and risk.
8. **Open questions** — anything you could not determine from the code, and what you would need to resolve it.

## Rules

- Every claim about existing behaviour must cite `file:line`. If you did not read it, do not assert it.
- Distinguish **verified** (read the code) from **inferred** (looks likely) from **unknown**. Mark inferences explicitly.
- Do not soften findings. If live location silently dies on background, say so plainly.
- Do not propose vague fixes. "Add retry" is useless; "wrap the POST in WorkManager with exponential backoff, `file:line`" is useful.
- Be honest about OS limits. Do not promise behaviour after force-kill that the platform does not permit.
- Prefer depth over breadth in prose, but do not skip a feature because it is small.
