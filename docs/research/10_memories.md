# Memories (Moments / Stories) viewer — lag and black space

Research doc, 2026-08-05. Topic: *"Memories viewer is laggy with too much black space — make it
like WhatsApp status."*

Naming note: the feature is called **Moments** in the UI (`StoriesHomeView.swift:48`
`.navigationTitle("Moments")`, `StoriesHomeView.kt:65`), **Stories** in every type, file and
table name, and **Memories** in the request. They are the same feature. This doc uses "story"
for the code-level noun.

**E2EE constraint, restated up front.** Unlike Clips, moments are end-to-end encrypted
per-recipient-device: one AES-256-GCM media blob in R2, plus one ~400-byte ratchet envelope per
target device carrying the key (`017_stories.sql:1-18`, `:48-58`). Every fix in this doc is
client-side rendering, decode and scheduling work on **already-decrypted local plaintext files**.
Nothing here adds a server round-trip for media content, changes what the server stores, or
routes plaintext through the API. Specifically: the "blur backdrop" recommended below is generated
on-device from the local decrypted file — it is **not** a server-side blurhash like Signal's
(Signal can do that because the blurhash travels in its own E2EE attachment pointer; ours would
have to be added to `StoryEnvelope`, which is a protocol change, see §4.7).

---

## 1. What exists today

### 1.1 iOS

| Piece | File |
| --- | --- |
| Viewer (outer author pager + inner stepper) | `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift` |
| Segmented progress bar | `apps/ios/Voiid/Voiid/Main/Stories/StorySegmentProgressView.swift` |
| Tray / entry point | `apps/ios/Voiid/Voiid/Main/Stories/StoriesHomeView.swift` |
| Download + decrypt + prefetch | `apps/ios/Voiid/Voiid/Networking/StoryEngine.swift` |
| Models | `apps/ios/Voiid/Voiid/Models/Story.swift` |

Structure (`StoryViewerView.swift:26-47`): a `ZStack` with `Color.black.ignoresSafeArea()` behind a
`TabView` in `.page(indexDisplayMode: .never)` style, one page per `StoryContext` (author). Each
page is a `StoryContextPlayer` (`:57-333`) that owns the inner index, a 30 Hz `Timer.publish`
tick (`:78`), the progress float, the `AVPlayer`, and the load state.

Already present and working:
- **Segmented progress bar** — one capsule per story, driven by an explicit float rather than
  animation interpolation, so pause/resume is exact (`StorySegmentProgressView.swift:19-38`,
  invoked at `StoryViewerView.swift:104`).
- **Tap zones** — left third back, right two-thirds forward (`StoryViewerView.swift:93-99`).
- **Long-press pause + chrome fade** (`:118-123`).
- **Swipe-down dismiss** — `DragGesture(minimumDistance: 40)`, fires above 80pt
  (`:124-129`).
- **Content-driven durations** — images 5s, video `min(duration, 30s)` (`Story.swift:94-97`).
- **Timer does not start until the media is downloaded** (`:303` guards on `loadState == .ready`).
- **Prefetch of the next story in the current context** (`:295-300`).

### 1.2 Android

| Piece | File |
| --- | --- |
| Viewer | `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryViewerView.kt` |
| Media frame + thumbnail decode | `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryCommon.kt` |
| Segmented progress | `apps/android/app/src/main/java/com/voiid/app/main/stories/StorySegmentProgress.kt` |
| Store (Compose VM) | `apps/android/app/src/main/java/com/voiid/app/model/StoriesStore.kt` |
| Download + decrypt | `apps/android/app/src/main/java/com/voiid/app/net/StoryEngine.kt` |
| Host | `apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:542-556` |

Structure (`StoryViewerView.kt:81-99`): `Box(fillMaxSize().background(Black))` wrapping a
`HorizontalPager` over contexts; each page is `ContextPage` (`:101-297`) with the inner index,
three `LaunchedEffect`s (download+prefetch `:124-131`, viewed-after-1s `:137-141`, 30 Hz progress
timer `:145-155`), and `detectTapGestures` for press/tap (`:159-176`).

Same feature parity as iOS, plus:
- Viewed is recorded **after 1 s on screen**, keyed on `active` so a pre-composed neighbour page
  does not fire a receipt for a story never seen (`:133-141` — the comment there is correct and
  load-bearing).
- Caption is rendered in the chrome column (`:227-232`); iOS renders no caption at all in the
  viewer.

### 1.3 Backend / schema — not implicated in the lag

