# Voiid Clips — Build Plan (grid feed, real upload, Moments rename)

Status: **BUILT** (2026-07-29). Phases 1–7 are implemented on both platforms and the backend.
Both apps compile; the backend typechecks. See §9 for exactly what is and is not verified —
**the migration has not been run and no endpoint has been exercised against a live database.**

Scope of this doc: turn Clips from a dummy-data mock into a real feature, redesign the feed as an
Instagram-style grid, replace the upload popup with a full page + camera/gallery picker + native
editor, add empty states and a video loader, and rename the user-facing "Stories" surface to
**Moments**.

Precedents to read first: [`STORIES_PROTOCOL.md`](./STORIES_PROTOCOL.md) (media upload + fan-out
pattern this reuses), [`API_CONTRACT.md`](./API_CONTRACT.md), [`ANDROID_IOS_PARITY.md`](./ANDROID_IOS_PARITY.md).

---

## 0. What exists today (the honest starting point)

Clips is a **UI shell over hardcoded arrays**. There is no backend, no database, no upload, no
persistence. Nothing in the current Clips code path talks to a server.

| Piece | Today | Files |
| --- | --- | --- |
| Feed | Vertical `LazyVStack` / `LazyColumn` of cards, gradient placeholder instead of video | [ClipsFeedView.swift](apps/ios/Voiid/Voiid/Main/ClipsFeedView.swift), [ClipsFeedView.kt](apps/android/app/src/main/java/com/voiid/app/main/ClipsFeedView.kt) |
| Player | Fullscreen "reel" that is a gradient + play icon; no `AVPlayer`/`ExoPlayer` anywhere | [ClipFullscreenView.swift](apps/ios/Voiid/Voiid/Main/ClipFullscreenView.swift), [ClipFullscreenView.kt](apps/android/app/src/main/java/com/voiid/app/main/ClipFullscreenView.kt) |
| Upload | A 47-line sheet: pick video, type title, tap Share → **`dismiss()`**. The file is discarded. | [NewClipView.swift](apps/ios/Voiid/Voiid/Main/NewClipView.swift), [ClipsSheets.kt](apps/android/app/src/main/java/com/voiid/app/main/ClipsSheets.kt) |
| Likes | `ClipsStore.toggleLike` mutates an in-memory `@Published` array; lost on relaunch | [Stores.swift:890](apps/ios/Voiid/Voiid/Models/Stores.swift#L890) |
| Comments | `DummyData.clipComments`; `addComment` prepends locally | same |
| Backend | **None.** No `backend/api/src/routes/clips.ts`, no `clips` table, no R2 prefix | — |

So "wire the clips accordingly to the new UI" is not a UI-rewiring job. It is **building the Clips
feature**, and the UI work sits on top of that. This doc sequences it so the visible parts (grid,
empty states, loader, upload page) can land against a real backend rather than being rebuilt twice.

### The one architectural decision to make first

Stories/Moments are **end-to-end encrypted** — the server stores ciphertext only, keyed per recipient
device. Clips as designed (a public-ish grid, view counts, likes, comments from anyone) is a
**broadcast** surface: there is no fixed recipient set to encrypt to, and view/like counts require the
server to attribute activity.

**Recommendation: Clips are NOT E2EE.** They are public/followers-visible content, stored as plaintext
media in R2, exactly like a normal social video feed. This must be stated explicitly in the code and in
the privacy copy so nobody mistakes it for a weakening of the messaging guarantee — same way
[`GAMES.md`](./GAMES.md) carves out game state. If you instead want Clips to be contacts-only and
encrypted, say so before implementation starts: it changes the schema, kills server-side view counts,
and makes the grid thumbnails per-device-decrypted (much slower first paint).

Everything below assumes the non-E2EE broadcast model.

---

## 1. Backend — new, does not exist yet

### 1.1 Database: `database/migrations/022_clips.sql`

(`020` is the next free number — `019_privacy.sql` is current head. If Games lands first, this becomes `021`.)

```
clips
  id              uuid pk        -- client-supplied, like stories/calls
  author_id       uuid fk users(id) on delete cascade
  r2_key          text           -- media/clips/<uid>/<uuid>.mp4  (PLAINTEXT, see §0)
  thumb_r2_key    text           -- media/clips/<uid>/<uuid>.jpg  — the grid renders THIS, never the video
  caption         text
  duration_ms     int
  width, height   int            -- drives grid aspect + player letterboxing without a probe
  byte_size       bigint
  view_count      int  default 0 -- denormalised counter, incremented by the view endpoint
  like_count      int  default 0 -- denormalised; source of truth is clip_likes
  comment_count   int  default 0
  status          text           -- 'uploading' | 'ready' | 'failed'  (see §1.3)
  created_at      timestamptz
  deleted_at      timestamptz    -- soft delete; the reaper clears R2 objects

clip_likes        (clip_id, user_id) pk, created_at   -- presence of row = liked
clip_comments     id, clip_id, author_id, text, created_at, deleted_at
clip_views        (clip_id, user_id) pk, viewed_at    -- dedupes view_count per user
```

Indexes: `clips (created_at desc) where deleted_at is null and status='ready'` for the feed;
`clips (author_id, created_at desc)` for a profile grid; `clip_comments (clip_id, created_at)`.

**Why denormalised counters:** the grid shows a view count on every tile (per the reference design).
Counting `clip_views` rows per tile on every feed page would be the feed's dominant cost. The counter
column is the read path; the row table is the dedupe/audit path.

### 1.2 Routes: `backend/api/src/routes/clips.ts`

Model it on [`stories.ts`](backend/api/src/routes/stories.ts) — same `requireAuth` + `asyncHandler`
shape, same presign approach via [`r2.ts`](backend/api/src/r2.ts) (`presignPut` / `presignGet`).

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/clips/presign-upload` | Returns presigned PUT URLs for **both** video and thumbnail + the `r2_key`s |
| `POST` | `/clips` | Create the row after the PUTs succeed (`status: 'ready'`) |
| `GET` | `/clips/feed?cursor=&limit=` | Keyset-paginated feed; returns rows + presigned GET URLs for thumbs |
| `GET` | `/clips/:id/playback` | Presigned GET for the video (short TTL, minted on demand — not in the feed payload) |
| `GET` | `/clips/mine` | The author's own grid |
| `POST` | `/clips/:id/view` | Idempotent; inserts `clip_views` on conflict do nothing, bumps counter |
| `POST` / `DELETE` | `/clips/:id/like` | Toggle; returns the authoritative new count |
| `GET` | `/clips/:id/comments` | Paginated |
| `POST` | `/clips/:id/comments` | Add |
| `DELETE` | `/clips/:id` and `/clips/:id/comments/:cid` | Soft delete, author-only |

**Pagination must be keyset (cursor on `created_at,id`), not `OFFSET`.** An infinite grid with offset
paging duplicates and skips tiles whenever someone posts mid-scroll.

**Why playback URLs are a separate call:** a 30-tile feed page would otherwise mint 30 presigned video
URLs that mostly go unused and expire before the user taps. Feed carries thumbs only; the video URL is
minted when a clip is opened.

### 1.3 Upload lifecycle

The `status` column exists because a client can die between "PUT to R2" and "POST /clips". Sequence:

1. Client calls `presign-upload` → server returns keys + URLs (no DB row yet).
2. Client PUTs video, then thumbnail, directly to R2 (progress UI reads from this).
3. Client `POST /clips` → row created `status='ready'`.

Orphaned R2 objects with no row are swept by a worker mirroring
[`reapStories.ts`](backend/workers/src/reapStories.ts), plus an R2 lifecycle rule on `media/clips/` as
the net. Do not create the row up front in `uploading` state — a client that never finishes then leaves
a permanently broken tile in everyone's feed.

### 1.4 Caps

Enforce **client-side before upload and server-side on create** (the story composer's caps are the
precedent and the comments there explain why): video ≤ 90 s, ≤ 720p, H.264/AAC MP4, ≤ 100 MB;
thumbnail JPEG ≤ 300 KB. Reject at both ends — a client-only cap is not a cap.

---

## 2. Clips feed → Instagram-style grid

Replaces the current vertical card list on both platforms. This is the reference design in the
screenshot: a dense 3-column grid, near-zero gutters, view count bottom-left on each tile.

### 2.1 Layout

- **3 columns**, `2dp`/`2pt` spacing, edge-to-edge (no horizontal page padding).
- Tile aspect **9:16** (the reference is a portrait-video grid). Tiles are uniform — do **not** use a
  staggered/Pinterest grid; the reference design's occasional tall tile comes from a separate
  "featured" rule that is not worth the complexity in v1.
- Each tile: thumbnail image, a subtle bottom gradient scrim, an eye glyph + formatted count
  (`4.7M`, `732K`, `1.2M` — a compact formatter, not `%,d`; both platforms need the same rounding
  rules, so put it in one shared helper per platform and unit-test the boundaries).
- Tap → the existing fullscreen player, opened **at that index** with the rest of the loaded page as a
  vertically-swipeable pager (this is what makes a grid feel like Instagram rather than a gallery).

iOS: `LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3))` inside the
existing `ScrollView`. Android: `LazyVerticalGrid(GridCells.Fixed(3))`.

### 2.2 Thumbnail loading

Grid tiles must not each fire an unbounded network request. Reuse the app's existing image-cache
approach ([AvatarCache.swift](apps/ios/Voiid/Voiid/Networking/AvatarCache.swift) is the in-repo
precedent) or add a small disk+memory cache keyed by `thumb_r2_key`. Tiles show a shimmer placeholder
(§4) until the thumb resolves, never a blank or a layout jump.

### 2.3 Header

Keep the current header shape but the `+` opens the new full-page composer (§5), not a sheet. The
decorative `video.fill` / `Videocam` icon next to it does nothing today — either wire it to "My clips"
or drop it.

---

## 3. Wiring likes, comments, views, playback

### 3.1 Replace the dummy store

`ClipsStore` on both platforms becomes a real engine, sitting alongside
[`StoryEngine.swift`](apps/ios/Voiid/Voiid/Networking/StoryEngine.swift) as the shape to copy: a
`ClipsService` (thin HTTP over `APIClient`) plus a `ClipsEngine` (paging, cache, optimistic state).
`DummyData.clips` and `DummyData.clipComments` are deleted, not left as a fallback.

### 3.2 Optimistic-but-reconciled interactions

Like/comment must feel instant but never lie:

- **Like:** flip the icon and adjust the count locally on tap, fire `POST/DELETE /clips/:id/like`,
  then **overwrite the local count with the server's authoritative count** from the response. On
  failure, revert and surface a quiet inline error. Debounce rapid double-taps to one in-flight request
  per clip.
- **Comment:** insert with a `pending` flag, replace with the server row on success, mark `failed` +
  offer retry on error. Do not silently drop — the repo already has a commit fixing exactly this class
  of bug for stories (`fix(stories): close the remaining five silent-drop paths`); don't reintroduce it
  here.
- **View:** fire once per clip per session after a **≥2 s** watch, not on tile appearance. Counting
  scroll-past impressions as views inflates the number the grid is built around.

### 3.3 Real video playback

Today's player has no video component at all. Add `AVPlayer` (iOS) / ExoPlayer–Media3 (Android) with:

- Vertical pager over the loaded page; **preload the next 1–2 items** and release players outside a
  ±1 window (an unbounded pager of live players is the standard way this feature OOMs).
- Loop, muted-by-default with a tap-to-unmute affordance, pause on background/scroll-away.
- Failure state: "Couldn't load this clip" with retry — mirroring the story viewer's existing copy.

---

## 4. Loading and empty states

### 4.1 Video loader (animated)

While the player buffers, show a branded loader over the clip's own **blurred thumbnail** (so the
frame is never black): a circular indeterminate progress ring in `VoiidColor.primary`, with a soft
pulse. On slow connections (>3 s), reveal a "Still loading…" subtitle. Both platforms share the
timings; the ring is drawn with the existing design tokens, not a stock spinner.

### 4.2 Grid skeleton

First load and page-append show shimmer tiles in the real grid geometry (3 columns, 9:16, same
spacing) so the layout does not reflow when content lands. A shimmer sweep over `VoiidColor.fieldFill`
— the same gradient direction and ~1.2 s period on both platforms.

### 4.3 Empty states

Three distinct states, styled with current design tokens (`VoiidColor.surfaceCard`, `VoiidFont`,
`VoiidRadius`), each centered with icon + title + subtitle + optional action:

| State | Title | Subtitle | Action |
| --- | --- | --- | --- |
| No clips at all | "No clips yet" | "Be the first to post one." | **Create clip** → composer |
| No clips from your people | "Nothing here yet" | "Clips from people you follow will show up here." | Browse / Create |
| Your own grid empty | "You haven't posted a clip" | "Your clips will appear here." | **Create clip** |
| Load failed | "Couldn't load clips" | "Check your connection and try again." | **Retry** |

The failure state is deliberately **not** the empty state — showing "No clips yet" when the request
actually errored is the single most common bug in this pattern.

---

## 5. Upload: a full page, not a popup

Replaces `NewClipView` (iOS sheet) and the Android bottom sheet with a **pushed full-screen flow**.
Four steps, each a real screen with a back stack:

```
[1] Source picker  →  [2] Capture / Pick  →  [3] Edit  →  [4] Details & Post
```

### 5.1 Step 1 — Source picker

A full-page screen (not an action sheet) with two large tappable cards:

- **Camera** — record in-app.
- **Gallery** — pick an existing video.

Plus a recent-videos strip along the bottom for one-tap selection, so the common case skips a step.
Permission denial gets an inline explainer + "Open Settings", never a dead end.

### 5.2 Step 2 — Capture / Pick

- **Camera:** reuse the pattern in [StoryCameraView.swift](apps/ios/Voiid/Voiid/Main/Stories/StoryCameraView.swift)
  / `StoryCameraView.kt` — press-and-hold record, front/back flip, flash, and a duration ring capped at
  the §1.4 limit. This code is already written for stories; extract the shared parts rather than
  forking it.
- **Gallery:** `PhotosPicker` (iOS) / Photo Picker (Android) filtered to videos.

### 5.3 Step 3 — Edit ("all the filters available inside the phone")

Worth being precise here, because the two platforms differ and the requirement as written isn't
literally achievable the same way on both:

- **iOS:** there is no public API to enumerate and apply the system Photos filters. The correct
  equivalent is **Core Image** — `CIFilter` built-ins (`CIPhotoEffect*` = the same Vivid/Dramatic/
  Mono/Noir set the Photos app exposes, plus exposure/contrast/saturation/temperature adjustments)
  applied to the video via `AVVideoComposition(asset:applyingCIFiltersWithHandler:)`. That gives a
  real-time filmstrip of live-previewed filter thumbnails and renders on export. Optionally, `UIImagePickerController`'s
  built-in trim UI can cover trimming for free.
- **Android:** the equivalent is **Media3 Transformer + `Effect`s** (`RgbFilter`, `RgbAdjustment`,
  LUT-based `SingleColorLut`) — same filter list defined once as data (name + LUT/param set) so both
  platforms present an identical row of filters.

Editor surface (both platforms): trim handles with scrubber, a horizontal filter strip with live
thumbnails, cover-frame picker (this becomes `thumb_r2_key`), mute toggle. Everything renders on
export via one shared "apply edit list to source → output MP4" function; the UI only ever produces an
edit description, never a re-encoded intermediate per tweak.

If a same-day scope cut is needed, ship **trim + cover-frame + a fixed set of ~8 filters** and add
adjustment sliders later. Don't ship the editor with no cover-frame picker — the grid is thumbnails,
so the cover frame is the highest-leverage control in the whole flow.

### 5.4 Step 4 — Details & Post

Caption field, audience/visibility row, and **Post**. Posting is **optimistic**: the screen dismisses
immediately, and the upload runs in the background with a progress indicator on the new grid tile
(the story composer's "Share dismisses immediately and never blocks on a 50 MB upload" comment states
the reasoning; same applies at 100 MB). Failure surfaces a retry on the tile, not a lost video.

---

## 6. Stories → Moments rename

**This has two very different scopes and only one of them is safe to do broadly.**

Measured footprint: **250 occurrences across 22 iOS files, 327 across 24 Android files**, plus backend
routes, `database/migrations/017_stories.sql`, R2 prefixes, WebSocket frame types (`story`,
`story_receipt`, `story_deleted`), message `content_type: "story_reply"`, and `UserDefaults` keys
(`voiid.stories.*`).

### 6.1 Rename (user-facing only) — do this

Every string a user can read:

- Tab label `"Stories"` → `"Moments"` — [RootTabView.swift:91](apps/ios/Voiid/Voiid/Main/RootTabView.swift#L91), [RootTabView.kt:102](apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt#L102)
- `"Stories"` nav title, `"New Story"` → `"New Moment"`, `"Your story"` → `"Your moment"`,
  `"Add to your story"` → `"Add to your moment"`, `"No stories yet"` → `"No moments yet"`,
  `"This story couldn't be loaded"`, `"This story is no longer available"`,
  `"Stories can be up to 30 seconds"`, the privacy section header `"Stories"`, `"Story view receipts"`,
  and both view-receipt explainer paragraphs.
- Push-notification copy in [pushPayload.ts](backend/api/src/pushPayload.ts).

Grammar note: "moment" is countable the same way "story" is, so the plural/singular switches
(`"1 story" / "N stories"` in `StoriesHomeView.kt:80`) map cleanly — but check each one, don't
sed-replace, or you get "1 moment · 2 moments" strings with the wrong article elsewhere.

### 6.2 Do NOT rename (identifiers and wire values) — deliberately

Leave as `story`/`stories`:

- **WebSocket frame types** and **`content_type: "story_reply"`** — these are on-the-wire values. An
  older client that hasn't updated stops recognising the frame, and story replies stop rendering as
  replies. Renaming a wire value is a protocol migration, not a rename.
- **REST paths** (`/stories/*`), **DB tables/columns**, **R2 key prefix `media/stories/`** — existing
  rows and objects keep the old prefix regardless, so a rename just splits your data across two names.
- **`UserDefaults`/`SharedPreferences` keys** (`voiid.stories.sendViewReceipts`, etc.) — renaming these
  silently resets every user's privacy preference to the default. For a **view-receipts** toggle that
  is a privacy regression, not a cosmetic one.

### 6.3 Optional, separate PR: internal symbol rename

Swift/Kotlin type and file names (`StoryEngine`, `StoriesHomeView`, `VStory`, …) *can* be renamed to
`Moment*` for internal consistency. It touches ~46 files across both platforms and conflicts with
anything in flight. **Do it as its own mechanical PR, after §6.1 ships and is verified** — never mixed
into the same commit as the user-facing copy change, or a copy-change bug becomes unreviewable inside
a 500-line rename diff.

---

## 7. Suggested sequencing

Each phase is independently shippable and leaves the app working.

| # | Phase | Notes |
| --- | --- | --- |
| 1 | **Moments rename (user-facing)** §6.1 | Zero-risk, no backend, ships immediately |
| 2 | **Backend: migration + routes** §1 | Nothing user-visible; unblocks everything else |
| 3 | **Grid feed + skeleton + empty states** §2, §4.2, §4.3 | Against the real feed endpoint |
| 4 | **Real playback + loader** §3.3, §4.1 | First point the app plays actual video |
| 5 | **Likes / comments / views wiring** §3.1, §3.2 | Deletes `DummyData.clips` |
| 6 | **Upload flow: pages 1, 2, 4** §5.1, §5.2, §5.4 | Posting works end-to-end, no editor yet |
| 7 | **Editor** §5.3 | The largest single piece; trim + cover + filters |
| 8 | **Internal symbol rename** §6.3 | Mechanical, do last |

---

## 8.4 Renditions & cover source (added after the first build)

### Three renditions, produced on-device

Migration `023_clips_renditions.sql` adds `r2_key_sd` / `_hd` / `_fhd` (+ per-rendition sizes) and
`cover_source`. All are **nullable**: the exporter never upscales, so a 720p source simply produces
no 1080p rung, and `r2_key` remains the always-present baseline every playback falls back to.

| Rung | Long edge | Target bitrate |
| --- | --- | --- |
| `sd` | 854 | 1.2 Mbps |
| `hd` | 1280 | 2.8 Mbps |
| `fhd` | 1920 | 4.5 Mbps |

Bitrates are set so a 90 s clip stays well inside the 100 MB cap (90 s @ 4.5 Mbps ≈ 50 MB).

**Why on-device and not server-side:** a transcode worker would mean a new service, a job queue, and
a `processing` state in the feed. The phone already has a hardware encoder and the app already has
presign+PUT, so three renditions cost zero new infrastructure. The trade is a slower export and ~3x
upload bytes on the author's connection — paid once by the poster instead of repeatedly by viewers.

**Why not HLS/DASH:** true adaptive streaming needs the source segmented plus a manifest, which in
practice means handing transcoding to a service (Cloudflare Stream). Quality here is chosen **once
per playback**, not switched mid-stream.

Encoding is **sequential, not concurrent** — three simultaneous hardware encodes contend for the
same VideoToolbox/MediaCodec resources and fail outright on older devices.

**Selection at playback** (`ClipQuality.preferred` / `ClipNetworkMonitor`): Low Data Mode or a
metered connection is a **hard floor at `sd`** — the user pays per byte, and quietly streaming 1080p
over that is a bug they cannot see but are billed for. Otherwise wifi → `fhd`, cellular-unmetered →
`hd`. `GET /clips/:id/playback?quality=` walks *down* the ladder from the request and reports which
rung it actually served, so a client never assumes it got what it asked for.

**Upload is tiered by importance:** cover first (tiny — a later failure still leaves a real tile),
then the baseline (required), then renditions **best-effort** (a failed rung is dropped from the row
rather than failing the whole post).

### Cover image: video frame or a separate upload

The composer now offers both. An uploaded image **wins** over the frame scrubber, and the scrubber
is hidden while one is set — two controls that disagree about the tile would be a bug the author
cannot diagnose. Clearing the upload returns to frame mode.

Uploaded covers are re-encoded to ≤1080px JPEG q0.8: an 8 MB HEIC straight from the camera roll
would be a ~200x heavier grid tile than the frames beside it. They are deliberately **not** filtered
— the filter applies to the video, and silently tinting a photo the author picked would be a
surprise they cannot undo.

`cover_source` (`'frame'` | `'upload'`) is reported to the server so the editor can restore state.

---

## 8.5 What shipped — file map

| Layer | Files |
| --- | --- |
| DB | `database/migrations/022_clips.sql` (+ mirrored into `supabase/migrations/`) |
| API | `backend/api/src/routes/clips.ts`, mounted in `index.ts` at `/clips` (rate-limited 240/min) |
| iOS transport/state | `Networking/ClipService.swift`, `Networking/ClipsEngine.swift` |
| iOS UI | `Main/Clips/ClipsFeedView.swift`, `ClipFullscreenView.swift`, `ClipComposerFlow.swift`, `ClipEditor.swift`, `ClipsUIKit.swift` |
| Android transport/state | `net/ClipService.kt`, `model/ClipsStore.kt` |
| Android UI | `main/clips/ClipsFeedView.kt`, `ClipFullscreenView.kt`, `ClipComposerFlow.kt`, `ClipEditor.kt`, `ClipsUIKit.kt` |
| Deleted (dummy) | iOS `Main/ClipsFeedView/ClipFullscreenView/NewClipView.swift`, `VClip`/`VClipComment`/`ClipsStore`/`DummyData.clips`; Android equivalents incl. `ClipsSheets.kt` |

New Android dependency: **Media3 1.4.1** (`exoplayer`, `ui`, `transformer`, `effect`, `common`) —
the app previously had no video player at all.

### Deviations from the plan above

- **Android camera:** the existing in-app CameraX stack (`StoryCameraView.kt`) binds `ImageCapture`
  only — it is photo-only and cannot record video. Rather than grow a second capture stack, the
  composer uses the system `CaptureVideo` intent. iOS reuses `StoryCameraView` as planned.
- **Filters:** shipped as 10 entries in the same order on both platforms. iOS uses the real
  `CIPhotoEffect*` chain; Android approximates the same looks with Media3 `RgbFilter` /
  luminance-preserving saturation `RgbMatrix` (there is no LUT asset pipeline yet). Vivid/Dramatic
  vs. Chrome/Noir currently share underlying transforms on iOS — worth distinct LUTs later.
- **Sound:** clips start muted with tap-to-unmute, per the spec.

---

## 9. Verification status — read before deploying

**Verified:**
- iOS `BUILD SUCCEEDED` (iPhone 16 Pro sim, Debug); app installs and launches.
- Android `BUILD SUCCESSFUL` for both `compileDebugKotlin` and `assembleDebug`.
- Backend `tsc --noEmit` clean.
- (Re-verified after the renditions + cover-picker work.)

**NOT verified — these still need doing:**
1. **`022_clips.sql` has never been executed.** No Postgres was available in this environment
   (no `psql`, no Docker). The SQL is unrun; syntax and constraint behaviour are unconfirmed.
2. **No endpoint has been called.** Every route is untested against a live DB — the keyset
   pagination, the `on conflict do nothing … returning` idempotency in `/view` and `/like`, and the
   counter arithmetic are all reasoned-through but unexercised.
3. **Neither app's Clips UI has been seen running.** iOS gates behind phone-OTP onboarding, which
   cannot be completed in the simulator; the connected Android device is `unauthorized` in adb and
   no emulator image is installed. So the grid, the player, the loader, the empty states and the
   editor have compiled but not rendered.
4. **The editor's export path is unrun on both platforms** — `AVAssetExportSession` +
   `AVVideoComposition` on iOS, `Transformer` on Android. Export is the most likely place for a
   runtime-only failure (codec/GL surface issues), so exercise it first. **This now matters more:**
   the ladder runs the encoder up to three times per post, so a device-specific codec failure has
   three chances to bite. Check specifically that a portrait clip comes out portrait —
   `Presentation.createForHeight` assumes portrait sources, which is right for clips but would
   letterbox a landscape one.
5. **`023_clips_renditions.sql` is also unrun**, for the same reason as `020`.

Suggested first real test: run the migration on dev, `POST /clips/presign-upload`, then drive one
upload end-to-end from a signed-in device.

---

## 10. Open questions — please confirm

These were built on stated assumptions rather than blocking. Each is cheap to change now and
expensive later — please confirm or correct:

1. **Encryption model (§0).** Built as public/non-E2EE. Load-bearing for the schema, and surfaced to
   users in the composer ("Clips are public. Unlike your chats and moments, they aren't end-to-end
   encrypted."). Changing this means a new migration and losing server-side counts.
2. **Who sees a clip?** Built as a **global explore feed** (everyone's clips, newest first). There is
   **no follow/follower concept in the repo** — "people you follow" needs a social-graph feature
   first, and only the `GET /clips/feed` query would change.
3. **Max duration** — built at **90 s** / 100 MB / 720p, enforced on device *and* server. Changing it
   means editing `ClipCaps` on both platforms and the constants in `routes/clips.ts` together.
4. **Comment replies/threads** — built flat. `clip_comments` has no parent column; threading would
   need a migration.
5. **Grid aspect** — uniform 9:16 tiles, 3 columns, 2pt gutters. Not staggered (that needs per-tile
   aspect before first paint and reflows as pages append).
