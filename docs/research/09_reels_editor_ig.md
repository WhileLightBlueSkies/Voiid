# 09 — Reels record + edit screens: matching Instagram's flow

Scope: the clip **capture and edit** experience on both platforms — `ClipComposerFlow`,
`ClipEditor`, the Android in-app `ClipCameraView` (commit c64d890), and iOS's recording path
(`StoryCameraView` in `.clip` mode). Goal: full-screen camera, segmented record, speed control,
filter carousel over the live preview, and an IG-grade trim/cover/caption flow.

> Verification status: every file:line citation below was re-read against the working tree at
> commit `41eefc7`, and the Signal citations were re-read against `/Users/devacc/Signal stack`.
> Claims about media3/CameraX APIs were checked against the actual pinned `.aar`s, not from memory.
> Statements about Instagram's UI are from product knowledge and are labelled as such (§3.1) —
> they are the design target, not code claims.

Hard constraints honoured: the colour-filter pipeline was **just rebuilt** (iOS `CIPhotoEffect*` +
custom `CIColorControls`; Android media3 `RgbMatrix`/`RgbFilter` with a matching
`android.graphics.ColorMatrix` preview path) and is **reused, not redesigned** by every
recommendation below. Clips remain a deliberate non-E2EE surface (`docs/CLIPS.md` §0; the notice is
rendered at `ClipComposerFlow.swift:287-295` / `ClipEditor.kt:670-676`). Nothing here touches E2EE.

---

## 1. What exists today (cited)

### 1.1 Flow shape (both platforms, deliberately mirrored)

Four steps with a real back stack — `[1] Source → [2] Capture/Pick → [3] Edit → [4] Details & Post`:

- **iOS** `apps/ios/Voiid/Voiid/Main/Clips/ClipComposerFlow.swift`
  - `NavigationStack` over `ClipComposerStep { edit, details }` (ClipComposerFlow.swift:24-50, :238).
  - Step 1 is a menu of two gradient tiles, "Camera" / "Gallery" (:71-128). The camera is a
    `fullScreenCover` presenting `StoryCameraView(mode: .clip)` (:52-62); gallery is `PhotosPicker`
    (:105-110) → temp copy → `accept(url:)` validates duration ≤ 90 s *before* the editor (:191-206).
  - Caps mirror the backend: `ClipCaps.maxDurationSeconds = 90`, `maxBytes = 100 MB`
    (:242-250, mirroring `backend/api/src/routes/clips.ts`).
  - Step 4 `ClipDetailsView`: cover thumb + multiline caption field + public/non-E2EE notice + Post
    (:254-315). Post dismisses immediately and exports/uploads in the background (:210-235).
- **Android** `apps/android/app/src/main/java/com/voiid/app/main/clips/ClipComposerFlow.kt`
  - Same steps as an enum + header back button (ClipComposerFlow.kt:71, :132-160).
  - Camera is a full-screen overlay **above** the step stack, not a step in it (:216-235); its
    multi-take output is joined by `ClipSegments.concatenate` (:224-227) before `accept(uri)`
    (:96-119) runs the same early duration validation.
  - `ClipCaps.MAX_DURATION_MS = 90_000`, `MAX_BYTES = 100 MB` (:73-77).
  - `ClipDetailsView` (caption + notice + Post) at `ClipEditor.kt:601-681`; posting is handed to
    `ClipsStore` so the export survives the composable's dismissal (ClipComposerFlow.kt:192-207).

### 1.2 Recording — Android (the new in-app camera, c64d890)

`apps/android/app/src/main/java/com/voiid/app/main/clips/ClipCameraView.kt`:

- CameraX `Preview` + `VideoCapture.withOutput(Recorder)` with
  `QualitySelector.from(Quality.HD)` — i.e. **720p** (ClipCameraView.kt:98-106).