`backend/api/src/routes/stories.ts` and `database/migrations/017_stories.sql` are a per-device
key-envelope fan-out with a `FEED_LIMIT = 200` (`stories.ts:48`) and partial indexes on the
undelivered rows (`017_stories.sql:61-62`, `:80-81`). The viewer's per-item hot path touches the
server exactly once per story — `POST /stories/presign-download` (`stories.ts:227`) — and only on
a cache miss. **No backend change is needed for this topic**, and none is proposed.

---

## 2. What is broken or weak

Ordered by contribution to the two reported symptoms ("laggy", "too much black space").

### 2.1 iOS — the viewer content is inset by the safe area, so it is framed in black · CONFIRMED

`StoryViewerView.swift:28` applies `.ignoresSafeArea()` to `Color.black` **only**. The `TabView`
at `:29`, and therefore the `GeometryReader` at `:86` and every pixel of media inside it, is
laid out inside the safe area. On a notched iPhone that is ~59pt of black at the top and 34pt at
the bottom — a black frame around the media on every single story.

`.statusBarHidden(true)` at `:46` hides the status bar *content* but does **not** change the safe
area insets, so the top band remains.

Cross-check: Clips got this right — `ClipFullscreenView.swift:58` puts
`.background(Color.black.ignoresSafeArea())` on the container and feeds the pages the
`GeometryReader` size. Stories was never given the same treatment.

**Root cause:** missing `.ignoresSafeArea()` on the media container; the modifier is on the
backdrop instead.

### 2.2 iOS — `scaledToFit` letterboxes on top of the safe-area inset · CONFIRMED

`StoryViewerView.swift:148-149`:

```swift
} else if let url = fileURL, let img = UIImage(contentsOfFile: url.path) {
    Image(uiImage: img).resizable().scaledToFit()
```

`scaledToFit` fits the whole image inside the (already inset, §2.1) box. A 4:3 photo on a 19.5:9
phone leaves large black bands above and below **in addition to** the safe-area frame. The two
defects compound: this is the direct cause of "too much black space".

WhatsApp Status and Signal both solve this by never showing bare black — see §3.

### 2.3 iOS — the image is decoded synchronously on the main thread, inside `body` · CONFIRMED

Same line, `StoryViewerView.swift:148`. `UIImage(contentsOfFile:)` reads and decodes the file
**synchronously**, and it is called from inside a `@ViewBuilder` — i.e. **on the main thread,
during view evaluation**. Story media is a full-resolution JPEG capped at 10 MB
(`StoryEngine.swift:216` documents the §8.2 cap), so this is a multi-hundred-millisecond
main-thread stall on a large photo.

Worse, it re-decodes **on every `body` evaluation**, and `body` is re-evaluated at **30 Hz** —
the `.onReceive(tick)` at `:134` mutates `progress` (`:312`), which is `@State`, which invalidates
the view. So a still photo is decoded from disk up to 30 times per second for the entire 5 s it
is on screen. That is the single largest lag source on iOS.

Cross-check: Clips does not have this defect — `ClipsUIKit.swift:110-123` resolves the image in a
`.task(id:)` into `@State`, with a `ClipThumbCache` in front of it.

**Root cause:** synchronous decode in the view body, with no cache and no `@State` hand-off, on a
view that invalidates at 30 Hz.

### 2.4 iOS — SwiftUI `VideoPlayer` letterboxes and ships its own controls · CONFIRMED

`StoryViewerView.swift:146-147`:

```swift
if let s = current, s.media.mime.hasPrefix("video"), let player {
    VideoPlayer(player: player).disabled(true)
```

This is *exactly* the defect Clips already diagnosed and fixed. From
`ClipFullscreenView.swift:467-472`:

> SwiftUI's `VideoPlayer` cannot do this — it always letterboxes and always brings its own
> controls. `.resizeAspect` shows the whole frame at its true aspect ratio…

Clips replaced it with `ClipPlayerLayerView`, a `UIViewRepresentable` over `AVPlayerLayer`
(`ClipFullscreenView.swift:473-492`). Stories still uses the letterboxing `VideoPlayer`. The
`.disabled(true)` at `:147` suppresses interaction but does not remove the control chrome's
compositing cost or its layout.

### 2.5 iOS — a new `AVPlayer` is constructed per story, with no pool and no warm item · CONFIRMED

