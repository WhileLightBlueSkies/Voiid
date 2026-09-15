# Android conference audio route correction

Reported behavior: Android moves to speaker when joining a conference.

Confirmed code issues: ConferenceState defaulted speakerOn to true, including voice invite acceptance. LiveKit room creation used its default audio handler while Voiid and the retained Telecom connection also controlled audio routing.

Changes: voice invites use earpiece by default and preserve the matching existing call's speaker choice; video keeps its speaker default. Conference rooms use LiveKit NoAudioHandler with its communication-mode workaround disabled, leaving routing to Voiid/Telecom. After cutover, applySpeaker delegates to the surviving Telecom connection when available, using the existing AudioManager fallback otherwise. No signaling or encryption behavior was changed.

Validation: Android debug build, 138 unit tests, APK signature verification passed. Updated build/share/Voiid-Android-2026-09-11-latest.apk. Physical-device validation remains required: voice invite, earpiece-to-conference escalation, Bluetooth/wired route preservation, speaker toggle, leave/rejoin, and return to normal audio after hangup.

Log limitation: the available iPhone console stopped after the earlier 19:00 test; it does not contain the reported conference attempt. No current Android conference report was supplied. Do not claim these source findings establish the exact device-level sequence of the latest attempt.