- **Segmented multi-take recording**: each start/stop writes its own
  `clip_seg_<ts>.mp4` in cache (:148-184); segments are concatenated only at commit
  (`ClipSegments.kt:35-85`, a media3 `Transformer` over an `EditedMediaItemSequence`, single-take
  returned as-is with no transcode).
- **Undo last take** with banked-duration re-derivation from the remaining files (:264-275,
  `durationMsOf` :326-333).
- Tap-to-toggle shutter (76 dp ring, red rounded-square while recording) (:277-293).
- Cap enforced from `VideoRecordEvent.Status.recordingStats.recordedDurationNanos` — the only
  signal tied to bytes actually written (:155-161); elapsed/cap pill in the top bar (:201-216).
- Flip camera (disabled while recording) (:218-222); audio recorded only if `RECORD_AUDIO` was
  actually granted (:111-116); recording stopped on dispose so the file isn't left open (:139-141).
- A thin progress bar under the top bar (:227-241).

Dependencies: CameraX **1.3.4** (`libs.versions.toml:36`) and media3 **1.4.1**
(`libs.versions.toml:41`); `camera-video` was added specifically for this camera
(`libs.versions.toml:87-89`, wired at `apps/android/app/build.gradle.kts:152`). Note the same
CameraX version is shared with the stories camera, which imports `androidx.camera.core/lifecycle/
view` (`apps/android/app/src/main/java/com/voiid/app/main/stories/StoryCameraView.kt:4-10`) — so a
CameraX upgrade (Step 5) is not a clips-only change.

**API availability verified against the pinned artifacts** (unzipped from the Gradle cache, so the
recommendations below cannot fail on a missing class): `androidx/media3/effect/SpeedChangeEffect`,
`RgbMatrix`, `RgbFilter` and `Presentation` are all present in `media3-effect-1.4.1.aar`;
`SonicAudioProcessor` and `ExoPlayer.setVideoEffects` are present in `media3-exoplayer-1.4.1.aar`.

### 1.3 Recording — iOS

There is **no clip-specific camera**. iOS reuses the stories camera,
`apps/ios/Voiid/Voiid/Main/Stories/StoryCameraView.swift`, parameterised by
`CameraMode.clip = (maxSeconds: 90, videoOnly: true)` (StoryCameraView.swift:22-31):

- `AVCaptureSession` + `AVCaptureMovieFileOutput` + `AVCapturePhotoOutput`, configured on a private
  serial queue (:147-169). Preview via `AVCaptureVideoPreviewLayer` (:123-136).
- Shutter: in `.clip` mode a **tap toggles** recording; press-and-hold also records (0.3 s min)
  (:93-118). Flip via input swap (:202-210).
- The 90 s cap is a **1-second wall-clock `Timer`** (:224-238), not a capture-time signal.
- Records to a temp **`.mov`** (:227) even though the callback contract says "video/mp4" (:34).
- One take only: the first `Finalize` fires `onCapture` and dismisses the camera (:76-79);
  `ClipComposerFlow` receives a single URL (ClipComposerFlow.swift:57-61).
- Good salvage logic: a recording cut short by the cap/teardown is kept if
  `AVErrorRecordingSuccessfullyFinishedKey` is set (:254-279).

### 1.4 Editing — both platforms

**iOS** `apps/ios/Voiid/Voiid/Main/Clips/ClipEditor.swift`:

- Edits are a pure **description** — `ClipEdit { trimStart/End, filter, muted, coverSeconds,
  customCoverJPEG }` (ClipEditor.swift:28-44); nothing re-encodes until export.
- **The rebuilt filter pipeline (reuse this):** `ClipFilter` (10 entries, `.none/vivid/dramatic/
  mono/noir/fade/chrome/process/transfer/instant`, names + order shared with Android)
  (:55-102); `apply(to: CIImage)` maps to `CIPhotoEffect*` plus hand-built `CIColorControls` for
  Vivid/Dramatic (:104-132). Export bakes it via
  `AVVideoComposition(asset:applyingCIFiltersWithHandler:)` (:479-487) — the same mechanism Photos
  uses.
