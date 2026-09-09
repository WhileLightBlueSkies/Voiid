# Camera controls and audio output repair — 2026-09-09

This follows the confirmed cross-platform call audio repair in `CALL_ENCRYPTION_FIX_2026-09-09.md`.

## Findings and changes

### Android self-preview after answering

The user could see their preview only after toggling the camera off and on. Device logs showed both camera capture and actual rendered frames, so the investigation moved to surface composition. Local and remote video used separate `SurfaceViewRenderer` instances with no explicit media overlay order. The remote surface can be created after the answering phone's preview and cover it.

The local preview now calls `setZOrderMediaOverlay(true)` before its view attaches; the remote surface keeps the default layer. The preview's drag/flip controls and track attachment remain in place. Device confirmation of immediate self-preview is pending.

### iPhone camera-switch crash

The device report `Voiid-2026-09-09-200544.ips` identifies an uncaught `NSInvalidArgumentException` from `AVCaptureSession.addConnection`: the video output already had a connection. The existing switch called native `startCapture` again without completing a stop. The installed LiveKitWebRTC camera capturer uses a shared MultiCam session on supported devices, and its stop implementation removes the old connection.

All camera starts now wait for native stop completion. A request generation and current-call/capturer checks coalesce rapid flips and discard callbacks after hold, backgrounding, camera disable, replacement, or hangup. Camera-off now stops capture; camera-on resumes through the same guarded path. Encryption and microphone setup are preserved.

`tools/check-camera-lifecycle.py` compiles the production scheduling methods with asynchronous capture fixtures. Eight cases pass: stop ordering, rapid flips, hold, end, camera off, replacement, background, and cancellation. Native camera switching still requires the device test.

### Android audio output selection

An explicit phone/speaker selection previously called the automatic route helper, which always chose a connected Bluetooth or wired headset first. Selecting an external route also fell through to AudioManager even when Telecom owned the call. Newer Android devices were handled only through deprecated audio-state callbacks.

- Explicit selections now go through the existing Telecom connection for all route types and do not use the headset-first default.
- Android 14+ uses the system-provided `CallEndpoint` objects and `requestCallEndpointChange`. Endpoint callbacks drive the current route; a submitted request alone does not move the checkmark.
- Older Android retains the legacy Telecom route API with explicit target selection.
- Initial routing still follows connected headsets. A pending user choice survives delayed Telecom attachment, and the AudioManager fallback retains an explicit selection across device-list changes while the device remains available.
- The picker appears whenever an external route exists, including a system list with only speaker and headset. The built-in route label is now “Phone”.

`tools/check-call-audio-routing.py` runs the production routing methods against modern and legacy callback fixtures. It covers explicit phone/speaker choices with a connected headset, selecting a specific headset, deferred endpoint availability, actual-route UI callbacks, and stale callbacks after termination.

The modern API requirement is documented in [Android's Connection reference](https://developer.android.com/reference/android/telecom/Connection#requestCallEndpointChange(android.telecom.CallEndpoint,%20java.util.concurrent.Executor,%20android.os.OutcomeReceiver%3Cjava.lang.Void,%20android.telecom.CallEndpointException%3E)).

### iPhone headphones → phone

The call audio configuration allowed stereo A2DP as well as bidirectional HFP. A2DP can retain Bluetooth output while the app selects the built-in microphone. Call and tone sessions now allow HFP without A2DP. Explicit routing removes inherited A2DP/default-speaker options, selects the built-in microphone for phone/speaker, and then applies the requested output override. The current route and speaker indicator are read back from the actual session output.

This targets Bluetooth call routing. The user has been asked whether their earphones are Bluetooth or wired; hardware confirmation remains pending. No claim is made that a wired headset can always be bypassed to the receiver.

## Builds and device check

The combined signed iPhone build and Android Debug APK passed builds. The iPhone package passed Firebase resource preflight and signature verification. Both were installed and launched on the connected test phones, preserving app data and including the earlier media-key repair. Unrelated concurrent chat UI work was excluded using the existing isolated build snapshot.

The user has been asked to verify: answer a video call on Android and see self-preview immediately; flip the iPhone camera repeatedly without a crash; switch headphones → phone → speaker on both phones. App-only device diagnostics are being captured. These hardware checks remain pending at the time of writing.
