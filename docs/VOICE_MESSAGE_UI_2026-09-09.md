# Voice-message UI polish — 2026-09-09

Keeps the existing compact play → waveform → time layout, chat bubble colors,
and recording pill. The waveform now fits the space left by the controls instead
of imposing a fixed width. Play has a 44-point target around the original 34-point
disc; duration uses fixed, monospaced text and message metadata sits below it.

Playback:

- Native `UISlider` rendering and adjustable accessibility with a spoken-time
  value. A sibling `UIControl` maps touch position directly to the waveform;
  this avoids the iOS 26 slider's animated value drift after releasing a compact
  custom thumb.
- Voice swipe-to-reply uses a native pan that rejects touches on controls before
  recognition, so scrubbing never becomes a reply gesture.
- The play/pause symbols cross-fade over 150 ms. Press feedback uses a 120 ms
  transition; Reduce Motion removes the scale change.
- Progress follows the audio clock at 30 Hz without queued seek animations.
- Only one voice note plays at once. Finish, interruption, headphone removal and
  leaving the bubble stop its timer and update the playback controls.
- Loading failures expose retry rather than leaving an indefinite spinner.

Recording:

- The waveform draws only as many real meter samples as fit its allotted space.
- Delete progress follows the finger with a trash indicator and a threshold haptic.
- The visible delete action now requests actual recorder cancellation, rather than
  only hiding the recording UI. Cancellation stops audio and removes the temp file.
- A late microphone-permission response cannot start recording after release.
- The transcript receives duration changes once per second; meter updates remain
  isolated to the waveform. Recording time comes from the recorder’s clock.

Validation uses the production voice player and recording bar in
`apps/ios/checks/ChatInteractionQA`, with synthetic local PCM audio and no network.
Microphone capture quality and the feel of press/slide/delete still need an iPhone
check; the automated recording-bar test covers its layout and delete action, not
real microphone capture.

Passed on the iOS 26.5 simulator: compact and larger-text control bounds,
play/pause, midpoint scrubbing with no reply, switching active voice notes,
voice swipe-to-reply, retry state, and recording-bar deletion. The existing
native reaction/menu checks and text swipe-to-reply checks also passed during
this change. No frame-rate or microphone-quality claim is made by this harness.
