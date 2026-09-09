# Chat sending and actions — 2026-09-09

The device reproduction showed voice uploads completing and the server announcing the
message, followed by the sender losing its visible bubble. Two separate faults caused
successful actions to look unsuccessful:

- `ChatEngine.SendResponse` relied on Swift property defaults during synthesized
  decoding. Fresh server responses omit `duplicate`, so decoding threw after the server
  accepted the message. Retries include that field, explaining why a subsequent send or
  reopening could advance the previous message. Optional response metadata now decodes
  with explicit defaults.
- iOS day grouping cached entire message values by count/newest timestamp. Receipts,
  reactions and tombstones did not invalidate it. `MessageDayGroups` now caches only day
  boundaries and reads current values on every render.

Sent media, reactions, deletions, replies and forwards now await shard persistence before
releasing the cross-process lock. Pending/failed media rows remain visible across sync on
both platforms. Send/action failures have visible feedback.

Delete for Me stores hidden local tombstones on iOS and Android, preserving decrypt-once
ids while hiding content after refresh/relaunch. It transmits no deletion to the peer.
Delete for Everyone validates ownership, only confirms locally after successful delivery
to the server, and reports failures. Deleted messages ignore late reactions. Selection
supports tappable 44-point/dp controls, Select All, local bulk deletion, and bulk deletion
for everyone when every selected message is eligible. Clear Chat uses local deletion.
Remote reactions/deletion remain scoped to supported 1:1 chats; group local deletion works.

Android now uses per-user reaction maps in its UI, preserves the peer's matching emoji,
serializes rapid changes per message, and keeps pending choices during refresh.

The compact voice layout remains. Recording stops immediately on discard; the recording
bar remains for 240 ms so its native trash feedback and waveform exit can finish before
the composer returns. Reduce Motion omits the spatial movement.

Validation:

- `python3 tools/check-chat-send-lifecycle.py` compiles actual production Swift send,
  action and storage methods with deterministic transport and a deliberately slow shard
  writer. Covers sparse fresh-send responses, immediate WS reload, persistent reactions,
  own/peer matching emoji, unauthorized remote deletion, local bulk deletion after a new
  engine instance, retained dedup ids, no network send for local deletion, and Note to Self.
- Isolated iOS UI tests use production day grouping, bubbles, native menus and voice
  controls. Existing-bubble Delivered/Seen/reaction/tombstone updates pass without adding
  another message. Menu, reply, voice scrubbing, large text and recording-bar checks pass.
- Android: 112 unit tests pass, including `ChatActionStateTest`; debug APK builds.
- Signed iOS device build passes.
- Installed and launched on Nehal’s iPhone 15 and the connected CPH2745 Android
  phone. During the user's subsequent test, new iPhone texts were accepted on the
  first attempt (`duplicate=false`); new voice notes and texts received Delivered
  and Read receipts that the engine applied successfully.

Microphone quality and unanswered-call notification delivery are not claimed by the
isolated tests. The call notification paths were inspected separately:
iOS has a local scheduled missed-call notifier; Android records missed outcomes and reports
them to Telecom after FCM ring delivery. Background/terminated-state banner parity still
needs dedicated device call testing.

## Follow-up: clock remained stale in conversations containing calls

The user's live test showed accepted texts and applied Delivered/Read receipts while the
visible bubble still displayed its sending clock. `ChatStore.messages(for:)` had a second
cache, separate from day grouping: it merged chat messages with call history and keyed
stored message values only by counts and newest date. The cache returned stale values
until the next message arrived. Both published source dictionaries now invalidate that
cache on mutation, including same-count status, reaction, tombstone and call-outcome changes.
The user confirmed **“It changes now”** on the installed iPhone build.

`tools/check-chat-transcript-cache.py` extracts the production merge method, cache stamp
and source property observers. It fails against the old implementation and passes with
status/reaction/deletion/call-outcome updates without adding another message.

A separate slow-disk reproduction exposed a save/reload race: an in-flight shard write
could restore an older pending row or erase an enqueue. Persistence callers now join the
active write and drain mutations before shared-state reload; cold app/NSE paths load the
ledger first. Server acceptance also immediately notifies the UI, and failed text is
mapped to Failed. The production-method send lifecycle check covers these paths.

## Android chat and long drafts

Android now uses the iOS 20dp/7dp bubble corners, 14dp/10dp padding, compact voice row,
trailing voice metadata, and per-message status. Long text places its timestamp below the
paragraph rather than squeezing every line. The header shows the conversation photo.
Message actions use a native vertical dropdown and a row of reaction buttons.

The composer keeps a stable mic slot, an external attachment action, and an internal GIF
control that hides while typing. Both platforms use a 22-point/dp rounded rectangle so a
long draft does not turn the field into a capsule that cuts into its text. Android's native
text field owns cursor tracking and scrolling after six lines; iOS retains its native
vertical TextField with the same six-line limit.

Android recording and playback used `File.createTempFile("vn", ...)`, whose two-character
prefix violates the file API. Both now use `voice-`; all stop/error/disposal paths release
the recorder/player and delete temporary files. Recording requests microphone permission,
requires a new hold after the permission dialog, exposes failure feedback, uses elapsed
real time, and supports a working delete button/90dp slide-to-delete with a short exit.

Validation: signed iOS builds, both Swift regression scripts, Android debug build and unit
tests pass. The major Android design update was installed and visually checked, including
real voice durations. The final six-line input/rounded-field build is ready; the user asked
to finish building while they use Android, so further phone interaction was stopped.
Live record/cancel and long-draft scrolling checks remain to be completed on the phone;
interrupted automated interactions are not counted as passes.

## Follow-up: Android attachments displayed as Unsupported message on iOS

The media arrived and decrypted, but Android's Kotlin encoder omitted `v = 1` because
it was a default value. Swift's synthesized media-envelope decoder required `v`, rejected
the payload, and stored the generic Unsupported message fallback. Android now explicitly
encodes both version and caption, including an empty caption for older iOS clients.
iOS accepts missing legacy version/caption while retaining required encryption fields
and rejecting unknown versions.

`MediaEnvelopeInteropTest` writes image/jpeg, video/mp4 and audio/m4a fixtures using the
production Kotlin DTO. `tools/check-media-envelope-interop.py` compiles the production
Swift DTO and checks those fixtures, omitted legacy defaults, unknown versions and missing
media keys. No encryption is removed or bypassed by this compatibility change.

Android now includes a Camera action in the composer and attachment menu, with native
full-resolution capture, permission handling, a narrowly scoped FileProvider and temporary
file cleanup. The gallery accepts photos and videos and preserves their actual MIME type.
Both chat renderers show video previews; tapping opens their native playback controls.
Previously stored Unsupported message rows cannot recover the discarded media reference
from the generic placeholder: those attachments need resending after the update.

Both debug builds pass, and Android's 114 unit tests pass. Camera capture and end-to-end
photo/video/audio delivery still need a device run. Android phone interaction remains
paused at the user's request while they use it; the updated APK is ready.
