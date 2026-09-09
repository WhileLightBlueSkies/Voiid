# Android Moments: upload orientation and chat references

## Changes

Photos selected from the gallery were decoded with `BitmapFactory` and re-encoded as JPEG without applying EXIF orientation. That permanently uploaded sideways pixels. The composer now uses the shared orientation-aware decoder before resizing and encoding, including mirrored photos; unreadable input produces an error instead of being uploaded with a false JPEG MIME type. Moments thumbnails and the viewer use orientation-aware sampled file decoding as well.

The in-app camera now follows physical device orientation and uses CameraX's file output, which records capture rotation in EXIF before the composer normalizes it. It previously copied raw ImageProxy bytes and discarded separate rotation information. Video upload dimensions now reflect the existing rotation metadata; the video itself retains its original bytes and metadata. CameraX's [output transformation contract](https://developer.android.com/media/camera/camerax/transform-output) documents the file/EXIF behavior.

Android now preserves `storyQuoteId`, `storyQuoteAuthorId`, and `storyQuoteCreatedAt` on received replies, linked-device copies and the sender's local echo. These optional fields survive existing JSON persistence without a database migration. Reaction-only iOS envelopes, including omitted/null text, also decode correctly.

Chat bubbles display the Moment author and a local photo/video thumbnail above the reply, using the existing bubble colors. The reference observes local story updates, rejects mismatched authors, removes its thumbnail at expiry/deletion, and distinguishes expired from unavailable Moments. It never downloads media or saves a permanent copy in chat. Deleted chat messages hide their quote. iOS already renders Moment references; its code is unchanged in this patch.

## Validation

- Android debug app and instrumentation APK build passed.
- Android lint regression gate passed: 90 errors, matching the existing baseline. The first local lint attempt hit a generated-source symlink/module-resolution error; materializing identical generated sources inside the temporary build workspace allowed lint to complete.
- All 120 Android JVM tests passed, including four new production serializer/reference conversion tests for iOS replies, local echoes, persistence, old messages and unsupported versions.
- Added instrumentation coverage of actual composer output for all eight EXIF orientations, plus sampled Moment file decoding. These tests compile but have not run: no Android device/emulator is available through ADB.
- The previous iOS simulator build completed successfully.

## Device checks still required

1. Upload portrait, landscape and upside-down gallery photos; compare composer, own Moment, Android receiver and iPhone receiver.
2. Repeat front/back camera capture while holding the phone portrait and landscape, including with screen rotation locked.
3. Upload portrait/landscape videos and check dimensions, playback and sound on both clients.
4. Reply with text and a reaction in both directions; verify the reference immediately and after restarting Android.
5. Delete/expire the referenced Moment while chat is open; its media must disappear while the reply remains readable. Delete the reply itself; no quote should remain.

Previously uploaded photos whose orientation was already stripped need to be uploaded again from the original. Old Android replies whose reference was discarded cannot be reconstructed from the stored body alone. The quote is a reference card; opening a Moment by tapping it is not part of this patch.

## Separate deployment status

The previous Memories backend deployment (`34396639383`, commit `5a77220`) encountered a failed Sea Battle test: “the deadline survives a restore unchanged.” The Node gate therefore blocks deployment. The assertion compared deadlines after the restored engine had already accepted a shot and correctly advanced its turn. A separate test-only correction checks the deadline immediately after restore; the Sea Battle suite passes locally. Production game/backend behavior is unchanged. Deployment still requires the remote quality gates to pass.
