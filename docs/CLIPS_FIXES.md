# Clips + Moments — bug fixes and UX work

Status: **task list, in progress.** Written 2026-07-29 after testing the first Clips build on a
real iPhone 15 (iOS 26.5) and a Motorola I2221 (Android 16).

Every item below has a **confirmed root cause read out of the code**, not a guess. Where a bug
exists on one platform, the other platform was checked for the same class of problem and the
finding is recorded either way — several of these are mirror-image bugs.

---

## 1. Android: upload crashes the app · **CONFIRMED — OOM**

**Root cause:** [`ClipsStore.kt:357`](../apps/android/app/src/main/java/com/voiid/app/model/ClipsStore.kt#L357)
and `:378` call `File.readBytes()`, which allocates the **entire video as one JVM byte array**.
The cap is 100 MB and the ladder uploads up to four files (baseline + 3 renditions), so peak heap
is far past the per-app limit on most devices. `OutOfMemoryError` kills the process — which is
exactly the "app crashing, upload not working at all" symptom.

`ClipService.uploadBlob(url, bytes: ByteArray, …)` forces this: its signature *requires* the whole
array.

**Fix:** stream the file. `okhttp3.RequestBody.create(mediaType, file)` streams from disk with a
fixed buffer and never materialises the whole video. Change `uploadBlob` to take a `File`.

**iOS cross-check:** *not* affected in the same way — `Data(contentsOf:)` memory-maps the file
rather than copying it onto the heap, so it survives. But it is still holding a mapped 100 MB
region per rendition and passing it to `URLSession.upload(for:from:)`. Switch to
`URLSession.upload(for:fromFile:)` so the OS streams it — same intent, and it removes the mapping
entirely. Lower priority than Android (not a crash), but it is the same design flaw.

---

## 2. Android: camera capture returns nothing · **CONFIRMED — state lost across process death**

**Root cause:** [`ClipComposerFlow.kt:217`](../apps/android/app/src/main/java/com/voiid/app/main/clips/ClipComposerFlow.kt#L217)
stores the capture target in a **file-level `private var pendingCaptureUri`** — a plain top-level
mutable global:

```kotlin
private var pendingCaptureUri: Uri? = null
```

Launching the system camera can (and on low-memory devices routinely does) kill the host process.
When it is recreated to deliver the result, that global is back to `null`, so the callback

```kotlin
val uri = pendingCaptureUri
if (ok && uri != null) accept(uri)      // uri == null -> silently does nothing
```

drops the recording on the floor. That is precisely the reported behaviour: *record, release, no
video, camera opens again.*

Two aggravating factors:
- **The failure is silent.** `ok == true` and a null uri produce no error and no log — the user
  gets no signal at all.
- **`newCaptureUri` can return `Uri.EMPTY`** if the MediaStore insert fails; `EMPTY` is non-null,
  so it passes the null check and then fails later with nothing useful surfaced.

**Fix:** hold the URI in `rememberSaveable` (survives process death), verify the result actually
has bytes before accepting, and surface a real error when it does not.

**iOS cross-check:** *not* affected. iOS reuses `StoryCameraView` and receives the recorded file
URL directly in the callback closure — no cross-process handoff, no global. No change needed.

---

## 3. iOS: reels player lags and the clip is cropped · **CONFIRMED — rotated TabView hack**

**Root cause:** [`ClipFullscreenView.swift:65–88`](../apps/ios/Voiid/Voiid/Main/Clips/ClipFullscreenView.swift#L65)
fakes vertical paging by rotating a horizontal `TabView` 90°:

```swift
.rotationEffect(.degrees(-90))
.frame(width: height, height: UIScreen.main.bounds.width)   // width/height SWAPPED
...
.rotationEffect(.degrees(90), anchor: .topLeading)
.offset(x: UIScreen.main.bounds.width)
```

This causes both reported symptoms at once:
- **Cropped:** each page is framed with **width and height transposed**, so the video's container
  has the wrong aspect ratio on every single page. `VideoPlayer` fits itself to that wrong box.
- **Laggy:** every page is inside two nested `rotationEffect`s, forcing SwiftUI to render each
  frame off-screen and re-composite it. That is per-frame GPU work on top of video decode.

It also hardcodes `UIScreen.main.bounds`, which is wrong on iPad/split-view and is deprecated.

**Fix:** delete the hack entirely. Use a native vertical `TabView` with
`.tabViewStyle(.page)` in a `ScrollView(.vertical)` with `.scrollTargetBehavior(.paging)` —
the supported API for exactly this. Feed it the `GeometryReader` size instead of `UIScreen`.

**Android cross-check:** already correct — it uses `VerticalPager`, the native API, with no
rotation. **But Android has the mirror bug for cropping:**
[`ClipFullscreenView.kt:215`](../apps/android/app/src/main/java/com/voiid/app/main/clips/ClipFullscreenView.kt#L215)
sets `RESIZE_MODE_ZOOM`, which **crops to fill** and cuts off the edges of any clip whose aspect
does not match the screen. Change to `RESIZE_MODE_FIT`. So: iOS crops from a broken frame,
Android crops deliberately — both need fixing, for different reasons.

---

## 4. Reels: scroll-to-next, and tap-hold speed controls

Requested: scroll to advance (Instagram-style), **hold right side → 2x**, **hold left side → 0.5x**.

- **Scroll to next:** Android already pages correctly. iOS gets it for free once §3 replaces the
  rotation hack with real paging.
- **Speed controls:** implement on both. Hold (not tap — a tap already toggles mute) on the right
  third → `rate = 2.0`; left third → `rate = 0.5`; release → back to `1.0`. Show a small floating
  "2x" / "0.5x" pill while held so the state is visible.
  - iOS: `AVPlayer.rate`, driven by a `DragGesture(minimumDistance: 0)` so press/release are
    distinguishable.
  - Android: `ExoPlayer.setPlaybackSpeed()`, driven by `detectTapGestures(onPress =)` with
    `tryAwaitRelease()`.

**Care:** the existing single-tap mute toggle must keep working — a long-press must not also fire
the mute tap.

---

## 5. Upload UI redesign

The current composer is functional but plain: a bare list of cards, a slider stack, no visual
weight. Requested: make it genuinely good-looking.

Plan (same design on both platforms so they stay one product):
- **Source step:** full-bleed gradient cards with large icons, and a **recent-videos strip** along
  the bottom so the common case is one tap instead of three.
- **Editor:** move the preview to a large rounded card that fills most of the screen; put trim,
  cover and filters into a segmented bottom sheet rather than a scrolling column of sliders.
- **Filter strip:** bigger thumbnails, selected state with a coloured ring + label, snap scrolling.
- **Details step:** cover thumbnail beside the caption field, a clear public-content notice, and a
  prominent Post button.
- Progress and failure states on the grid tile stay as they are — those already work.

---

## 6. Moments: iOS → Android delivery fails · **CONFIRMED cause, plus a mirror bug**

**Root cause (Android receive side):**
[`StoryEngine.kt:215`](../apps/android/app/src/main/java/com/voiid/app/net/StoryEngine.kt#L215)
drops any story whose author is not "reachable" — i.e. not in the address book **and** not a 1:1
chat peer. `reachableAuthors()` builds that set from `LocalStore.conversations` +
`UserDirectory.knownUserIds()`. On a freshly installed / freshly signed-in device those are
frequently **empty**, so a perfectly valid story from a real contact is discarded — and the feed is
**deliver-once**, so the drop is permanent.

Good news: it is already logged (`🚫 story DROPPED … is neither a contact nor someone you have a
chat with`), so this is confirmable in logcat rather than theoretical.

**Fix:** keep the anti-spam intent but stop making it destructive. Accept the story and mark it
*pending/unknown-sender* rather than discarding it, **or** refresh the directory before evaluating
reachability. Never permanently drop a deliver-once item on a cache that may legitimately be cold.

**iOS cross-check — the same bug exists in reverse.** `StoryEnvelope` on iOS (Story.swift:33–43)
was already fixed for Android→iOS: `v`, `t`, `caption`, `allowsReplies` are `Optional` because
Kotlin's `encodeDefaults = false` omits them. Android's decoder uses non-null Kotlin defaults +
`explicitNulls = false`, which handles *absent* keys — but iOS's `JSONEncoder` **emits
`"caption": null` explicitly** for a nil optional, and kotlinx throws on an explicit `null` for a
non-nullable field. That is a second, independent iOS→Android drop path.

**Fix:** make the nullable-capable fields `String?`/`Boolean?` on Android with null-coalescing at
use site, and/or add `coerceInputValues = true` to the `Json` config. Verify with a real
iOS→Android send, not just a unit test.

---

## Order of work

1. **Android upload OOM** (§1) — it is a hard crash, everything else is cosmetic beside it.
2. **Android camera capture** (§2) — feature is completely non-functional.
3. **iOS player rotation hack** (§3) — fixes lag + crop + unlocks scroll paging.
4. **Android RESIZE_MODE_FIT** (§3 cross-check) — one line.
5. **Moments cross-platform delivery** (§6) — both directions, verified on device.
6. **Speed controls** (§4).
7. **Upload UI redesign** (§5) — largest, purely visual, safest to do last.

## Verification bar

Compiling is not passing. Each item must be confirmed on a real device:
- Android: post a clip end-to-end without the process dying; record from camera and see the clip.
- iOS: scroll through several reels — no stutter, no cropping, correct aspect on portrait *and*
  landscape sources.
- Moments: send iOS→Android **and** Android→iOS, confirm arrival on the other device.
