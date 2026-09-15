# Chat media and transcript stability

Compared the production chat against Voiid UI's ConversationScreen.swift. The real iOS text bubbles already match the reference's 300-point maximum width and 14/10 padding. The reference's sample message model does not implement the production encrypted-media loading path.

Changes on both platforms:
- Reserve 240x220 for uploading, loading, failed and loaded image previews; preserve the complete image using aspect fit. No height change after decode.
- Provide an explicit retry action after thumbnail failure and prevent opening an unloaded Android image.
- Preserve cancellation during lazy-row disposal instead of misclassifying it as a permanent load failure.
- Preserve the reading position for incoming messages/typing when away from the bottom. First load goes directly to the bottom; sending one's own message follows it. Deleting messages no longer forces a jump.

This does not prove all missing images are repaired: unavailable server objects, invalid encrypted media references and unsupported formats still require an affected-message reproduction. Encryption/integrity verification remains in the existing fetchMedia path.

Validation: both platform builds passed; iOS startup resources validated and Android APK signature verified. Updated the shareable APK and installed the iPhone preview on Nehal's device. Visual comparison and a real failed-media retry still require device review.

## Approved photo-card styling

Applied minimal 4-point outer padding, rounded 260×220 media cards, gradient-backed time/delivery overlays and captions on iOS and Android. Existing encrypted loading, retry and fullscreen actions remain in use. The reserved media frame stays fixed because MediaRef currently carries no source dimensions; full-image aspect-fit avoids cropping and download-time layout jumps. Variable portrait/landscape card heights from the preview are not implemented. Both debug builds passed; Android APK signature verified. Device visual review remains necessary.

## Edge-to-edge photo fill

Following review of empty space, chat thumbnails now use aspect-fill on iOS and center crop on Android within the same reserved card bounds. Overflow is clipped without stretching. iOS fullscreen (`fill: false`) retains aspect-fit; Android fullscreen uses its separate, unchanged viewer. This supersedes the aspect-fit thumbnail decision above.
