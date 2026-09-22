# iOS ↔ Android UI parity check — 23 Sep 2026

iOS (SwiftUI) is the reference. This is what Android (Compose) is still missing, checked
against the code on `web/landing-redesign` at `d9c10301` plus tonight's face-filter work.
Every row below was confirmed in source, not copied from an earlier audit.

**Scale.** iOS: 357 Swift files, ~118.6k lines. Android: 327 Kotlin files, ~98.6k lines.
Android has most screens. What it lacks is a handful of whole features and a lot of polish:
blur, context menus, pull-to-refresh and hero headers.

> **Correction to `docs/MASTER_PARITY_AUDIT_REPORT.md` (22 Sep).** Its blockers #1 and #2
> are out of date. Android's Chats home already has the persistent **New chat** pill in the
> title row (`ChatsHomeView.kt:1087`, `:1599`), not only in the empty state. Blocker #7's
> "category pills" could not be found on iOS either. Re-check that report's rows before
> working from it.

---

## 1. Tonight: face filters on every camera

| Camera | iOS before | iOS now | Android before | Android now |
|---|---|---|---|---|
| Clips recorder | Filters (text pills) | **Round lens rail** (shared) | Filters (emoji pills) | **Round lens rail** (shared) |
| Moments / Story camera | No filters | **Filters, photo + video** | No filters | **Filters on photos** |
| Chat camera | System picker, no filters | **Voiid camera + filters** | System camera intent | **Voiid camera + filters** |
| Profile photo camera | System picker | **Voiid camera, selfie lens, square crop + filters** | System thumbnail intent (~200 px!) | **Voiid camera, selfie lens, square crop + filters** |

What changed:

- **Shared picker.** `FaceLensRail` is in `apps/ios/.../Main/Camera/FaceLensRail.swift` and
  `apps/android/.../main/camera/FaceFilterKit.kt`. It's a carousel of round gradient lenses.
  The selected lens grows, gets a white ring and centres itself, and its name floats above.
  The gradient colours are the same on both platforms.
- **iOS** `StoryCameraView` now runs on `ClipCameraController`, the clips engine. Photos are
  taken from the processed frame (`captureStill`), so the filter is in the photo. Videos
  have the filter burned in at capture. Photo-only modes skip the microphone, so iOS doesn't
  show the orange recording dot.
- **Android** `StoryCameraView` rebinds CameraX when a filter is switched on or off.
  - Filter on: Preview + ImageAnalysis (+ Video). The photo comes from the preview bitmap
    with the sprites drawn on top (`captureFilteredStill`).
  - Filter off: Preview + full-resolution ImageCapture (+ Video), same as before.
  - `VoiidPhotoCameraDialog` replaces the system intents in chat and on the profile screen.

### Remaining face-filter gap (Android)

- **Android videos don't include the filter**, in clips and in Moments. On Android the
  sprites are a Compose overlay drawn over the preview, and CameraX records the clean
  stream. iOS writes the sprites into each frame with `AVAssetWriter`.
  **Fix:** upgrade CameraX to 1.4+ and add a `CameraEffect` (media3 `Media3Effect` or an
  `OverlayEffect`) that draws the same `ClipFaceArt` layers into the video surface. That is
  the only change needed. The detector and art are already shared.
- Switching the filter on or off in the Android Story camera briefly re-binds the camera
  (one blank frame). That's expected. An `OverlayEffect` would remove the rebind as well.

---

## 2. Missing features on Android (whole screens)

| # | Feature | iOS | Android today | What to do |
|---|---|---|---|---|
| 1 | **Carrom** game | `Games/Carrom/CarromGameView.swift`, playable | "Coming soon" row (`GamesHomeScreen.kt:311`) | Port the board physics and view; wire it into the games router. |
| 2 | **Story archive** | `Stories/StoryArchiveView.swift` | None; no archive anywhere in `main/stories/` | Add `StoryArchiveScreen`, reached from Moments. The iOS archive is local only (`StoryStore.archived()`), so Android needs its story store to keep expired own-stories on device too. |
| 3 | **Map: Move / travel mode** | `MapMoveScreen.swift` (545 lines) + `MapStartMoveSheet` | None | Port both screens. |
| 4 | **Map settings & notifications** | `Map/MapSettingsView.swift`, `Map/MapNotificationsView.swift` | None; ghost mode is inline in `MapTabView.kt` | Add both screens and reach them from the map header. |
| 5 | **Map intro & privacy screens** | `MapIntroScreen.swift`, `MapPrivacyScreen.swift` | Folded into `MapTabView` (the `onboarded` gate) | Port the intro carousel and the privacy explainer. |
| 6 | **Link a browser (web companion)** | `Settings/LinkBrowserView.swift` (QR scanner) | Deliberately omitted (`LinkedDevicesScreen.kt:54`, "scanner does not exist yet") | Reuse the CameraX + ML Kit barcode path from `ScanQrCodeScreen.kt`, then add the Link button. |
| 7 | **Chat media viewer** (swipeable gallery) | `ChatMediaViewer` | Single-item image/video viewer (`MediaViews.kt`) | Add a pager viewer with zoom, swipe-to-dismiss and share/save. |
| 8 | **AI hub** | `Main/AI/*` (~1.3k lines, hub + chat) | `AIChatView.kt` (169 lines, chat only) | Port the hub landing (suggestions, history), then route into the existing chat. |
| 9 | **Match history** | `Games/MatchHistoryView.swift` | None | Port it. (Not linked on iOS yet either, so low priority.) |
| 10 | **Clips social privacy + guidelines** | `SocialPrivacyView`, `ClipsGuidelinesSheet` | Partly in `SocialSetupSheet.kt` | Split into dedicated screens that match iOS. |
| 11 | **Restore messages** in onboarding | `RestoreMessagesView.swift` | `onboarding/RestoreFlow.kt` exists | Check it visually against iOS; the logic is there. |

