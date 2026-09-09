# Moments audit — Android, iOS and backend

Scope: the currently enabled Moments feature (named Stories in code), from choosing media and audience through upload, encrypted delivery, viewing, chat replies, receipts, deletion, expiry and account teardown. This is a source audit plus builds and automated tests, not a claim of complete physical-device validation or an independent cryptographic review.

## Confirmed issues addressed

| Area | Finding | Change |
| --- | --- | --- |
| Android upload orientation | JPEG encoding removed orientation before applying it. | Previous commit `c82b072` normalizes gallery/camera photos and samples correctly oriented thumbnails. |
| Android chat replies | Original Moment reference was discarded. | Previous commit preserves the ID, author and creation time in received messages and local echoes; renders a quote card. |
| Android reply/reaction UX | Viewer closed and claimed success before the send finished. | Waits for completion, prevents duplicate taps, retains the draft and displays failure in the viewer/sheet. |
| Android deletion UX | Viewer closed even when deletion failed. | Closes after a successful delete; failure remains visible with a retry opportunity. |
| Reply authorization | Android could send against stale, expired or non-replyable snapshots. | Both clients re-read local state and require a live, replyable Moment from someone else and a nonempty reply/reaction. |
| Viewer counts | Android used delivered-device counts as a fallback for views. | Views come only from decrypted view receipts. Delivery is not a view. |
| Receipt attribution | Both clients accepted the encrypted payload's claimed viewer ID without binding it to the decrypting session's owner. | Decryptors return authenticated session ownership; consumers verify viewer, story ID, version/type and positive timestamp. |
| Receipt ratchet persistence | Android directly decrypted with cached sessions and did not save the advanced state. | Reuses the normal per-peer locked decrypt/persist path. Receipt fetching is serialized; disabled receipts are not fetched. |
| Repeat views | Reopening stale snapshots could repeatedly send view receipts. | Re-read the stored viewed timestamp and skip previously viewed or expired rows. |
| Download races | Prefetch and viewer could download the same object concurrently; stale snapshots could publish media after deletion. | Coalesce/serialize per-story downloads, re-read current rows, reject expired/deleted objects and coordinate Android file publication with deletion. |
| Expired quote media | iOS quote could retain a thumbnail after deletion/expiry and called any missing file “expired.” | Re-resolve on deletion/foreground/expiry, re-check after decode, verify author, distinguish unavailable and expired. An author's archive is not displayed in an expired chat quote. |
| Missed offline deletions | Cached media could remain visible until expiry after missing a socket event. | Add authenticated `POST /stories/availability`; clients reconcile their cached live IDs on refresh. Failed requests/older servers retain local state. |
| Audience authorization | An empty local contact cache bypassed the author filter. An authenticated session alone does not prove contact permission. | Defer consuming the feed while the local contact/chat list is empty; reject unknown authors before decryption. |
| Account teardown | Moments had independent media caches and audience/receipt preferences outside sign-out cleanup. | Clear Moments state, files, frames and preferences; invalidate in-flight feed/post/download work so it cannot restore the previous account's state. |
| Memory pressure | Android read an entire selected/remote file before applying its size cap. iOS loaded exported/downloaded media before checking size. | Bound Android streams while reading. Check iOS export file size before loading; download ciphertext to a temporary file, check size, then map/read it and remove the temporary file. |
| Prefetch load | iOS could schedule one auto-download for each of 20 authors at once. | Bound each auto-download scheduling pass by the remaining three-download budget. |
| Relay errors | Successful receipt/deletion database writes could return failure when Redis publishing failed. | Treat wake relay failures as best effort; durable state remains authoritative and cached IDs reconcile on refresh. |

## Security boundaries reviewed

The media blob is encrypted on the client; the media key/nonce/hash travel inside per-device encrypted envelopes. The storage service receives ciphertext and the backend keeps routing metadata. Client validation binds a story envelope to the server-routed story ID, author and object key. Download, availability and receipt routes require entitlement and filter blocked users/revoked devices. The generic media download route already rejects the story prefix.

The new availability endpoint accepts at most 1,000 UUIDs and returns only authorized, live IDs. It does not return keys/ciphertext or consume one-time envelopes. It intentionally makes missing, expired and unauthorized IDs indistinguishable. Availability is user-entitlement scoped, matching the existing download route.

Receipt identity is bound to the local authenticated ratchet session, not a newly trusted server-supplied viewer name. These fixes reuse the existing crypto primitives; they do not replace or modify the encryption protocol.

## Validation