- Editor screen: **static frame preview** (an `Image` refreshed by `AVAssetImageGenerator`, not a
  playing video) (:167-182, `refreshPreview` :375-377, `rawFrame` :408-420); trim via **two plain
  `Slider`s** ("Start" / "End") with 0.5 s min and 90 s clamp (:195-220); mute toggle (:227-230);
  cover = frame scrub slider or uploaded image, upload wins (:239-307, re-encoded to bounded JPEG
  :311-325); filter strip of 54×72 thumbs built from one decoded frame (:329-362, :381-391).
- Export: trimmed `AVMutableComposition` (:446-492) → sequential SD/HD/FHD ladder through
  `AVAssetExportSession` presets with upscale-skip and byte-cap drop (:497-533, :540-571).

**Android** `apps/android/app/src/main/java/com/voiid/app/main/clips/ClipEditor.kt` — a faithful
port:

- `ClipEdit` data class with content-equality for the cover bytes (ClipEditor.kt:89-132).
- **The rebuilt filter pipeline (reuse this):** `ClipFilter.effects()` returns the media3
  `Effect` chain — `RgbFilter.createGrayscaleFilter()`, saturation/channel/contrast `RgbMatrix`
  values matched to the iOS numbers (:161-180) — and `applyToBitmap` mirrors it with
  `android.graphics.ColorMatrix` for thumbs/preview/cover, with the row-major/0-255 vs
  column-major/0-1 conversion done correctly (:189-308).
- Editor screen: static `Bitmap` preview (:355-381), two labelled sliders for trim (:392-405),
  cover scrub + upload (:407-498), filter `LazyRow` (:500-538).
- Export: `Transformer` per rung with `MediaItem.ClippingConfiguration` trim,
  `Presentation.createForHeight(quality.longEdge)` then the filter effects (:750-776), pinned to
  the main thread as media3 requires (:786-815); ladder + cover in `exportLadder` (:833-875).

---

## 2. What is broken or weak (cited, with root cause)

1. **iOS has no segmented recording at all.** `StoryCameraView` finalises and dismisses after the
   first take (StoryCameraView.swift:76-79); `ClipComposerFlow` accepts exactly one URL
   (ClipComposerFlow.swift:57-61). No undo, no banked progress, no multi-take — the core of the
   IG record screen is absent on iOS while Android already has it (ClipCameraView.kt:148-184,
   :264-275). Root cause: the clip camera was implemented as a *mode* of the single-shot story
   camera rather than its own screen.
2. **No speed control on either platform.** Nothing in `ClipCameraView.kt`, `StoryCameraView.swift`
   or either editor touches playback rate; `ClipEdit` has no speed field
   (ClipEditor.swift:28-44, ClipEditor.kt:89-132).
3. **No filters over the live preview.** The Android camera comment explicitly names this as the
   reason the in-app camera exists — "no way to ever put the filter strip in the live preview"
   (ClipCameraView.kt:67-72) — but the strip still only appears post-capture in the editor
   (ClipEditor.kt:500-538; ClipEditor.swift:329-362). Root causes: Android is on CameraX 1.3.4
   (libs.versions.toml:36), which predates the stable `CameraEffect`/media3 interop; iOS records
   through `AVCaptureMovieFileOutput` (StoryCameraView.swift:149), and `AVCaptureVideoPreviewLayer`
   cannot render CIFilters — a filtered viewfinder requires the data-output + custom-render
   architecture (see §3, Signal-iOS).
4. **No camera hardware controls.** Neither camera has torch/flash, pinch-to-zoom, tap-to-focus, or
   double-tap flip (whole files: ClipCameraView.kt, StoryCameraView.swift — no
   `CameraControl`/`videoZoomFactor`/`torchMode`/focus code exists). IG's record screen has all
   four; so does Signal on both platforms (§3).