## 3. Visual and interaction gaps (screens exist, look behind)

| # | Area | iOS | Android | What to do |
|---|---|---|---|---|
| 1 | **Blur / glass** | Materials and `glassEffect` in 17 files | Blur in 7 files; message menu scrim is a flat dim | Carry out `docs/LIQUID_GLASS.md` (spec only, not started). |
| 2 | **Message long-press menu** | Bubble lifts, blurred scrim, reaction palette floats above, icons on the leading side | Material `DropdownMenu` (`ChatUI.kt:287`) with reactions inside it | Build an anchored popover: lifted bubble, blurred scrim, reaction row above, action list below. |
| 3 | **Pull-to-refresh** | `.refreshable` on 16 screens | **0 screens** | Add `PullToRefreshBox` to chats, groups, moments, communities, call log and clips. |
| 4 | **Context menus** | `.contextMenu` in 8 files | None (long-press is custom per screen) | Add a shared `VoiidContextMenu` and use it for chat rows, stories and community posts. |
| 5 | **New group** | 88 pt squircle hero, "A space for your people", member avatar strip, bottom Create pill | Plain form; no hero, no strip | Rebuild the header and strip; move Create to the bottom pill. |
| 6 | **Group info** | Overlapping 3-avatar cluster; Message / Voice / Video action cards (`GroupInfoView.swift:33-35`) | Plain avatar, no action cards; lowercase `owner` / `admin` pills (`GroupInfoView.kt:356`) | Add the avatar cluster, the 3 action cards and outlined `Owner` / `Admin` badges. |
| 7 | **Edit profile copy** | Field is "About" | Field is "Bio" (`ProfileSettingsScreens.kt:293`) | Rename it to "About" and add the leading icon badges on fields. |
| 8 | **Shared-element transitions** | `matchedGeometryEffect` in 6 files | `SharedTransitionLayout` in 2 | Add them for avatar → profile, story ring → viewer and clip → fullscreen. |
| 9 | **Swipe actions** | `.swipeActions` on chat rows (`ChatListRows.swift`) and community lists | 1 use | Add swipe to archive, mute or delete on chat rows. |

## 4. Suggested order

1. **Pull-to-refresh + message long-press popover.** Users touch these every session.
   Small and self-contained.
2. **Group info + New group polish.** Visual only; no backend work.
3. **Face filters in Android video** (CameraX 1.4 `OverlayEffect`). Finishes tonight's work.
4. **Story archive, media viewer pager, Link a browser.** Whole features that need no new
   backend work (the web-companion linking route already exists).
5. **Map suite** (Move, Settings, Notifications, Intro, Privacy). The biggest block;
   schedule it as its own sprint.
6. **Carrom, AI hub, match history.**
7. **Liquid Glass pass** on Android, following `docs/LIQUID_GLASS.md` §11.

## 5. How this was checked

- Matched every iOS `*View` / `*Screen` / `*Sheet` against Android by name, then grepped
  for each one's function or feature (content, not just file names). Screens that exist
  under a different file name were dropped from the list (e.g. `FindByUsername` lives in
  `ReachabilityScreens.kt`, `PollCompose` / `MessageInfo` / `Forward` in `ChatSheets.kt`,
  event check-in in `EventManagementScreens.kt`).
- Counted each platform's use of shared UI patterns (materials, blur, `.refreshable`,
  `.contextMenu`, `.swipeActions`, shared transitions).
- Both apps' camera changes compile: Android with `:app:compileDebugKotlin` /
  `assembleDebug`, iOS with `xcodebuild` for the iPhone 17 Pro simulator.