`StoryViewerView.swift:285-289` builds `AVPlayer(url:)` fresh inside `loadCurrent()`, and `:274`
tears the previous one down (`player?.pause(); player = nil`). Nothing is retained across the
step, so every forward tap on a video story pays a full asset-load + first-frame-decode from
cold. During that window `loadState` is `.loading` and the user sees `ProgressView` on black
(`:143-144`) — more black space, this time transient.

Cross-check: Clips has `ClipPlayerPool` holding a ±1 window with `retainOnly`/`prepare`
(`ClipFullscreenView.swift:497-552`). Stories has no equivalent.

### 2.6 iOS — prefetch is bytes-only, one item deep, and does not cross the context boundary · CONFIRMED

`StoryViewerView.swift:295-300`:

```swift
private func prefetchNext() {
    let n = index + 1
    guard stories.indices.contains(n) else { return }
    Task { await engine.ensureDownloaded(stories[n]) }
}
```

Three limitations, each of which produces a visible spinner:
1. **Depth 1.** Signal warms 3 items ahead (`StoryContextViewController.swift:737`
   `subsequentItemsToLoad = 3`).
2. **Never crosses to the next author.** The last story of author A does not warm the first story
   of author B, so *every* horizontal swipe between people is a cold start. Signal explicitly
   walks into subsequent contexts to fill its window
   (`StoryContextViewController.swift:745-762`).
3. **Bytes only, no decode.** `ensureDownloaded` returns a file path; the expensive part (JPEG
   decode, §2.3) is still paid on display. Signal's `StoryCache.prefetch` warms **decoded
   drawables at the exact display size** (`StoryCache.kt:33-67`).

Also note `prefetchNext()` is called at `:291`, i.e. only *after* the current item finished
downloading — so on a cold context the prefetch of item 2 is serialised behind item 1's full
round-trip. This is the same class of defect as the clips-pager serial-await bug that
`CLIPS_FIXES.md` §3 and the current `ClipFullscreenView.swift:130-146` call out by name.

### 2.7 iOS — `TabView` page style eagerly builds every author's page · CONFIRMED (hypothesis on cost)

`StoryViewerView.swift:29-39` uses a plain `ForEach` inside `TabView` — not `LazyHStack`. SwiftUI's
paged `TabView` constructs the `StoryContextPlayer` for every context up front. Each one installs
its own `Timer.publish(every: 1.0/30.0)` **autoconnected at construction**
(`:78` — `.autoconnect()` starts on subscription, and `.onReceive` at `:134` subscribes for
every constructed page).

So with 12 authors in the tray, **12 timers fire at 30 Hz simultaneously**, each invoking
`advanceProgress()` (`:302`). The inactive ones return early at `:303` (`guard isActive`), so
they do no work — but 360 timer fires/second still cost dispatch and view-invalidation overhead.
*Marked hypothesis:* the early-return means this is a secondary contributor, not the primary one;
§2.3 dominates. It should still be fixed because it scales with tray size.

### 2.8 Android — full-resolution bitmap decoded with no downsampling · CONFIRMED

`StoryCommon.kt:53-62`:

```kotlin
val decoded = withContext(Dispatchers.IO) {
    runCatching {
        if (isVideo) { MediaMetadataRetriever().use { r -> r.setDataSource(p); r.getFrameAtTime(0) } }
        else { BitmapFactory.decodeFile(p) }
    }.getOrNull()
}
```

The decode is correctly **off the main thread** (unlike iOS, §2.3) — good. But
`BitmapFactory.decodeFile` with no `BitmapFactory.Options.inSampleSize` allocates the bitmap at
**full source resolution**. A 12 MP photo is ~48 MB as ARGB_8888. `grep` confirms no
`inSampleSize` or `BitmapFactory.Options` anywhere in the Android app.

Compounding it: `thumbCache` (`StoryCommon.kt:40`) is a **plain unbounded `HashMap`** of decoded
`ImageBitmap`, never evicted, and it is shared between the tray cells and the full-screen viewer
(`:49`, `:62`). Ten photo stories viewed in a session = ~480 MB retained. On a mid-range device
that is GC pressure at best and an OOM at worst — and GC pauses read as exactly the reported
"lag".

**Root cause:** no downsampling to display size, and an unbounded permanent cache.

### 2.9 Android — `ContentScale.Fit` produces the same black bars as iOS · CONFIRMED

`StoryCommon.kt:79`: `Image(bmp, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)`.
Same letterboxing as §2.2, against a `Color.Black` box (`StoryViewerView.kt:158`). Same fix
applies (§3, §4.2).

