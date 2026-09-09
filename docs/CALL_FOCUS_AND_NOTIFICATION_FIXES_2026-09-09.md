# Android microphone reliability and notification routing — 2026-09-09

## Device evidence

The reported failure affected Android's outgoing voice on both its built-in microphone and headphones. Incoming audio remained audible. A subsequent call worked, confirming the intermittent nature rather than resolving it.

Android's audio-service history at 21:00:04 and 21:00:32 showed Voiid requesting independent audio focus, Telecom taking focus for the same call roughly 330–370 ms later, and Voiid receiving transient focus loss. Our interruption callback disabled the microphone track; the recorder stopped immediately afterward. The recording configuration did not report OS microphone silencing.

## Changes

- Telecom-owned 1:1 calls no longer retain a competing app audio-focus request. Delayed Telecom attachment releases fallback focus and reconciles microphone state.
- Queued fallback callbacks are fenced by call ID and current Telecom ownership. A loss from the handoff cannot disable the microphone afterward or affect a replacement call.
- Microphone capture consistently respects user mute, hold, and genuine interruptions, including track creation and later unmute/unhold. Telecom focus lost/gained callbacks now drive the Telecom interruption gate; resource release is acknowledged after the media executor applies it.
- Notification answers wait for the Activity's RESUMED lifecycle before starting microphone foreground services. Locked-screen calls retain full call controls; ended calls release lock-screen window flags.
- While Android is unlocked and foregrounded, incoming calls use the system notification without automatically replacing the current app screen. Tapping the notification explicitly opens its call; Answer opens the active call. Blocked notification permissions/channels and posting failures retain the in-app answer fallback. Background/locked calls retain full-screen notification intents.
- Message PendingIntents include both conversation and message IDs in their identity and extras. Call answer intents similarly include the call ID, including waiting-call answers.
- Android message previews cannot substitute an unrelated older message when a specific pushed message is unavailable.
- Both Android and iOS retain the exact message destination through cold launch, tab navigation, conversation loading, and transcript loading. Repeated taps have separate request identities; stale async completions cannot consume a newer destination. iOS previously used a transient NotificationCenter event, which could be missed before the chat screen existed.
- Group-call notifications retain their group-call destination. Silent protocol/story wakes remain silent; they are not message notifications.

The backend already sends opaque `conversation_id`, `message_id`, and call routing IDs. No backend change or deployment is required.

## Validation

- `python3 tools/check-android-call-state.py`: production state/mute methods plus the actual microphone reconciliation and focus callback methods. Covers the observed handoff, late/queued losses, true interruption, mute/hold, replacement/hangup, and track creation after interruption.
- `python3 tools/check-notification-routing.py`: production Kotlin and Swift destination routers; delayed transcript consumption, rapid/repeated taps, stale completion, conversation-only fallback, incoming notification presentation, exact preview selection, and transport/UI wiring.
- Existing audio-routing, camera lifecycle, and cross-platform call-key regression checks pass.
- Android Debug build and selected call-key/message-ownership unit tests passed. The final installable build also passed after including the other agent’s current shared-media changes.
- iOS Debug device build passed; app-bundle Firebase-resource checks and strict code-signature verification passed.
- Both builds were installed successfully on the connected Android and iPhone. Android launched successfully, and fresh app-specific diagnostic captures were started for the physical checks below.
- `python3 tools/check-call-lifecycle.py`: five production CallKit handler regressions passed.

## Physical checks still required

1. iPhone → Android, Android locked: answer the system notification and speak on both sides for at least 30 seconds.
2. Android → iPhone, iPhone locked: answer CallKit and repeat.
3. Repeat both directions across several consecutive calls, with Android calling and answering on built-in microphone and Bluetooth. Exercise mute/unmute, hold/resume, and output switching.
4. While Android is open in a chat, receive a call: exactly one system incoming notification, no automatic in-app takeover. Verify notification tap, Answer, Decline, and cancellation when the caller hangs up.
5. Send several messages to each device; tap an older notification, then a newer one. Repeat from another tab, an open different chat, and a cold launch. The transcript must open at the corresponding message.
6. A genuinely deleted/unavailable message cannot be displayed; its notification must never substitute another message's preview. Offline delivery and OS force-stop restrictions remain platform-dependent.

Compilation and deterministic regressions do not establish end-to-end microphone reliability. Multi-party conference focus behavior has not been live-tested by these 1:1 checks.
