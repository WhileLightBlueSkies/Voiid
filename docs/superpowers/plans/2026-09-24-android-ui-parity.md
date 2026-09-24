# Android UI Parity Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement this plan task by task. Steps use checkboxes for tracking.

**Goal:** Make the native Android app match the shipped iOS app's available features, colors, navigation, sheets, and gestures.

**Architecture:** iOS SwiftUI is the reference. Android remains Jetpack Compose and uses the existing Voiid design tokens, sheet, dialog, modal navigator, and gesture components. Compare only shipped routes and working features; do not port iOS placeholders.

**Tech Stack:** SwiftUI reference, Kotlin/Compose implementation, Gradle, Rust UniFFI Android bindings.

**Spec:** User request in this task, and the existing `Android_iOS_Parity_Gaps.xlsx` as a historical inventory. Recheck every finding against current `origin/main` before implementing it.

## Global Constraints

- Change Android source and shared Android build inputs only; do not edit iOS source.
- Preserve Android native rendering, platform accessibility, Back, IME, and system insets.
- Match iOS feature behavior first, then visual tokens and motion.
- Every modal must close safely after its exit transition and support reduced motion.

## Review Focus

- Pulling a sheet down while its inner list scrolls should never strand or dismiss it unexpectedly.
- Pinch, pan, swipe, and Back on image media should not compete for the same gesture.
- Destructive actions should require the same confirmation and busy behavior as iOS.
- Dark theme text must remain legible when matching iOS fills.
- Network failures should show retry states instead of looking like empty content.

---

### Task 1: Restore a verifiable Android baseline

**Files:** Android ignored UniFFI/JNI outputs and local build configuration.

- [x] Regenerate Kotlin and JNI bindings from current Rust source.
- [x] Compile debug Kotlin and run Android unit tests; the backup policy inventory required two newly added stores to be classified.

### Task 2: Shared visual and gesture system

**Files:** `apps/android/app/src/main/java/com/voiid/app/ui/theme/*`, `ui/components/*`.

- [x] Compare every semantic color value to current iOS theme; Android palette values already match.
- [ ] Verify custom sheet detents, nested scroll, fling, IME, Back, and reduced motion on device.
- [ ] Verify photo viewer pinch/pan bounds, release velocity, gallery swipe, and loading/error states on device.
- [x] Migrate remaining stock Material alerts and key branded sheets. Android source now has no `AlertDialog` or `ModalBottomSheet` call sites.
- [x] Block the underlying tab and prior screen while any full-screen game or other root cover is entering, open, or exiting.

### Task 3: Main routes and feature parity

**Files:** Android `main`, `onboarding`, `stories`, `clips`, `games` screens and stores.

- [ ] Recheck shipped iOS routes against Android and implement every missing reachable action.
- [ ] Match confirmation, retry, empty/error, refresh, and Back behavior per route.
- [ ] Match screen hierarchy, layout, icons, haptics, and motion to iOS in light and dark.

### Task 4: Verification

- [x] Build Android debug APK with current bindings.
- [x] Run Android unit tests and smoke check onboarding legal sheet open, drag dismiss, and scrim dismiss on emulator.
- [ ] Compare paired iOS and Android captures for each shipped flow on devices or emulators.
- [ ] Record any hardware-only verification limits without claiming full parity.

Current verification limit: the available Android emulator has no signed-in account, so game,
call, community, and event routes cannot be exercised end to end there. The onboarding legal
sheet was smoke checked for drag and scrim dismissal. This plan remains open until signed-in
device flows and paired iOS captures are checked.
