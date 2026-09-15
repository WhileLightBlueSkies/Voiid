# Android call survival after Recents dismissal

## Cause and change

CallForegroundService.onTaskRemoved explicitly called both CallManager.hangupFromSystem and GroupCallManager.leaveFromSystem, then removed the foreground notification and stopped itself. Removing the activity from Recents therefore deliberately ended any ongoing 1:1 or group call.

Removed that callback teardown and explicitly declared android:stopWithTask="false". The call engine and started foreground service outlive the Activity; existing hang-up, remote end and group-leave paths retain responsibility for ending media and stopping the service. START_NOT_STICKY remains deliberate: restarting a killed process cannot reconstruct an encrypted RTC session.

This does not bypass Android Settings Force stop or the system foreground-service Stop action. OEM process termination may still end media. iOS is not changed in this patch; it needs a separate device check. A suspicious iOS scene-disconnect-to-termination handler was found, but has not been changed or validated.

## Required device validation

1. Connect an iPhone-to-Android voice call. Verify both directions of audio.
2. Swipe Voiid away from Android Recents; speak on both phones for 30 seconds. The ongoing-call notification and audio should remain.
3. Tap the notification; call UI should reopen in the same call without another ring/join.
4. End from the reopened Android call UI, then repeat ending from iPhone. Check that notification and microphone indicator clear.
5. Repeat Android-to-iPhone, locked screen and Bluetooth, video, and group/conference calls. Video may suspend if camera foreground-service requirements are not met; audio should continue.
6. Separately test genuine force-stop. The peer must recover/end within its existing timeout bounds; reopening must not revive the old call.

Sources: https://developer.android.com/reference/android/app/Service#onTaskRemoved(android.content.Intent) and https://developer.android.com/develop/background-work/services/fgs/handle-user-stopping

## Build verification

Android assembleDebug and testDebugUnitTest passed: 138 tests, zero failures/errors/skips. APK: build/share/Voiid-Android-2026-09-11-call-recents.apk. Live recents-dismissal audio validation remains pending on the connected device.

Reinstalled and launched on the connected Android (CPH2745) on 11 September at approximately 13:47 IST for user testing.
