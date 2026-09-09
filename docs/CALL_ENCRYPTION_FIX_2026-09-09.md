# iOS / Android call encryption repair — 2026-09-09

Reported symptom: calls in both directions had no audible media and the iPhone remained on “Checking encryption”.

## Changes

- Android now handles and sends the existing iOS v1 verification envelope. The shared commitment uses the derived media key, salt, and normalized, sorted SDP fingerprints. Previously Android did not complete this verification exchange and its unused commitment helper used a different algorithm.
- iOS now parses SDP fingerprints correctly when SDP uses CRLF line endings. The production-parser regression reproduced a missing fingerprint before the fix.
- Both platforms attach frame cryptors when receiver tracks become available. Android also attaches them after applying the remote answer. Stable native sender/receiver IDs prevent duplicate attachment through different wrapper objects.
- Callers resend the existing call secret after the answer so an initial key arriving before the callee's call state does not permanently strand media setup. This does not rotate the secret.
- Verification messages retry with fresh pairwise encryption at 0, 2, and 6 seconds. Tasks are scoped to the call and key generation and cancelled on cleanup or replacement. iOS retains a same-generation verification message that arrives before its secret.
- Android initial media-key installation runs on its media executor.

Encryption remains enabled. These changes address identified protocol and media setup defects; a successful build does not establish audible end-to-end media on real devices.

## Validation and installation

- `tools/check-call-key-interop.py`: passed against the production Swift commitment and SDP parser, including CRLF SDP and the shared Android digest fixture.
- Android `CallKeyProtocolTest` and `LinkedMessageOwnershipTest`: passed.
- Existing call lifecycle, Android call state, and conference recovery regression scripts: passed.
- Signed iOS Debug build and Android Debug APK build: passed.
- iOS app bundle configuration preflight and signature verification: passed.
- Updated iPhone app installed and launched; subsequent process check confirmed it running. Launch console contained no fatal exception marker at inspection.
- Updated Android app installed successfully and launched successfully.

Builds used an isolated snapshot with the call fixes and the preceding linked-message ownership repair. Other concurrent chat UI edits were excluded.

## Live checks still required

The user has been asked to place fresh iPhone-to-Android and Android-to-iPhone calls and confirm both two-way audio and that verification completes. At the time of this report, no new call or verification event appeared in the updated iPhone console. Audible media is therefore not yet confirmed.

Conference regression checks passed, but a live three-device conference remains untested because only two test devices are available. No backend change was needed for this repair.

## Follow-up: verified keys but silent audio

The user tested both directions and reported continued silence. Fresh device logs confirmed the v1 verification exchange completes on both platforms. Targeted Debug diagnostics then showed:

- Android microphone recording and playback started successfully.
- iOS had an active, enabled audio session and a microphone track with nonzero source energy.
- iOS RTP packet counters increased in both directions, but incoming decoded sample count stayed at zero and its frame cryptor reported `decryptionFailed`.

The root cause found in application code was a second key-derivation path: Rust `new_call_secret` uses vodozemac's unpadded standard Base64 encoding. Android's decoder accepts that format. Foundation's strict `Data(base64Encoded:)` rejects an unpadded 32-byte secret, and iOS `frameMediaKey` then silently derived from the UTF-8 encoded text. The Rust-derived SRTP verification could still match while the native audio encryption keys differed.

The iOS media-key path now restores Base64 padding, requires exactly 32 decoded bytes, and rejects invalid input. It never derives from encoded text. The regression compiles the production media-key method and checks unpadded and padded secrets against the Android-compatible HKDF fixture, plus invalid input rejection. Reintroducing the old fallback into an isolated fixture reproduces an assertion failure; the corrected implementation passes.

The corrected signed iPhone build passed configuration preflight and signature verification, was installed, and launched. Android retains its earlier lifecycle and verification fixes and now includes Debug cryptor-state diagnostics. A new user audio check is pending after this installation. Debug diagnostics log bounded cryptor states and numeric packet/audio counters, never secret keys or audio content.

### Post-fix device evidence

The fresh 20:02 iPhone-originated test call showed Android sender and receiver cryptors both reporting `OK`. iOS reported cryptor `OK` after a brief startup rejection, and its inbound decoded samples increased from 136,320 to 424,320 over successive samples with nonzero received audio energy. Both outgoing and incoming RTP counters increased, the audio session and microphone remained enabled, and key verification completed. This replaces the earlier sustained decryption failure and zero decoded samples.

A second, Android-originated call arrived at 20:03:48 and connected at 20:03:52. Both platforms again reported successful cryptors; iOS decoded 544,320 received audio samples with nonzero received energy before remote hangup at 20:04:14. Call direction is established from the iPhone receiving an answer for the first call and an offer for the second. Device evidence now covers both directions. The user subsequently confirmed: “perfect can hear”.

### Video-call follow-up

The user then reported missing audio and video in video calls and asked whether LiveKit was responsible. Code inspection confirms that 1:1 voice/video uses native peer connections (LiveKitWebRTC on iOS, Stream WebRTC on Android); the LiveKit conference server is used for group/conference media, not ordinary 1:1 calls.

The 20:05:33 video call on the corrected builds showed four active iOS frame cryptors and successful audio/video cryptors on both devices. Android camera capture started at 1280×720, its H.264 decoder produced frames, and both EGL renderers reported actual rendered frames, reaching about 30 fps. iOS inbound audio samples and received audio energy increased, with its audio session and microphone enabled. These observations do not reproduce a complete media transport failure. Whether the user can see remote video on the iPhone and hear both phones in this fresh test remains to be confirmed; successful decryption alone does not prove visible rendering on the iPhone.
