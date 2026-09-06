# 09 — Motion, gestures, and accessibility

Baseline: `a2e24e5` · 2026-09-05 · All tasks TODO; fixes specified, not implemented.

Use existing component boundaries and motion conventions. Gesture-driven transitions must remain interruptible. The targets below are native parameters, not CSS curves blindly copied into Compose/SwiftUI.

## U01 — Await Android sheet dismissal before removing it

**Priority:** P1 · **Evidence:** Confirmed · **Dependencies:** None

**Location:** `apps/android/app/src/main/java/com/voiid/app/ui/components/VoiidSheet.kt:256`, `:284`.

Current code starts `animateTo(offscreenAnchor, tween(durationMillis = 220))` in a separate remembered scope, then immediately invokes `onHidden()`. The dialog is removed before its dismissal animation finishes.

**Fix:** make dismissal a suspendable operation owned by one transition job or call `onHidden` only from the successful animation completion. Ensure cancellation/reopening does not invoke a stale completion. Keep ordinary dismissal 220ms, and reduced-motion opacity 140ms. Preserve `onDismiss` exactly once. Do not delay input merely to let an animation finish.

**Done when:** frame-by-frame recording shows the full exit; back, scrim, drag and programmatic dismissal each invoke the callback once; reopening during exit reverses cleanly; disposal cancels work; reduced motion fades without sliding. Add a controlled-clock Compose test around the callback timing.

## U02 — Correct sheet initial detents and entrance position

**Priority:** P1 · **Evidence:** Confirmed · **Dependencies:** U01

**Location:** same `VoiidSheet.kt:204`, `:216`, `:231`, `:258`, `:275`.

Anchors are sorted while `initialDetentIndex` still uses caller ordering. `[Medium, Large]` index 0 can therefore map to Large. The initial animation starts at `minAnchor`, not the offscreen anchor, so entrance can begin at the final raised position. Measurement and density changes need retargeting.

**Fix:** preserve detent identity → anchor mapping separately from sorted snap candidates. Once measured, initialize at `offscreenAnchor`, then animate to the selected detent. Recompute bounds on content, IME, density and container changes. Carry gesture release velocity into the existing spring (`0.86` damping, `380` stiffness), and preserve current presentation position when interrupted. Retain small resistance at bounds; do not create a new motion vocabulary.

**Done when:** mixed detent orders select the requested identity, content-sized sheets open reliably, large text/rotation/keyboard do not jump, repeated drag/reverse is continuous, and reduced motion positions immediately with 140ms fade feedback.

## U03 — Restore system Back in custom dialogs

**Priority:** P1 · **Evidence:** Confirmed · **Dependencies:** None

**Location:** `ui/components/VoiidDialog.kt:100`, `:105`, `:246` under Android source root.

Both dialog variants disable `dismissOnBackPress` without a compensating BackHandler. The public `backDismissable` option cannot produce the intended ordinary Back dismissal.

**Fix:** enable Dialog's native Back handling according to the option, or install one explicit lifecycle-aware handler. Preserve deliberate busy/non-dismissible states and provide a visible recovery/close path for errors. Verify predictive Back compatibility with the actual Activity/Compose versions. Keep scrim behavior separate.

**Done when:** hardware/gesture Back, keyboard Escape where supported, scrim and close button follow the configured policy; busy operations do not trap users indefinitely. TalkBack focus returns to the opener.

## U04 — Finish the photo viewer's gesture lifecycle

**Priority:** P1 · **Evidence:** Confirmed · **Dependencies:** None

**Location:** `ui/components/VoiidPhotoViewer.kt:99`, `:110`, `:117`, `:152`.

Drag changes `dragY` but has no release handler to dismiss or settle. Zoomed panning is unbounded; double-tap changes scale directly. The Close icon is a 28dp pointer-only target, without a semantic click action.

**Fix:** use explicit gesture start/update/end/cancel state with release velocity and distance thresholds. At scale 1, dismiss after a downward drag beyond 25% of viewport height or velocity above 1900dp/s; otherwise spring back (0.86/380). Convert velocities by density and tune on devices. Clamp pan to image/viewport bounds; reset offsets when returning to scale 1. Double-tap zoom should be anchored to the tap and interruptible, using a short spring. Replace Close with a labeled semantic IconButton and ≥48dp hit region, honoring system insets.

**Done when:** partial drags settle, committed drags close once, pinch/pan never loses the image, cancellation restores a valid state, and TalkBack/keyboard can close. Reduced motion keeps direct touch tracking but removes animated zoom travel/overshoot.

## U05 — Remove stale iOS tab timers and honor reduced motion

**Priority:** P2 · **Evidence:** Confirmed timer/policy gap · **Dependencies:** None

**Location:** `apps/ios/Voiid/Voiid/Main/RootTabView.swift:439`, `:446`, `:466`, `:490`, `:558`.

Uncancelled `DispatchQueue.main.asyncAfter` releases shared tab stretch state. Rapid taps leave earlier callbacks able to reset newer transitions. Root tab motion has no explicit reduced-motion branch despite extensive custom spring/scale/symbol movement.

**Fix:** replace delayed callbacks with a cancellable transition owner or supported completion mechanism bound to the current selection generation. Preserve the existing 0.32s/0.9 selection spring and restrained indicator personality. For reduced motion, change selection immediately and use a 140ms opacity/color response; remove stretch and icon overshoot. Keep selection semantics and tab scroll-to-visible behavior.

**Done when:** rapid A→B→C→A taps never let an old callback change the latest transition; no delayed work survives disappearance; VoiceOver activation and Reduce Motion show correct state without spatial effects. Inspect at 10% playback speed.

## U06 — Make native typography scale and materials stay legible

**Priority:** P2 · **Evidence:** Confirmed fixed-size tokens; screen impact requires device audit · **Dependencies:** G02

**Location:** `apps/ios/Voiid/Voiid/DesignSystem/Theme.swift:203` uses `.system(size:)`; `Main/RootTabView.swift:517` uses a 10pt fixed label with shrinking. No explicit `accessibilityReduceTransparency` read was found in first-party iOS sources; native materials may already adapt, so this is a custom-surface verification gap rather than proof every material ignores the setting.

**Fix:** use semantic Dynamic Type styles or scaled metrics for custom sizes and adapt layout rather than shrinking meaningful text. Provide platform-specific minimum hit regions (44pt iOS, 48dp Android), semantic names/roles/state, focus restoration, non-color selection cues, and logical reading order. Centralize motion/transparency/contrast policy for custom components; verify OS-managed materials before adding overrides. Audit both theme modes and long/localized text.

**Done when:** accessibility text sizes, Android 200% font size, VoiceOver/TalkBack, reduced motion, increased contrast and reduced transparency keep primary flows operable with no clipped action text. Record affected screens and screenshots; do not mark all UI accessible from a token change alone.

**Additive opportunities after defects:** animate a sheet from its triggering control where spatially appropriate; use a brief opacity change for offline→connected status; reserve game-completion celebration for occasional outcomes. These are optional product experiments, not confirmed missing-feature bugs. Never delay message sending, keyboard input or navigation for decoration.