5. **The editor preview is a still frame, not a playing video.** iOS renders an `Image` from
   `AVAssetImageGenerator` (ClipEditor.swift:167-182, :375-377); Android a `Bitmap` from
   `MediaMetadataRetriever` (ClipEditor.kt:355-381). You cannot judge a trim, a filter on motion,
   or audio at all (mute is a blind toggle, ClipEditor.swift:227-230). ExoPlayer is already a
   dependency (build.gradle.kts:158) and AVPlayer is free — the pieces exist, unwired.
6. **Trim is two abstract sliders, not a filmstrip.** ClipEditor.swift:195-220 and
   ClipEditor.kt:392-405. Without frame thumbnails under draggable handles there is no visual
   anchor for *where* start/end land; the cover scrubber has the same problem
   (ClipEditor.swift:298-301, ClipEditor.kt:488-498).
7. **Android in-app recordings can never produce the 1080p rung.** The recorder asks for
   `Quality.HD` (=1280×720) with a comment reasoning about not recording *4K*
   (ClipCameraView.kt:100-104). The ladder skips a rung when
   `sourceEdge < quality.longEdge * 0.9` (ClipEditor.kt:748), and `ClipQuality.FHD.longEdge = 1920`
   (`apps/android/app/src/main/java/com/voiid/app/net/ClipQuality.kt`), so the FHD rung needs a
   source long edge ≥ **1728**. A 720p recording's long edge is **1280** — it fails, always.
   Gallery imports get 1080p; in-app recordings silently top out at 720p. Root cause: `Quality.HD`
   was chosen while the comment reasons about avoiding 4K, so the argument ("the ladder tops out at
   1080p") actually justifies `Quality.FHD`, not `Quality.HD`. The comment and the code disagree
   about which rung is the ceiling.
8. **Android progress bar: comment/code mismatch.** The comment promises "one bar per take"
   (ClipCameraView.kt:225-227) but the implementation draws a **single** proportional `Box`
   (:228-240) — no segment tick marks, so undo has no visual anchor. (IG shows white ticks at each
   segment boundary.)
9. **iOS cap and container weaknesses.** The 90 s cap is a 1 s wall-clock `Timer`
   (StoryCameraView.swift:229-233) rather than `movieOut.maxRecordedDuration`, so overshoot rides
   on `accept()`'s +1 s tolerance (ClipComposerFlow.swift:198); and the file is a `.mov` (:227)
   while the callback contract says "video/mp4" (:34) — harmless today only because the exporter
   re-encodes, but wrong the moment anything trusts the label.
10. **Entry is a menu, not a camera.** Both platforms open on a two-tile "Camera / Gallery" chooser
    (ClipComposerFlow.swift:71-128, ClipComposerFlow.kt:238-285). IG opens straight into the
    viewfinder with gallery as a corner thumbnail — one screen and one decision earlier.

---

## 3. How Instagram and Signal do it

### 3.1 Instagram Reels, screen by screen (from product knowledge — the target)

1. **Record screen** — full-bleed viewfinder, no chrome besides:
   - *Top*: close (×), sound picker, and a thin **segmented progress bar** (fills toward the cap;
     a tick mark is left at each segment boundary).
   - *Right vertical rail*: length toggle (15/30/60/90), **speed (0.3×/0.5×/1×/2×/3×)**, effects
     (filter carousel), touch-up, **timer** (3 s/10 s countdown, optional auto-stop point), flash.
   - *Bottom*: gallery thumbnail (bottom-left, imports straight into the same segment list),
     **shutter** (tap toggles; hold records with **slide-up-to-zoom**), flip (bottom-right;
     double-tap on the viewfinder also flips).
   - *Filters*: swiping horizontally on the viewfinder (or picking from the carousel wrapped
     around the shutter) changes the live look; the selected look carries into the recording.
   - *Per-segment*: speed and filter are captured per segment; **undo** (←) deletes the last
     segment after a confirm; a check (✓) commits to the edit screen.
2. **Edit screen** — the joined video **plays in a loop**, full-screen; top rail: audio, text,
   stickers, effects, overflow; bottom: "Edit video" (opens per-clip timeline: trim handles on a
   frame filmstrip, reorder, split) and **Next**.
3. **Share screen** — caption field beside the cover thumbnail; **"Edit cover"** opens a
   frame-filmstrip scrubber plus "Add from camera roll"; tag people, location; Share / save draft.

Voiid already has the share screen's essentials (caption, cover-frame-or-upload with upload-wins
precedence, details step) — the gaps are almost entirely on screens 1 and 2.

