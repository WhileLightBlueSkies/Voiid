# iPhone Duo readiness — 15 September 2026

Status: foundational layout preparation implemented; full Duo adaptation and device validation remain open. Do not describe the app as Duo-certified or fully tested.

## Documentation reviewed

Apple's [Duo developer hub](https://developer.apple.com/iphone-duo/) links six technical/design sessions. Their published summaries and code examples were reviewed. The hub currently lists Xcode 27.1 beta and the dedicated preparation article as coming later this month. The local installation is Xcode 27.0 (27A266a). The linked [Duo HIG page](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo) did not expose readable content through the documentation reader; it is not claimed as reviewed.

| Apple source | Guidance relevant to Voiid |
| --- | --- |
| [Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/) | Adapt using size classes and safe areas. Preserve navigation and functionality through poses. Sheets adapt automatically; interactive elements should avoid the fold. Wide layouts can expose more hierarchy. |
| [Prepare your app](https://developer.apple.com/videos/play/tech-talks/111461/) | Use local view geometry and the owning window's screen. Respect asymmetric insets. Inner-display layouts cannot rely on orientation restrictions. Xcode 27.1 enables the full edge-to-edge and vertical-bar behavior and Duo simulator testing. |
| [Raise the bar](https://developer.apple.com/videos/play/tech-talks/111462/) | System navigation containers provide vertical bars. Supply labels and symbols for adaptable toolbar items. Review cancellation/primary actions, overflow, and axis behavior. Vertical bars have no scroll-edge effect by default; retain soft edges for horizontal scrolling boundaries. |
| [Adaptive layouts](https://developer.apple.com/videos/play/tech-talks/111463/) | Query reserved regions for fold/camera avoidance. ArrangementView can rearrange related primary and secondary content. Continuous scrolling content should not be displaced wholesale. |
| [Multiple displays and scenes](https://developer.apple.com/videos/play/tech-talks/111464/) | Use geometry/region APIs for layout, hinge updates for interactions. Split View resizing is required. Multiple windows and scene accessories are additional features, with availability and activation errors to handle. |
| [Camera experience](https://developer.apple.com/videos/play/tech-talks/111465/) | The virtual front camera switches between inner/outer cameras. Individual physical cameras require direction coordination tied to the relevant view. Camera capabilities differ; avoid assuming a fixed resolution across switches. |

## Changes implemented

- Removed the global `VoiidScreen.width` helper, which selected an arbitrary connected scene's physical screen.
- Chat drag/drop hit regions use the measured grid width. Resizing cancels the active drag so stale coordinates cannot trigger a call/delete target.
- Splash sizing uses its current container's short dimension.
- Story decoding uses measured page dimensions, with a bounded pre-layout pixel budget.
- Ludo's compact layout and die size use the available view size rather than `UIScreen.main` or the iPad device idiom.
- The root tab carousel preserves horizontal safe areas while retaining its existing vertical underlap.
- The UIKit media viewer independently respects left/right safe-area insets for its controls and filmstrip.
- Thumbnail generation accepts the consuming view's display scale. Cache entries include pixel size so a thumbnail for one display/size is not reused as a smaller image on another.
- Existing soft top scroll edges remain in place, including explicit Settings and sheet overrides.

## Existing support and remaining work

The app already uses SwiftUI scene lifecycle and targets both iPhone and iPad, with portrait and landscape orientations declared. These are useful foundations, not proof of Duo readiness.

1. **Custom navigation:** `RootTabView` draws a custom tab selector/carousel. It will not automatically become a native vertical bar. Evaluate a system TabView/NavigationSplitView presentation for regular layouts while keeping tab selection and navigation state stable. Keep compact-width functionality accessible.
2. **Fold-aware controls:** validate chat composer, game boards/dice, custom call overlays, playback controls and camera controls against reserved regions using the 27.1 SDK. Do not invent hinge widths or infer poses from model names.
3. **Scene ownership:** event ticket brightness still uses `UIScreen.main`; bind this to the ticket view's actual window and restore the previous display's brightness when moving displays. Floating call windows and UIKit presentation helpers still choose connected scenes; bind them to their originating window before enabling multiple concurrent UI instances.
4. **Camera/calls:** existing Story camera discovery uses `.builtInWideAngleCamera` with `.front`, consistent with Apple's virtual-camera route. Clips includes wide-angle fallback. Confirm the actual device selected and session continuity on Duo, including LiveKit, camera flips and resolution changes. Optional physical-camera or dual-display features require the new direction/scene-accessory APIs.
5. **Wide/narrow content:** test every tab, Settings destination and nested sheet with Dynamic Type, keyboard, and narrow Split View widths. Review fixed-width chat media cards and dense custom headers. Add wider two-column experiences where they improve navigation; do not stretch phone-only compositions indiscriminately.
6. **Toolchain:** install Xcode 27.1 when available, review final API declarations and the dedicated preparation article, then run the Duo simulator. New APIs are not stubbed into the 27.0 build.

## Required runtime validation

- Outer and inner displays, portrait/landscape, open/close during an active chat, draft, sheet and media session.
- Partial folds in book/table poses: controls clear reserved regions and no state reset.
- Split View resizing and keyboard presentation: no clipping, unexpected drag/drop actions, or unreachable buttons.
- Settings, backup/recovery and legal sheets: scroll effects, native dismiss/back controls, large text.
- Camera and live calls across display changes: preview, capture resolution, microphone and session continuity.
- Ludo and other games in short/wide windows: reachable controls and correct board hit testing.
- Normal iPhone/iPad regression checks for the shared geometry changes.

Build validation uses the installed iOS 27 SDK; Duo-specific simulator/hardware validation has not been performed.
