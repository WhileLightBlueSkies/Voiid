# Call encryption indicators — September 10, 2026

Voice and video call screens now show a lock with visible “End-to-end encrypted” text on both platforms. The capsule uses the existing theme for voice and a dark translucent background for readability over video. Group call screens also show the full label, with participant counts kept separate.

The iOS 1:1 indicator observes the existing CallKeyExchange verification state and remains visible during hold and reconnection. Android now publishes the existing current-epoch commitment comparison into call state: pending, verified, unverified, or mismatch. New calls and changed keys start pending. Missing peer verification after the bounded delivery window becomes “Encryption not verified”; a later valid peer tag can still verify. Updates are scoped to the current call and key. Group indicators use their existing keying/E2EE state.

The change does not alter key derivation, encryption algorithms, media tracks, microphone routing, or call controls. Pending and failed checks do not display the successful encrypted label.

## Validation

- Android debug build and all 115 JVM tests passed, including commitment mismatch and empty-tag rejection for badge state.
- iOS device build and bundle-resource preflight passed.
- Cross-platform media-key and commitment vectors passed, including invalid secrets and altered fingerprints.
- Installed and launched successfully on the paired test iPhone. Android installation is pending because ADB discovery has no connected device.
- Physical call-screen verification still requires a live call on the test devices.

## Manual checks

1. Connect a voice call in each direction and verify the lock and exact label appear after key verification.
2. Repeat for video, checking readability against bright and dark camera scenes.
3. Hold and restore the call, then interrupt and restore networking; the badge should remain visible while connection/hold status updates separately.
4. Check a group call: the encryption label and participant count should both be readable.
5. Use a test peer without a verification response or with a mismatched commitment: show the pending/unverified/failure label, never a successful verification claim.
