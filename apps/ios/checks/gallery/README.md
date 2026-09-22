# Chat gallery verification

`python3 apps/ios/checks/gallery/typecheck.py` type-checks the actual gallery source
against the iOS SDK, with stubs for app services. SwiftUI macro expansion requires
execution outside the restricted tool sandbox. This does not build or launch the app.

Verified: isolated iOS type-check, parsing of changed Swift sources, clean diff
whitespace, and colour scan of iOS Swift hex literals/colour assets. The old dark
AccentColor lime and onboarding CTA gradient now use brand teal. App-level tint and
the document picker inherit the brand accent.

Changed: floating material header/footer, sender/date/counter, expandable captions,
labelled Share/Save/Show in Chat actions, accessible thumbnails, video playback,
load errors with retry, and pause/cancellation when leaving the gallery. Long media
collections release distant page images/players; updates preserve the selected ID.

Still requires device/visual verification (not performed):
- Photo, GIF and video; cached/offline and failed download/retry.
- Pinch, double tap, horizontal paging, filmstrip jumps, vertical dismissal.
- Video controls; pause when paging, presenting Share, backgrounding, or closing.
- Save permission granted/denied and successful Photos import; Share on iPad.
- Show in Chat from both chat-photo viewer and Shared Media.
- Long captions, large text, VoiceOver escape, Reduce Motion/Transparency.
- Portrait/landscape and media arriving/deleted while gallery is open.
- Document Files picker tint in light/dark mode and onboarding CTA colours.