### 2.10 Android — video uses `VideoView`, on a stale premise · CONFIRMED

`StoryCommon.kt:83-84` states:

> No ExoPlayer dependency exists in this app, and VideoView plays a local MP4 with zero new deps.

**That is no longer true.** `apps/android/gradle/libs.versions.toml:78-82` and
`apps/android/app/build.gradle.kts:154-159` add `androidx.media3.exoplayer` and `media3-ui` for
the Clips work. `VideoView` is a `SurfaceView` that punches a hole through the compose hierarchy
(a known source of flicker and black frames on transition), gives no control over resize mode, and
cannot be prepared ahead of time. Media3 `ExoPlayer` + `PlayerView` with `RESIZE_MODE_FIT` gives
aspect control and pre-buffering, and is already in the dependency graph.

### 2.11 Android — the mute toggle silently does nothing mid-story · CONFIRMED (correctness bug)

`StoryCommon.kt:91-97` sets the volume **only inside `setOnPreparedListener`**, which runs once in
the `factory` block. The `update` lambda (`:99-102`) handles `paused` but never re-reads `muted`.
So `onToggleMute` (`StoryViewerView.kt:88`, wired to the icon at `:207-211`) flips the icon and
changes nothing audible until the story changes and a new `VideoView` is constructed.

`AndroidView`'s `factory` is also not re-invoked on `localPath` change in this composition shape —
`view` is `remember { mutableStateOf<VideoView?>(null) }` with no key (`:85`), and the
`DisposableEffect(localPath)` at `:105` stops playback but does not re-run `factory`. *Marked
hypothesis:* whether the surface is actually recycled across stories depends on Compose's
`AndroidView` reuse; it should be tested. Either way the mute bug at `:91-97` is unconditional.

### 2.12 Android — no prefetch depth, no cross-context warm · CONFIRMED