### 3.2 Signal — the concrete architecture to copy where it overlaps

- **Signal-iOS records video with `AVCaptureVideoDataOutput` + `AVCaptureAudioDataOutput` feeding
  an `AVAssetWriter`**, not `AVCaptureMovieFileOutput`:
  `Signal-iOS/Signal/src/ViewControllers/Photos/CameraCaptureSession.swift:1153-1260`
  (`videoDataOutput`/`audioDataOutput` declared :1153-1154, `AVAssetWriter` + writer inputs
  :1160-1162, writer built with `recommendedVideoSettings` :1202-1241, sample buffers appended on a
  dedicated recording queue :1358). This is precisely the architecture that makes a *filtered live
  preview + recording* possible on iOS — once frames flow through your code, you can render them
  through Core Image to a Metal view and still write them (filtered or clean) to disk.
- **Signal-iOS shutter gesture**: a `UILongPressGestureRecognizer` with
  `minimumPressDuration = 0` on the shutter (`MediaControls.swift:184-188`), a 0.5 s threshold
  timer promotes press → recording (:416, :448-461), and while recording, vertical drag distance is
  converted to zoom via `zoomScaleReferenceDistance` (:463-470, :1870-1889 in
  PhotoCaptureViewController.swift) — the exact "hold to record, slide up to zoom" behaviour IG
  uses.
- **Signal-Android viewfinder gestures**: `detectTapGestures(onDoubleTap = SwitchCamera,
  onTap = TapToFocus)` plus `detectTransformGestures { … PinchZoom }` directly on the Compose
  preview surface
  (`Signal-Android/feature/camera/src/main/java/org/signal/camera/CameraScreen.kt:161-185`), with a
  drawn focus indicator (:188+). Voiid's Compose camera can lift this pattern verbatim.
- **Signal-Android capture flow** separates HUD events (`VideoCaptureStarted`/`VideoCaptureStopped`)
  from the recording implementation
  (`Signal-Android/feature/media-send/src/main/java/org/signal/mediasend/capture/CameraXFragment.kt:578-599`)
  — a useful shape once Voiid's shutter grows tap *and* hold *and* timer entry points.

(Signal consulted for flow/architecture only, per policy — nothing MLS/persistence related here.)

---

## 4. Recommended fixes — an implementable, independently-shippable sequence

Ordering rule: each step ships alone, leaves the flow working, and later steps build on earlier
ones. The filter *pipeline* (`ClipFilter.apply` / `ClipFilter.effects()`) is never modified — only
new call sites are added.

### Step 1 (iOS, high) — dedicated segmented `ClipCameraView`, parity with Android

- **New file** `apps/ios/Voiid/Voiid/Main/Clips/ClipCameraView.swift`; wire it in place of the
  `StoryCameraView(mode: .clip)` cover at `ClipComposerFlow.swift:52-62`. Stories keep
  `StoryCameraView` untouched (remove `CameraMode.clip` once migrated).
