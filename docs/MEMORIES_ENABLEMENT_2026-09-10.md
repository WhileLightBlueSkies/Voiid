# Memories / Moments enablement — September 10, 2026

Memories is the existing Stories feature, named **Moments** in both native apps. The current test builds expose Chats and Moments. Existing encryption is retained: a fresh AES-256-GCM media key encrypts each blob on-device; per-device Double Ratchet envelopes carry its key, caption and metadata. The backend stores ciphertext plus routing metadata. View receipts remain opt-in.

## Corrections

- iOS refreshes share one in-flight task, Android feed refreshes use one mutex, including push-triggered refreshes. This avoids concurrent decrypt-once consumption. Both app roots refresh Moments after returning to the foreground, skipping that automatic work during an active call.
- iOS empty-state rendering uses the engine's actual refresh result; it no longer fetches and discards another deliver-once feed page as a health probe.
- iOS canonicalizes story IDs and compares authenticated UUID bindings without case sensitivity. Both platforms reject unsupported envelope versions/types while accepting omitted legacy defaults.
- iOS share errors retain the composer and media for retry. Replies and deletes only show success after completion; a failed delete retains the local post. Android's failed-post retry now reads the saved audience and cached media.
- Android batches audiences beyond 1,000 device envelopes. A later batch failure on either platform retains the already-published post and reports partial delivery instead of treating it as wholly unsent.
- Android handles live deletion signals by removing the local post; iOS dismisses a deleted active post. Viewers stop at expiry (the author's explicit iOS archive remains available). Android waits for ready, visible media before recording a view.
- Backend key delivery normalizes UUID casing, skips blocked and revoked recipient devices, and does not fail a durable delivery solely because its WebSocket wake failed.
- Story downloads and receipts enforce live stories, blocking and active-device entitlement. The generic media download endpoint rejects story objects, closing an alternate route around story authorization.

## Validation

- Backend API TypeScript build and five production-route authorization tests passed.
- Final Android debug and iOS device builds passed; all 116 Android JVM tests passed with no failures, errors or skips. iOS bundle-resource preflight passed.
- Kotlin-generated photo/video/view-receipt fixtures passed decoding using production Swift types, including omitted defaults and required encryption keys.

## Deployment follow-up

The first implementation was pushed as `7f08f88`. The preceding deployment's iOS simulator gate exposed a missing `@MainActor` annotation on `VoIPPushManager` when it accesses `E2EManager.deviceId`. The follow-up restores that annotation; PushKit delegate callbacks remain nonisolated and synchronously enter the main actor as before. This fixes the compile-time isolation boundary without delaying CallKit reporting.

The Memories build was installed and launched on the paired iPhone. Android is not discoverable through ADB, so Android installation and the cross-platform physical test remain pending. Backend protection changes become live only after the gated deployment succeeds.

## Physical test matrix

| Scenario | Expected result |
| --- | --- |
| iOS photo → Android; Android photo → iOS | Selected recipient sees and decrypts the same media/caption. |
| Video each direction | Video and audio play; pause/resume and advance work. |
| Custom audience | Excluded account receives no envelope. |
| Offline posting | Honest failure; draft/retry remains available. |
| Reply and reaction | Encrypted chat reply appears with the original story reference; no false Sent state. |
| View receipts off/on | Off sends no receipt; opted-in viewing populates the author list. |
| Delete with working network | Author and online recipient remove the post; open viewer stops. |
| Delete with failed network | Author retains the post and sees an error. |
| Expiry while viewing/paused | Viewer closes; ordinary feed no longer includes expired post. |
| App backgrounded | Content-free wake triggers feed sync; unread state refreshes. |
| Blocked/revoked device | New key delivery/download/receipt is refused. |

## Limits to verify before release

A passing build or route test is not a physical cross-platform sharing test. The connected-phone matrix remains required. Existing deliver-once feeds do not guarantee crash-safe recovery between server delivery and local persistence, and prekey exhaustion can leave recipient devices out of a fan-out. Durable per-device acknowledgment/outbox retry would require a separate protocol change. Already-issued signed URLs and already-decrypted copies cannot be revoked. Android has no author archive equivalent to iOS.
