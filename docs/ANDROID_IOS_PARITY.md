# VOIID — Android ↔ iOS UI Parity

> iOS (SwiftUI) is the reference; Android (Compose) must match it. This tracks the
> cross-platform audit: what's fixed and what remains. Items best verified on a
> device/emulator (animations, gestures, ripples) since they're visual/feel.
>
> Last updated: 2026-06-17

## Design-system foundations — ✅ verified matching
- Colors (`VoiidColor`): identical tokens, fixed light (non-adaptive) on both → dark-mode is a non-issue.
- Spacing/radius: identical scale.
- Type scale + weights: identical (34/22/17/16/15/13/12). **Font face differs by design:** iOS = SF Pro Rounded, Android = Nunito (SF Pro isn't licensed for Android — see CHECKLIST blocker #4). Urbanist logo wordmark matches.
- Shared components (primary button, text field, toggle, soft-press, avatar) are faithful ports.

## Fixed this pass
- **Terms checkbox** (the reported "turns white" bug): removed the soft-press scale/alpha that made it look like it faded; fill now springs plum→ via `animateColorAsState`, check fades in. Continue button made plain (no press feedback) to match iOS.
- **OTP** active-circle spring was too fast (`StiffnessMedium`→`StiffnessMediumLow`) to match iOS response 0.3.
- **CreateProfile**: removed extra success haptic on photo pick (iOS has none); camera icon 16→14; avatar placeholder wordmark sized up to read like the iOS image mark.
- **Extra Material ripples** removed (iOS shows none): OTP "Resend code", country picker rows / close / search-clear. Added a reusable `Modifier.noRippleClickable` in `ui/components/Components.kt`.
- **Splash→Terms handoff**: splash now slides up while fading (connected feel) instead of a flat cross-fade.
- **ChatDetail message menu**: was opening on a single TAP — fixed to **long-press** (+ rigid haptic) via `combinedClickable`; tap only toggles selection in selection mode. (Functional regression.)
- **AIChatView** input bar: added 80dp bottom padding so it clears the floating tab bar.

## Remaining punch-list (verify on device, then fix)

### High (functional / missing)
- [ ] **ChatDetail** — tapping an image bubble should open a fullscreen black-bg image viewer (iOS has it; Android image bubble isn't clickable / no viewer).
- [ ] **ChatDetail** — send⇄voice button swap should animate (scale+opacity spring); Android swaps instantly.
- [ ] **ChatsHome grid** — pick-up long-press should arm at ~0.15s (Android uses default ~500ms); add spring reorder/pick-up animation (cards currently snap).
- [ ] **RootTabView** — tab bar should hide/show with move+opacity transition (Android always shows it).
- [ ] **GroupInfo** member sheet — add the "Message" action (dropped on Android).
- [ ] **Clips** feed + comment rows — pass the per-clip author photo to `VoiidAvatar` (currently omitted).
- [ ] **MessageInfoSheet / SharedMediaSheet** — add toolbar "Done"; **EmojiPickerSheet** — add "Cancel" (Android relies on swipe-dismiss only).

### Medium (styling / animation / ripples)
- [ ] Replace remaining bare `.clickable` ripples with `noRippleClickable`/`softClickable` across ChatDetail header & controls, ClipFullscreen, ChatsHome hamburger, GroupInfo/Contact rows, ForwardSheet rows.
- [ ] **AIChatView** header + input bar should use a translucent/blur background (iOS `.ultraThinMaterial`); currently solid.
- [ ] Message bubble / reaction / reply-preview enter transitions (iOS uses scale+opacity / move-in); Android has none.
- [ ] **RootTabView** active-pill alignment behind the icon.
- [ ] Icon glyph corrections: GroupInfo mute = bell.slash, report = hand.raised (Android uses Block for both); MessageInfo delivered = checkmark.circle.
- [ ] **EmojiPicker** sticky category headers; **ClipFullscreen** action label font (11 medium) + comment divider opacity.
- [ ] **CallScreens** voice 1:1 should show the contact photo; remove the extra fieldFill circle.

### Low
- SF Symbol → Material icon swaps, minor size/spacing/shadow deltas, feed bottom-padding so last items clear the nav bar. Full per-screen detail in the audit (see git history / agent output).

## Note on verification
The Android SDK isn't installed in the dev environment used for these edits, so changes were verified by import/usage cross-check, not a Gradle compile. **Run `./gradlew :app:assembleDebug` on a machine with the SDK** (and add `local.properties` with `sdk.dir=`) before relying on them; eyeball the animations/gestures on an emulator.
