# Android: dragging a fullscreen photo down doesn't close it

> **Date:** 16 Sep 2026
> **Baseline:** `main` at `9fc79f3`
> **Reported:** open an image, drag it down to dismiss (as in WhatsApp). The image follows your finger but never closes — you have to tap the X.
> **Status: reproduced in source. Single root cause, one file, small fix.**
> **Related:** [NAVIGATION_AUDIT_2026-09-16.md](NAVIGATION_AUDIT_2026-09-16.md) — same theme of "back/dismiss doesn't complete" on Android.

---

## Summary

The drag is implemented. The **release** is not.

`VoiidPhotoViewer` tracks your finger and moves the photo, fades the backdrop and dims the image. But nothing runs when you lift your finger. There is no gesture-end handler, so the viewer never asks "did they drag far enough to close?" — it just leaves the photo wherever the finger left it.

That produces exactly what you described: the image drags, stays there, and only the X closes it. It is also *worse* than not having the gesture, because a half-dragged photo stays stuck off-centre with a faded backdrop until you tap X.

The file even documents the intended behaviour it does not implement: *"past the threshold (or with enough velocity) it releases closed"* ([VoiidPhotoViewer.kt:44-45](../../apps/android/app/src/main/java/com/voiid/app/ui/components/VoiidPhotoViewer.kt#L44-L45)). The two constants for that decision exist and **are never read by any code** ([VoiidPhotoViewer.kt:52-55](../../apps/android/app/src/main/java/com/voiid/app/ui/components/VoiidPhotoViewer.kt#L52-L55)).

iOS does this correctly ([ChatMediaViewer.swift:141-155](../../apps/ios/Voiid/Voiid/Main/Media/ChatMediaViewer.swift#L141-L155)) and is the reference for the fix.

**Affects:** every fullscreen photo on Android — chat images ([ChatUI.kt:412](../../apps/android/app/src/main/java/com/voiid/app/main/ChatUI.kt#L412)) and profile/group photos ([Components.kt:384](../../apps/android/app/src/main/java/com/voiid/app/ui/components/Components.kt#L384)), since both use this one viewer.

---

## Findings

| ID | Sev | Issue |
|---|---|---|
| [IV-01](#iv-01) | P1 | No gesture-end handler: the drag never decides to close |
| [IV-02](#iv-02) | P1 | A released drag doesn't spring back either — the photo stays stuck off-centre |
| [IV-03](#iv-02) | P2 | `detectTransformGestures` is the wrong gesture detector for this job |
| [IV-04](#iv-04) | P2 | Drag can start mid-pinch and while zoomed-in panning |
| [IV-05](#iv-05) | P2 | No movement follows the finger 1:1 — no scale-down, no horizontal tracking |
| [IV-06](#iv-06) | P3 | Tap-to-close conflicts with the drag; a tiny drag then a tap does nothing |
| [IV-07](#iv-07) | P3 | Video fullscreen has no drag-to-dismiss at all |

---

<a id="iv-01"></a>
### IV-01 · P1 · The drag never decides to close (root cause)

**The code.** The whole gesture lives in one `detectTransformGestures` block:

```kotlin
detectTransformGestures { centroid, pan, zoom, _ ->
    if (image == null) return@detectTransformGestures
    if (zoom != 1f) {
        …pinch zoom…
    } else if (scale > 1f) {
        offset += pan
    } else {
        // At rest scale, a downward drag dismisses; upward drag rubber-bands lightly.
        dragY = (dragY + pan.y).coerceAtLeast(-60f)
    }
}
```
[VoiidPhotoViewer.kt:99-113](../../apps/android/app/src/main/java/com/voiid/app/ui/components/VoiidPhotoViewer.kt#L99-L113)

`dragY` moves the photo and fades the background ([VoiidPhotoViewer.kt:96](../../apps/android/app/src/main/java/com/voiid/app/ui/components/VoiidPhotoViewer.kt#L96), [VoiidPhotoViewer.kt:140-141](../../apps/android/app/src/main/java/com/voiid/app/ui/components/VoiidPhotoViewer.kt#L140-L141)). The comment says "a downward drag dismisses" — but the block only *accumulates* `dragY`. `onClose` is never called from it.

**Why it can't work.** `detectTransformGestures` reports movement only. It has no end callback, so there is no moment at which the code can evaluate the release. The two thresholds written for that decision are dead constants:

```kotlin
const val DISMISS_TRAVEL_FRACTION: Float = 0.22f
const val DISMISS_FLING: Float = 1400f
```
[VoiidPhotoViewer.kt:52-55](../../apps/android/app/src/main/java/com/voiid/app/ui/components/VoiidPhotoViewer.kt#L52-L55)

Searching the app for either name returns only these two declarations. Nothing reads them. The feature was designed and half-built.

---

<a id="iv-02"></a>
### IV-02 · P1 · A released drag doesn't spring back

Because there is no end handler, there is also no "snap back" path. `dragY` keeps whatever value the finger left it at, so a short drag that *shouldn't* close leaves the photo hanging off-centre over a partly-faded backdrop, indefinitely.

Every other viewer of this kind returns the photo to centre when the drag is too small. This is the second half of the same missing code, and it is what makes the current behaviour feel broken rather than merely unfinished.

---

<a id="iv-04"></a>
### IV-04 · P2 · The drag can begin in the wrong situations

Two gaps in the `else` branch that accumulates `dragY`:

1. **Mid-pinch.** The branch runs whenever `zoom == 1f` on that event. During a two-finger pinch there are frames with no scale change but plenty of vertical movement, so a pinch can leak into a dismiss drag.
2. **Direction.** Any vertical movement counts. There is no check that the gesture is predominantly vertical, so a mostly-horizontal swipe also moves the photo down.

iOS guards both: it requires the zoom scale to be at rest and the gesture to be downward and steeper than horizontal before the pan may begin ([ChatMediaViewer.swift:125-130](../../apps/ios/Voiid/Voiid/Main/Media/ChatMediaViewer.swift#L125-L130)).

---

<a id="iv-05"></a>
### IV-05 · P2 · The photo doesn't move like the thing you're dragging

Today the photo only translates vertically and fades. Two pieces of the familiar interaction are missing:

- **No shrink.** In WhatsApp (and iOS Photos) the image scales down as it falls, which is what makes it read as "being put away".
- **No horizontal tracking.** `pan.x` is discarded at rest scale, so the photo slides straight down even as your finger moves sideways, breaking the sense of direct manipulation.

Worth adding with the fix, since they are a few lines once an end handler exists.

---

<a id="iv-06"></a>
### IV-06 · P3 · Tap-to-close is blocked after any drag

```kotlin
onTap = { if (dragY == 0f && scale == 1f) onClose() },
```
[VoiidPhotoViewer.kt:123](../../apps/android/app/src/main/java/com/voiid/app/ui/components/VoiidPhotoViewer.kt#L123)

A single tap closes the viewer only when `dragY` is exactly zero. After any drag — including a 2-pixel one that never reset — tapping the photo does nothing, which is the state a user reaches straight after an unsuccessful drag attempt. Fixing IV-02 (reset to 0 on release) resolves this too.

Also worth reviewing: tap-anywhere-to-close is unusual for a photo viewer, and it can fire when the user meant to reveal chrome. Separate decision.

---

<a id="iv-07"></a>
### IV-07 · P3 · Fullscreen video has no drag-to-dismiss

`ChatVideoViewer` is a separate `Dialog` with a close button and no gestures at all ([MediaViews.kt:183-216](../../apps/android/app/src/main/java/com/voiid/app/main/MediaViews.kt#L183-L216)). Once photos are fixed, video will be the odd one out.

---

## How iOS does it (the reference for the fix)

```swift
case .ended, .cancelled, .failed:
    if gesture.state == .ended && (distance > 120 || (distance > 24 && gesture.velocity(in: view).y > 850)) {
        onClose()
    } else {
        UIView.animate(…)   // spring back to centre
    }
```
[ChatMediaViewer.swift:141-155](../../apps/ios/Voiid/Voiid/Main/Media/ChatMediaViewer.swift#L141-L155)

Three rules worth copying exactly, so both platforms feel the same:
1. **Distance OR velocity closes** — a long slow drag *or* a short fast flick.
2. **Anything else springs back** to centre.
3. **The gesture only starts** when the photo is not zoomed and the movement is downward and steeper than sideways.

---

## The fix

Replace `detectTransformGestures` with a detector that reports the end of the gesture. The straightforward shape:

- Keep a separate `pointerInput` for **pinch/zoom** (`detectTransformGestures`, active only when zoomed or when two fingers are down).
- Add a `pointerInput` for **dismiss** using `detectVerticalDragGestures`, which provides `onDragEnd` and `onDragCancel`.

In `onDragEnd`, apply the iOS rule using the constants that already exist:

```kotlin
val threshold = size.height * VoiidPhotoViewerDefaults.DISMISS_TRAVEL_FRACTION
if (dragY > threshold || velocityY > VoiidPhotoViewerDefaults.DISMISS_FLING) onClose()
else animate dragY back to 0f   // spring, or snap when reduce-motion is on
```

Guards to add at the same time (IV-04): only start when `scale == 1f`, only when the drag is downward, and only when vertical movement exceeds horizontal.

Polish worth including (IV-05): scale the photo down slightly as `dragY` grows (about 1.0 → 0.85 at the threshold) and let it track `pan.x` too.

**Scope:** one file, roughly 40 lines. It fixes chat photos and profile photos together, because both go through this viewer.

**Reduce motion** is already read in this file ([VoiidPhotoViewer.kt:65](../../apps/android/app/src/main/java/com/voiid/app/ui/components/VoiidPhotoViewer.kt#L65)) — keep the gesture (it is direct manipulation) and make the spring-back a snap, which is what the file's own header promises.

---

## Decisions needed

1. **Close threshold:** keep the written 22% of screen height, or match iOS's 120 px? (They differ; 22% is roughly 190 px on a typical phone, so today's constant is stricter than iOS.)
2. **Shrink while dragging** (IV-05): yes or no? WhatsApp and iOS Photos both do it.
3. **Tap-to-close** (IV-06): keep tap-anywhere-to-close, or require the X so a tap can toggle chrome instead?
4. **Video** (IV-07): add the same gesture now, or leave it for later?
5. **Upward drag:** currently rubber-bands slightly and can never close. Keep it downward-only (recommended, matches WhatsApp), or dismiss in both directions (iOS Photos behaviour)?

---

## What this audit checked

**Read in full:** `VoiidPhotoViewer.kt` (all 165 lines), both of its call sites, `MediaViews.kt`, and the iOS `ChatMediaViewer.swift` gesture code.

**Verified:** that `DISMISS_TRAVEL_FRACTION` and `DISMISS_FLING` are referenced nowhere outside their declaration, and that this one viewer backs every fullscreen photo on Android.

**Not done:** the app was not run. The behaviour is read from source, and it matches your description exactly: the drag moves the photo, and nothing acts on the release.