`StoryViewerView.kt:130` prefetches exactly `index + 1` within the current context, with the same
three limitations as iOS §2.6. It also sits inside a `LaunchedEffect(context.authorId, index,
active)` (`:124`), which is **cancelled on every index change** — so a fast tapper cancels each
prefetch before it lands and arrives at a page with nothing warmed. This is precisely the defect
`ClipFullscreenView.swift:130-146` calls out on iOS ("detached from this task because
`.task(id: index)` cancels on every page change") and fixed with `Task.detached`. Android's
stories path never got the same treatment.

### 2.13 Android — press-to-pause and tap fight each other; there is no swipe-down dismiss · CONFIRMED

`StoryViewerView.kt:159-176` registers `detectTapGestures(onPress = …, onTap = …)`. `onPress`
sets `paused = true; chromeVisible = false` **immediately on touch-down**, before the tap/long-press
distinction is made. So *every* tap-to-advance flickers the chrome off and back on, and pauses
the timer for the duration of the touch. WhatsApp only pauses after a hold threshold (~200 ms).

There is also **no swipe-down-to-dismiss on Android** — no `detectVerticalDragGestures` anywhere in
the file. iOS has it (`StoryViewerView.swift:124-129`); Android users can only leave via the
system back button. This is a straight parity gap against both iOS and WhatsApp.

### 2.14 Both — the chrome has no scrim, so white captions and names sit on bright media · CONFIRMED

iOS `StoryViewerView.swift:169-197` (header) and Android `StoryViewerView.kt:198-232` draw white
text and white progress capsules directly over the media with no gradient behind them. On a bright
photo the author name, timestamp and progress bar are illegible. WhatsApp and Signal both use a
top/bottom gradient scrim. This is not a lag issue but it is part of "make it like WhatsApp
status".

### 2.15 iOS — no caption is rendered in the viewer at all · CONFIRMED (parity gap)

`Story.swift:80` carries `caption`, `StoryEngine.swift:196` populates it, and Android renders it
(`StoryViewerView.kt:227-232`). iOS's `StoryContextPlayer` never references `current?.caption` —
`grep` over `StoryViewerView.swift` finds no use. An iOS viewer silently drops the sender's
caption.

---

## 3. How WhatsApp and Signal do it

### 3.1 The letterbox is filled, never black — both Signal platforms

This is the direct answer to "too much black space". Signal composes **two** layers:

Signal-Android, `app/src/main/res/layout/stories_post_fragment.xml:7-19`:

```xml
<ImageView android:id="@+id/blur"  android:layout_width="match_parent"
           android:layout_height="match_parent" android:scaleType="centerCrop" />
<ImageView android:id="@+id/image" android:layout_width="match_parent"
           android:layout_height="match_parent" android:scaleType="fitCenter" />
```

A `centerCrop` blurred backdrop filling the frame, with the true-aspect `fitCenter` image on top.

Signal-iOS does the identical thing in code —
`Signal/src/ViewControllers/HomeView/Stories/Context View/StoryItemMediaView.swift:1029-1039`:

```swift
private func buildBackgroundImageView(thumbnailImage: UIImage) -> UIView {
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFill
    imageView.image = thumbnailImage
    imageView.clipsToBounds = true
    let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    imageView.addSubview(blurView)
```

with the foreground at `:1005` `imageView.contentMode = .scaleAspectFit` and the video player at
`:959` likewise `.scaleAspectFit`. Same pattern at `StoryPageViewController.swift:612-624`.

WhatsApp Status behaves the same way visually: media is fit (never cropped — you always see the
whole photo), and the surrounding area is a blurred, darkened derivative of the media rather than
pure black.

### 3.2 Aspect-ratio-aware framing rather than one fixed layout

Signal-Android picks one of three treatments from the *screen's* aspect ratio —
`StoryDisplay.kt:28-52`:

```kotlin
fun getStoryDisplay(screenWidth: Float, screenHeight: Float): StoryDisplay {
  val aspectRatio = screenWidth / screenHeight
  return when {
    aspectRatio >= LANDSCAPE  -> MEDIUM
    aspectRatio <= LARGE_AR   -> LARGE   // 9:18 and taller
    aspectRatio >= SMALL_AR   -> SMALL   // 9:16 and wider -> content is CROPPED
    else -> MEDIUM
  }
}
```

On a short/wide device (`SMALL`) Signal deliberately **crops to fill** and squares the corners;
on a tall device it fits with rounded corners and puts the reply bar underneath. The takeaway is
not the exact thresholds — it is that "fit and eat the black bars" is never the answer alone.

### 3.3 Prefetch is decoded-at-display-size, and 3 deep, and crosses contexts

Signal-Android `StoryCache.kt:33-67` — note `.priority(Priority.HIGH)`, `.centerInside()` and the
target sized to `StoryDisplay.getStorySize(resources)` (`StoryViewerPageFragment.kt:160`):

```kotlin
requestManager
  .load(DecryptableUri(attachment.uri!!))
  .priority(Priority.HIGH)
  .centerInside()
  .into(StoryCacheTarget(attachment.uri!!, storySize))
```

It prefetches **every attachment in the context at once** (`StoryViewerPageViewModel.kt:100-106`),
not just the next one, and the cache is cleared in `onCleared()` (`:117`) — bounded lifetime,
unlike our unbounded `thumbCache`.

Signal-iOS warms 3 items ahead and **walks into subsequent contexts** to fill the window —
`StoryContextViewController.swift:737-762`:

```swift
private static let subsequentItemsToLoad = 3
...
// If the current context has less than 3 unloaded items, try the next context until we reach the end or the limit
while subsequentItems.count < Self.subsequentItemsToLoad {
    guard let nextContext = self.delegate?.storyContextViewController(self, contextAfter: context) else { break }
    ...
}
subsequentItems.forEach { $0.startAttachmentDownloadIfNecessary() }
```

and it does it on `DispatchQueue.sharedUtility.async` (`:745`) — off the main thread, detached
from the current page's lifetime.

### 3.4 Pager offscreen limit is explicitly bounded

Signal-Android `StoryViewerFragment.kt:89`: `storyPager.offscreenPageLimit = 1`. One page either
side is kept alive; everything else is destroyed. Our iOS `TabView` (§2.7) keeps all of them.

### 3.5 What WhatsApp Status does that we should match, behaviourally

- **Edge-to-edge media.** Media extends under the status bar; the chrome is overlaid on top with a
  gradient scrim, not pushed below the notch.
- **Tap zones**: left ~30 % back, right ~70 % forward. We already match this on both platforms.
- **Hold to pause** with a threshold (not touch-down), chrome fades out, release resumes.
- **Swipe down to dismiss**, with the frame following the finger and scaling slightly before it
  commits — not a binary threshold jump.
- **Swipe up** opens the reply composer (we put reply in a persistent footer instead; acceptable
  divergence, but the footer is what pushes our media up on Android).
- **Segmented progress**, one segment per item, at the very top of the screen inside the status
  bar area. We match this, except ours sits below the safe area.

---

## 4. Recommended fixes

Ordered. Each is independently landable.

### 4.1 iOS — take the viewer edge-to-edge · **critical, 1 line + 1 modifier move**

**Files:** `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift`

Move `.ignoresSafeArea()` off the backdrop (`:28`) and onto the `TabView` / the
`StoryContextPlayer`'s `GeometryReader` content (`:86-117`), so the media fills the physical
screen. Keep the *chrome* inside the safe area by reading `geo.safeAreaInsets` explicitly in the
`VStack` at `:101-110` — replace the hardcoded `.padding(.top, 44)` at `:196` (which is a guess at
the notch height and is wrong on every non-notched and every Dynamic Island device) with the real
inset value.

**Risk:** low. Purely layout. Verify on a notched device, a non-notched device (SE), and iPad
split view.

### 4.2 Both — blurred backdrop instead of black bars · **critical, the "black space" fix**

**Files:** `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift`,
`apps/android/app/src/main/java/com/voiid/app/main/stories/StoryCommon.kt`

Two layers, exactly as Signal does (§3.1):
- **Backdrop:** the same decoded image, `.scaleAspectFill` / `ContentScale.Crop`, heavily blurred
  and darkened, filling the frame.
- **Foreground:** the media at true aspect, `.scaledToFit` / `ContentScale.Fit`, unchanged.

iOS: a `UIVisualEffectView(effect: UIBlurEffect(style: .dark))` over a `.scaleAspectFill`
`UIImageView`, or SwiftUI `.blur(radius: 40)` on a `.scaledToFill().clipped()` copy. Use a
**downsampled** copy for the backdrop (see §4.3) — blurring a full-res image is itself expensive.

Android: a second `Image` with `ContentScale.Crop` plus `Modifier.blur(40.dp)` behind the existing
`ContentScale.Fit` one in `StoryMediaFrame` (`StoryCommon.kt:76-82`).

For **video**, derive the backdrop from the first frame (Android already has
`MediaMetadataRetriever().getFrameAtTime(0)` at `StoryCommon.kt:56`; iOS can use
`AVAssetImageGenerator`), or fall back to a dark neutral rather than pure black.

**E2EE note:** the blur source is the already-decrypted local file. Nothing new crosses the wire.

**Risk:** low-medium. Watch memory — the backdrop must be built from a downsampled bitmap, not a
second full-res decode.

### 4.3 iOS — get the image decode off the main thread and out of `body` · **critical, the "lag" fix**

**Files:** `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift`

`UIImage(contentsOfFile:)` at `:148` runs synchronously on the main thread inside a `@ViewBuilder`,
and re-runs on every `body` evaluation — which the 30 Hz progress tick at `:134` forces 30×/s.

Replace with: an `@State private var image: UIImage?` populated in `loadCurrent()` (`:272-293`)
via `Task.detached`, using `CGImageSourceCreateThumbnailAtIndex` with
`kCGImageSourceThumbnailMaxPixelSize` set to the screen's pixel width so a 12 MP photo is decoded
once, at display size. Body then just renders `if let image`.

Follow the pattern already proven in `ClipsUIKit.swift:110-123` (`.task(id:)` → `@State`, with a
cache in front).

Add a small bounded decoded-image cache (NSCache, count-limited to ~6) so stepping back to a
previous story does not re-decode.

**Risk:** low. Behaviour-preserving; measurable with Instruments (main-thread hitches should drop
to zero on photo stories).

### 4.4 iOS — replace `VideoPlayer` with an `AVPlayerLayer` host and pool the players · **high**

**Files:** `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift`,
`apps/ios/Voiid/Voiid/Main/Clips/ClipFullscreenView.swift` (source of the reusable type)

`VideoPlayer` at `:146-147` letterboxes unconditionally and carries its own control chrome — the
exact defect fixed for Clips. Reuse `ClipPlayerLayerView`
(`ClipFullscreenView.swift:473-492`); promote it out of `ClipFullscreenView.swift` into a shared
file (it is currently `private`), or add a sibling for Stories. Set
`videoGravity = .resizeAspect` and put the §4.2 blurred backdrop behind it.

Then stop building a fresh `AVPlayer` per story (`:285-289`). Introduce a small player pool
keeping the current item and the next one warm, modelled on `ClipPlayerPool`
(`ClipFullscreenView.swift:497-552`) but keyed on story id. Prepare the next story's
`AVPlayerItem` during the current story's dwell so a forward tap has a warm first frame instead
of a spinner on black.

**Risk:** medium. Player lifecycle is the easiest thing to leak; make sure `stop()` (`:268-270`)
and the context-swipe path both release. Test: a context with 5 videos, tap through fast, then
swipe between authors; watch for audio from a page you have left.

### 4.5 Both — real prefetch: depth 3, cross-context, detached, and decoded · **high**

**Files:** `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift`,
`apps/ios/Voiid/Voiid/Networking/StoryEngine.swift`,
`apps/android/app/src/main/java/com/voiid/app/main/stories/StoryViewerView.kt`,
`apps/android/app/src/main/java/com/voiid/app/model/StoriesStore.kt`

Change three things at once (they are the same defect wearing three hats — §2.6, §2.12):

1. **Depth 3, not 1**, matching Signal's `subsequentItemsToLoad = 3`
   (`StoryContextViewController.swift:737`).
2. **Cross the context boundary.** When fewer than 3 items remain in the current author's list,
   pull the first items of the *next* author into the window
   (Signal: `StoryContextViewController.swift:745-762`). This is what removes the cold start on
   every horizontal swipe.
3. **Detach from the page's task scope.** iOS: `Task.detached(priority: .utility)` with a
   `withTaskGroup` so the items are fetched **in parallel**, not serially — the exact remedy
   already applied at `ClipFullscreenView.swift:136-146`. Android: launch on the store's
   `viewModelScope`, not inside `LaunchedEffect(context.authorId, index, active)`
   (`StoryViewerView.kt:124-131`), which is cancelled on every index change.
4. **Warm the decode, not just the bytes.** Feed the prefetched paths through the same
   downsampled-decode + cache introduced in §4.3 / §4.6, so arriving at the item is a cache hit.

Keep `StoryEngine.autoDownloadEligible`'s throttle intent (`StoryEngine.swift:339-345`) — do not
let an in-viewer prefetch storm start 20 concurrent R2 downloads.

**Risk:** medium. Concurrency; and prefetching more bytes on cellular. Cap concurrency to ~3 and
consider gating cross-context prefetch on Wi-Fi.

### 4.6 Android — downsample bitmaps and bound the cache · **high (OOM risk)**

**Files:** `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryCommon.kt`

`BitmapFactory.decodeFile(p)` at `:58` decodes at full source resolution. Do a two-pass decode:
`inJustDecodeBounds = true` to read dimensions, compute `inSampleSize` against the display size,
then decode for real. For the tray thumbnails the target is ~52 dp; for the viewer it is the
screen size — so `rememberStoryThumbnail` needs a **target-size parameter** and the cache key must
include it, or the tray's tiny bitmap will be reused (blurry) in the viewer.

Replace the unbounded `HashMap` at `:40` with an `LruCache` sized from
`Runtime.getRuntime().maxMemory() / 8`, and clear it when the viewer closes (Signal clears in
`StoryViewerPageViewModel.onCleared()`, `:117`).

**Risk:** low-medium. Getting the cache key wrong yields blurry full-screen images — test the
tray-then-viewer sequence explicitly.

### 4.7 Android — move video to Media3 ExoPlayer · **medium**

**Files:** `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryCommon.kt`

The premise in the comment at `:83-84` ("No ExoPlayer dependency exists in this app") is stale —
`libs.versions.toml:78-82` and `build.gradle.kts:154-159` already ship `media3-exoplayer` and
`media3-ui`. Replace `VideoView` with `ExoPlayer` + `PlayerView`, `resizeMode =
RESIZE_MODE_FIT`, `useController = false`, and `playWhenReady` driven by the `paused` flag.

This also fixes §2.11 as a side effect: bind `volume` in the `update` lambda so the mute toggle
takes effect immediately. **If ExoPlayer migration is deferred, fix the mute bug on its own** —
add `vv.setVolume()` handling to the `update` block at `StoryCommon.kt:99-102` (note `VideoView`
has no public `setVolume`; it requires capturing the `MediaPlayer` from
`setOnPreparedListener` into a `remember`ed ref — one more reason to just migrate).

**Risk:** medium. New player lifecycle; must release in `DisposableEffect`.

### 4.8 Android — swipe-down dismiss, and fix the press/tap conflict · **medium**

**Files:** `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryViewerView.kt`

Add `detectVerticalDragGestures` (or a `draggable` on the Y axis) to the root `Box` at `:157-176`
that translates the page with the finger and calls `onClose()` past a threshold — matching iOS's
`:124-129` and WhatsApp's behaviour. Prefer following the finger over a binary threshold.

Separately, in `detectTapGestures` at `:161-165`, do not pause on touch-down. Await a
`viewConfiguration.longPressTimeoutMillis` (~200 ms in a `withTimeoutOrNull` around
`tryAwaitRelease()`) before setting `paused = true; chromeVisible = false`, so an ordinary
advance-tap does not flicker the chrome.

**Risk:** medium. Gesture ordering with the enclosing `HorizontalPager` — a vertical drag must not
steal the horizontal context swipe. Test diagonal drags.

### 4.9 Both — gradient scrims behind the chrome · **medium (legibility)**

**Files:** `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift`,
`apps/android/app/src/main/java/com/voiid/app/main/stories/StoryViewerView.kt`

Add a top scrim (black → clear, ~140 pt tall) behind the progress bar + header, and a bottom scrim
behind the footer, on both platforms. Without them white text on a bright photo is unreadable
(§2.14).

**Risk:** trivial.

### 4.10 iOS — render the caption · **low (parity)**

**Files:** `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift`

`current?.caption` is populated (`StoryEngine.swift:196`) and rendered on Android
(`StoryViewerView.kt:227-232`) but never shown on iOS. Add it above the footer, inside the bottom
scrim from §4.9, matching Android's placement.

**Risk:** trivial.

### 4.11 iOS — stop building every context page up front · **low**

**Files:** `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift`

`TabView` + `ForEach` (`:29-39`) constructs one `StoryContextPlayer` per author, each with its own
autoconnected 30 Hz `Timer.publish` (`:78`). Either (a) move the tick out of the per-page view
into the parent, driven only for the active page, or (b) switch to
`ScrollView(.horizontal) { LazyHStack { … } }.scrollTargetBehavior(.paging)` — the same
construction Clips adopted for exactly this reason (`ClipFullscreenView.swift:82-100`) — so pages
are built lazily. (b) also gets you a bounded live-page window, matching Signal's
`offscreenPageLimit = 1` (`StoryViewerFragment.kt:89`).

**Risk:** low-medium. Option (b) changes the paging feel; verify the swipe still snaps per-author.

### 4.12 Optional / protocol — a blurhash in `StoryEnvelope` · **defer**

Signal shows a blurhash **before the media downloads**, so the first paint is never a spinner on
black (`StoryItemMediaView.swift:1014-1027`). We cannot copy this without adding a `blurHash`
field to `StoryEnvelope` (`Story.swift:23-44` / `Story.kt` `StoryEnvelope`). That is legitimate —
the envelope is E2EE plaintext, so the hash would be encrypted like everything else and the server
would never see it — but it is a **wire change on a deliver-once feed**, and both platforms have
a documented history of exactly this class of field-optionality bug (`Story.swift:24-31`,
`Story.kt` `caption` comment). If it is done: make the field **optional on both sides** (`String?`
on iOS, `String? = null` on Android), never a defaulted non-null, or Android's
`encodeDefaults = false` / iOS's `keyNotFound` will silently drop stories again.

**Recommendation: do not do this now.** §4.2 (blur from the downloaded media) plus §4.5 (prefetch
so it is already downloaded) covers the same user-visible ground without touching the protocol.

---

## 5. Verification bar

Layout and lag claims must be confirmed on device, not in a simulator:

- **iOS, Instruments Time Profiler:** open a context with 3 large photo stories. Before §4.3, main
  thread shows repeated `UIImage(contentsOfFile:)` / `CGImageSource` decode work during dwell.
  After, zero.
- **iOS, notched + non-notched + iPad:** no black band above or below the media on any of them.
- **Android, Memory Profiler:** view 10 photo stories. Before §4.6, heap climbs monotonically
  (`thumbCache` never evicts). After, it plateaus.
- **Android:** tap the mute icon mid-video — audio must change immediately (§2.11).
- **Android:** swipe down anywhere on the viewer — it must dismiss (§4.8).
- **Both:** step forward through a 5-item context; no spinner should appear after the first item
  (§4.5).
- **Both:** swipe from the last story of author A to author B; first frame should be warm, not a
  spinner (§4.5 cross-context prefetch).
- **E2EE regression:** post iOS→Android and Android→iOS after any change and confirm arrival. The
  feed is deliver-once; a regression here is permanent per-story
  (`StoryEngine.swift:111-112`, `:120-128`).
