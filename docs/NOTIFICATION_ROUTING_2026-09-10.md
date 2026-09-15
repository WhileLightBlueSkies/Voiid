# Message notification routing — 2026-09-10

Foreground messages use a tappable in-app banner on iOS and Android. The currently open thread is suppressed; iOS also retains its mute check. Android in-app banners work without OS notification permission. Background message alerts and the established call notification/CallKit paths remain system-managed. Banner taps carry both conversation and message IDs; duplicate deliveries are suppressed and stale dismissals cannot remove a newer banner. Preview state clears on background/sign-out.

iOS chat routing no longer uses a view-lifetime task for navigation: pending destinations are reconsidered when conversations load, existing chat detail state resets on conversation changes, and notification targets trigger message sync if needed. Android rechecks destinations when the conversation list changes and requests missing target messages immediately.

Validation: both native builds passed, Firebase startup resources passed, Android signature verified, 135 JVM tests passed (five new banner/routing cases), and `python3 tools/check-ios-notification-routing.py` passed seven checks against the production router with isolated mute/presence fixtures. These are not live APNs/FCM delivery or cross-device UI results.

APK: `build/share/Voiid-Android-2026-09-10-notifications-test.apk` (debug-signed test distribution). Live foreground/background/cold-start notification taps still need two-phone verification.

## Banner tap follow-up

Reproduced Combine's pre-commit @Published delivery in the router regression harness. The chat observer now defers validation until publication completes and tries cached conversations before network loading. Failed resolution preserves the chat/message target in a retry banner. iOS and Android banner surfaces are entirely tappable, with separate dismissal controls, stronger visual hierarchy and a teal icon area. Both native builds passed; 135 Android tests and nine iOS router checks passed. APK: `build/share/Voiid-Android-2026-09-10-banner-tap-test.apk`. Real on-device notification tap behavior remains to be confirmed by the user.

## Approved capsule promoted to both apps

The approved option 03 uses theme-matched colors (light glass/dark text; dark glass/light text). iOS uses native iOS 26 Liquid Glass, regular material on older systems, and a solid surface under Reduce Transparency. Android uses a translucent theme surface with matching capsule proportions. Entrance uses a short slide/fade with subtle scale; dismissal is quicker. iOS Reduce Motion removes positional motion; Compose respects the platform animation duration scale.

Both production models coalesce pending notifications by conversation, count distinct message deliveries, retain the latest message ID, and keep at most three chats. Dismissing/expiring the top exposes the next chat; stale timers cannot dismiss a new update. Leaving the foreground/signing out clears the queue. Existing call routing stays separate.

Both builds passed, Android APK signature verified, 138 Android unit tests passed, and 12 iOS routing checks passed. Source snapshot matches changed files; one unrelated Swift file differs only in a documentation comment. Latest Android test APK: `build/share/Voiid-Android-2026-09-10-capsule-test.apk`. Real cross-device notification burst/tap testing is still required after installation; demo checks are not live push evidence.