- Backend TypeScript build passed.
- Nine production-route handler tests passed, covering existing entitlement rules plus bounded availability requests, revoked/block filters, and successful durable writes when Redis is offline.
- Android regression tests cover receipt identity spoofing, story mismatch, unsupported receipt versions and bounded streams. Instrumentation tests exercise actual local file publication for live/deleted/expired rows and stale account generations; they are compiled but require a connected Android device to run.
- Android upload orientation instrumentation from the previous fix covers all eight EXIF orientations and sampled file decoding.
- iOS device build and bundle-resource preflight passed. The update was installed and launched on the paired iPhone; a subsequent process check confirmed Voiid was running. This is a launch smoke check, not the cross-platform scenario test.
- Android debug and instrumentation APK builds passed; all 124 JVM tests passed (zero failures/errors/skips). The lint regression gate reported 90 existing errors, equal to the baseline. The final viewer-count loading and storage-compatibility corrections passed the same build, 124-test and lint regression checks.
- Android remains unavailable through ADB; no new Android build or instrumentation test has been installed/run on the phone in this audit.

## Remaining release risks and limits

1. **High — durable delivery/acknowledgment.** The feed still marks envelopes delivered before the client commits decrypted state. A process crash or failed persistence can lose a Moment; re-fetching an already consumed ratchet message does not recreate its plaintext. A durable inbox/acknowledgment design coordinated with crypto state is still required. `include_delivered` recovery is not that guarantee, and its bounded first-page recovery also needs cursor coverage.
2. **High — posting idempotency and missing device keys.** A timeout after server commit can leave the client uncertain and a retry can create another post. Exhausted prekeys and later fan-out batch failures are surfaced best effort; there is no durable per-device outbox/retry protocol yet. Linked devices without the relevant receipt session/audience history can still miss best-effort viewer receipts.
3. **Medium — cold contact state.** Feed consumption now waits when the local contact/chat list is empty. This avoids accepting strangers and consuming legitimate pending envelopes before contact data loads. Receiving a linked device's own Moment in a truly empty contact account is deferred too. It resumes on a later refresh after contact/chat data is available.
4. **Medium — media resource limits.** Android decoding can still allocate a full-resolution source photo before resizing; iOS PhotosPicker still loads original gallery selections as Data. iOS ciphertext downloading is memory-bounded after download but does not yet impose a streaming disk-byte cutoff. Very large source selections and download/network cancellation deserve additional physical-device coverage.
5. **Expected limit — revocation.** A compliant client removes unavailable cached media on refresh; an offline device cannot learn deletion until it reconnects. Already-decrypted copies/screenshots and already-issued signed URLs cannot be retroactively erased. This is not a guarantee that recipients cannot retain content.
6. **Platform parity.** iOS supports an explicit author archive; Android does not yet offer equivalent archive UI. Quote cards reference Moments but do not open a viewer on tap. Previously stripped upload orientation and previously discarded Android reply references cannot be reconstructed from their stored values.
7. **Physical validation pending.** Android is not visible through ADB. Cross-platform sharing, camera rotation, receipt behavior, lost network during replies, active deletion/expiry and sign-out/account-switch scenarios have not been completed on two phones in this audit.

## Deployment

The prior push (`856295f`) passed Node, Android, web, crypto, migrations and dependency gates, but failed its iOS simulator gate. The log confirms it selected Xcode 16.4/iOS 18.5 SDK, which cannot compile the app’s iOS 26 `scrollEdgeEffectStyle` use; it also reported a result-builder inference failure in CallLogView. The workflow now explicitly selects Xcode 26.3 for the Rust framework and app builds. This version is listed in the [official macOS 15 runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md#xcode). Remote success still needs confirmation. The new availability route requires the backend changes in this audit to deploy. Native clients tolerate an older server or failed availability request without clearing the feed. A push and successful local build are not evidence that production deployment has completed.

## Physical acceptance checklist

- Android → iOS and iOS → Android: portrait/landscape gallery photo, front/back camera, portrait/landscape video; media remains upright and sound plays when unmuted.
- Text reply and each quick reaction: success retains the original Moment reference in both chats; offline failure retains the draft and does not claim success; repeated taps produce one in-flight action.
- Delete with and without network: failure retains the Moment; success removes it on the author and online recipient; a recipient offline during deletion removes it on its next successful refresh.
- Open/prefetch while deleting or expiring: no surviving/recreated media file or stale quote thumbnail; author archive remains available only through archive semantics.
- Receipts off: no viewer list or receipt fetch/send. Receipts on: unique actual viewers, never delivery counts; changing claimed viewer/story IDs is rejected.
- Sign out while downloading/sharing, then sign into another test account: no old tray rows, frames, audience selections, receipt preference or restored media.