- AVFoundation pieces: keep the proven `AVCaptureSession` + private-queue pattern from
  `StoryCameraView.swift:143-210` (including the finalize-salvage logic :254-279), but:
  - one `AVCaptureMovieFileOutput` recording **per take** to `clip_seg_<uuid>.mov`; a
    `segments: [URL]` list with banked-duration accounting mirroring ClipCameraView.kt:92-95;
  - undo-last-take and per-segment progress bar with tick marks (mirror ClipCameraView.kt:264-275);
  - cap via `movieOut.maxRecordedDuration = CMTime(seconds: 90 - banked, …)` per take instead of
    the 1 s `Timer` (fixes weakness §2.9), and a live elapsed/cap pill fed by
    `movieOut.recordedDuration`;
  - on ✓, concatenate takes: insert each into one `AVMutableComposition` and export with
    `AVAssetExportPresetPassthrough` (same codec/session settings for every take, so no re-encode;
    fall back to `AVAssetExportPreset1920x1080` if passthrough fails), then hand the single URL to
    the existing `accept(url:)` (ClipComposerFlow.swift:191-206). Single take returns as-is —
    mirror `ClipSegments.kt:36-37`.
- Risk: low-medium. The capture patterns are already proven in-app; the only new machinery is
  passthrough concatenation.

### Step 2 (Android, medium) — record at FHD; per-segment ticks in the progress bar

- `ClipCameraView.kt:100-104`: `Quality.HD` → `QualitySelector.from(Quality.FHD,
  FallbackStrategy.higherQualityOrLowerThan(Quality.HD))`, and fix the comment. The rung test is
  `sourceEdge < quality.longEdge * 0.9` (`ClipEditor.kt:748`) with `FHD.longEdge = 1920`, i.e. a
  source long edge ≥ 1728 is required; 720p capture gives 1280 and silently amputates the top rung.
  `FallbackStrategy` matters here — devices without a 1080p profile must still record rather than
  fail to bind.
- `ClipCameraView.kt:227-241`: render one `Box` per finished segment (widths from each segment's
  `durationMsOf`) plus the live segment, with 2 dp gaps — making the code match its own comment
  (:225-227) and giving undo a visual anchor.
- Risk: low. FHD capture raises file sizes (~2×) but exports were already sized for gallery-sourced
  1080p.

### Step 3 (both-mobile, medium) — viewfinder hardware controls

- **Android** (`ClipCameraView.kt`): keep a reference to the bound `Camera` from
  `bindToLifecycle` (:129); add `pointerInput` on the preview `AndroidView` wrapper with
  `detectTransformGestures` → `camera.cameraControl.setZoomRatio(current * zoom)` and
  `detectTapGestures(onDoubleTap = flip, onTap = tapToFocus)` using
  `previewView.meteringPointFactory.createPoint(x, y)` →
  `cameraControl.startFocusAndMetering(FocusMeteringAction)`; torch button →
  `cameraControl.enableTorch(on)` gated on `cameraInfo.hasFlashUnit()`. Pattern:
  Signal-Android `CameraScreen.kt:161-185`.
- **iOS** (new `ClipCameraView.swift` from Step 1): pinch → `device.videoZoomFactor` (clamped by
  `activeFormat.videoMaxZoomFactor`, with `lockForConfiguration`); tap →
  `focusPointOfInterest`/`exposurePointOfInterest` via
  `previewLayer.captureDevicePointConverted(fromLayerPoint:)`; torch → `device.torchMode`;
  slide-up-to-zoom while holding the shutter per Signal-iOS `MediaControls.swift:430-470`.
- Risk: low. Pure additive control-plane code.

### Step 4 (both-mobile, medium) — speed control (0.3×/0.5×/1×/2×/3×), per segment

Record every take at 1× and store the chosen speed *next to* the segment; apply speed at
join/export so the camera never re-encodes (consistent with the "edit description" architecture,
ClipEditor.swift:15-17 / ClipEditor.kt:86-88).

- **Android**: segment model `data class Take(file: File, speed: Float)` in `ClipCameraView.kt`
  (rail button cycles the speed for the *next* take; banked-duration math divides by speed so the
  90 s cap counts output seconds). In `ClipSegments.kt:35-85`, build each `EditedMediaItem` with
  `Effects(listOf(SonicAudioProcessor().apply { setSpeed(take.speed) }),
  listOf(androidx.media3.effect.SpeedChangeEffect(take.speed)))` — both classes exist in the
  pinned media3 1.4.1. The join then always runs (drop the single-take shortcut at
  `ClipSegments.kt:37` only when `speed != 1f`).
- **iOS**: in the Step-1 concatenation, after inserting each take's range call
  `composition.scaleTimeRange(insertedRange, toDuration: CMTime(seconds: takeDuration/speed, …))`
  (scales audio pitch-naively; acceptable v1 — IG's audio at 2× is also chipmunked). Passthrough
  export is no longer valid for scaled segments; use `AVAssetExportPreset1920x1080` when any
  speed ≠ 1.
- Risk: medium. Speed × cap accounting must count *output* duration; test 0.3× against the 90 s cap
  on both sides of the backend mirror (`backend/api/src/routes/clips.ts`).

### Step 5 (Android, medium) — filter carousel over the live preview (reuse `ClipFilter.effects()`)

- Upgrade CameraX 1.3.4 → **1.4.x** (`apps/android/gradle/libs.versions.toml:36`) and add the
  interop artifact **`androidx.camera.media3:media3-effect`** (`app/build.gradle.kts` next to
  :146-152). It exposes `Media3Effect(context, targets, executor, errorListener)` — a
  `CameraEffect` that runs a media3 `Effect` list on the camera stream.
- In `ClipCameraView.kt`, add the effect to the use-case group with target **`PREVIEW` only** and
  `media3Effect.setEffects(selectedFilter.effects())` — the exact `RgbMatrix` chains from
  `ClipEditor.kt:161-180`, unchanged. Recording stays clean; the selection is returned alongside
  the segments and pre-populates `ClipEdit.filter` in `ClipComposerFlow.kt:110-115`, so the
  existing exporter bakes it exactly once (`ClipEditor.kt:769-772`). This preserves
  non-destructive editing and avoids double-application.
- UI: horizontal swipe on the viewfinder pages through `ClipFilter.entries` with the label flashed
  centre-screen (IG behaviour); the editor strip remains the place to change your mind.
- Risk: medium — the CameraX upgrade is the risky half (StoryCameraView.kt shares the artifacts);
  the effect itself is preview-only and cannot corrupt recordings. If 1.4 must wait, the fallback
  is a manual `CameraEffect` + `SurfaceProcessor` running the same matrices in a GL shader —
  strictly more code, same contract.

### Step 6 (iOS, high effort, medium priority) — live-filtered viewfinder via the Signal architecture

- In the Step-1 `ClipCameraView.swift` controller, replace preview-by-`AVCaptureVideoPreviewLayer`
  with: `AVCaptureVideoDataOutput` (+ `AVCaptureAudioDataOutput`) → per-frame
  `CIImage(cvPixelBuffer:)` → **existing** `ClipFilter.apply(to:)` (ClipEditor.swift:104-132) →
  `CIContext.render` into an `MTKView`; record by appending the **clean** sample buffers to an
  `AVAssetWriter` (`AVAssetWriterInput` with
  `videoDataOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mp4)`). This is
  Signal-iOS's proven shape, `CameraCaptureSession.swift:1153-1260` — data outputs, writer inputs,
  dedicated capture/recording queues. Keep recording clean and carry the selection into
  `ClipEdit.filter` exactly as on Android (single bake at export, ClipEditor.swift:479-487).
- `AVCaptureMovieFileOutput` and `AVCaptureVideoDataOutput` do not coexist usefully in one session,
  so this *replaces* the movie output inside the clip camera only; the stories camera is untouched.
- Ships independently of Step 5; until it lands, iOS still gets segments/speed/zoom from Steps 1-4.
- Risk: high (writer session timing, orientation/mirroring transforms, dropped-frame handling) —
  which is why it is sequenced after the cheap wins and copied from a battle-tested source.

### Step 7 (both-mobile, high) — editor becomes a playing preview with an IG trim filmstrip

- **iOS** (`ClipEditor.swift:167-182` and :195-220): replace the still `Image` with `AVPlayer` in a
  `VideoPlayer`/`AVPlayerLayer`; live filter preview via `playerItem.videoComposition =
  AVVideoComposition(asset:applyingCIFiltersWithHandler:)` using the *same* closure as export
  (:479-487); loop the trimmed range with `addPeriodicTimeObserver` seeking back to `trimStart`;
  mute toggle drives `player.isMuted`. Replace the two sliders with a filmstrip: ~10
  `AVAssetImageGenerator` thumbs in an `HStack` under two draggable handle overlays writing
  `edit.trimStart/End` (drag gesture → seconds via strip width).
- **Android** (`ClipEditor.kt:355-405`): `ExoPlayer` (already a dependency,
  `app/build.gradle.kts:158`) in an `AndroidView(PlayerView)`; live filter via
  `exoPlayer.setVideoEffects(edit.filter.effects())` (available in media3 1.4.1; reuses
  ClipEditor.kt:161-180 untouched); trim loop via `MediaItem.ClippingConfiguration` rebuilt on
  handle release (not per-frame — rebuilding the item is a seek, so debounce);
  filmstrip thumbs from `MediaMetadataRetriever.getFrameAtTime(…, OPTION_CLOSEST_SYNC)` on
  `Dispatchers.IO` (same call as `ClipExporter.frameBitmap`, :702-710).
- The cover scrubber (ClipEditor.swift:298-301, ClipEditor.kt:488-498) reuses the same filmstrip
  composable/view with a single handle — IG's "Edit cover" exactly; keep the upload-wins
  precedence untouched (ClipEditor.swift:574-588, ClipEditor.kt:853-863).
- Risk: medium. All decode paths already exist; the new work is UI + player lifecycle
  (release the player on dispose; pause on backgrounding).

### Step 8 (both-mobile, low) — camera-first entry with in-camera gallery button

- Make the camera the first screen of the flow, with the gallery reachable from a bottom-left
  thumbnail *inside* the viewfinder (latest video thumb), collapsing the tile menu
  (ClipComposerFlow.swift:71-128, ClipComposerFlow.kt:238-285) into it. Imported videos join the
  same `accept()` path; on Android an import mid-recording session should append to the segment
  list (IG behaviour) — v1 can keep import-replaces-takes with a confirm.
- Risk: low, but do it *after* the camera is IG-grade — promoting today's camera to the front door
  would showcase the gaps.

### Step 9 (iOS, low) — StoryCameraView hygiene (independent of everything above)

- `StoryCameraView.swift:227` records `.mov` while the contract comment (:34) says "video/mp4":
  either write `.mov` into the comment or (better) keep the story path as-is and let the new clip
  camera (Steps 1/6) own mp4. Replace the 1 s `Timer` cap (:229-233) with
  `movieOut.maxRecordedDuration` for stories too.

### Explicit non-goals (scoped out deliberately)

- **Music/audio overlay, text, stickers, AR effects** — IG edit-screen features with server-side
  licensing (music) or large new subsystems; none block the record/trim/filter parity above.
- **Redesigning the filter looks or list** — the pipeline was just rebuilt with matched
  cross-platform values (ClipEditor.swift:86-132 ↔ ClipEditor.kt:161-235); every step above only
  adds call sites.
- **Backend changes** — the 90 s / 100 MB caps and ladder contract are untouched; everything here
  is client capture/edit UX.
