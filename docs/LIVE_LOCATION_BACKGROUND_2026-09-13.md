# 1:1 background live-location review

## Changes

- Removed the 25-metre movement threshold from both chat location providers. Fresh stationary fixes can now reach the recipient rather than the marker aging solely because the sender stopped moving.
- iOS limits encrypted update emission to approximately once per 15 seconds; operating-system delivery is not an exact timer.
- Both platforms reject invalid or more-than-60-second-old fixes and transmit the measurement timestamp instead of relabelling cached coordinates with the current time.
- Android checks expiry independently of new GPS fixes, while outbound shares exist. Restored shares are also monitored.
- iOS checks share expiry before encrypting/sending a new fix, including when background callbacks resume before the UI expiry timer.

## Existing background support reviewed

- iOS has the location background mode, background location indicator and active Core Location updates. Share keys use the app's AfterFirstUnlockThisDeviceOnly keychain storage.
- Android declares a location foreground service and publishes an ongoing notification with Stop sharing.
- Both transports discard location frames when disconnected rather than accumulating stale coordinates for replay. Subsequent fresh fixes use the reconnected socket.

## Device validation remains required

For each sender platform, begin a 1:1 share while the app is open, then lock the phone for several minutes. Test both remaining stationary and walking, then a Wi-Fi/mobile-data handover. Confirm timestamps, position, stop and expiry on the receiver. Verify Friends Map and unrelated chat shares remain unaffected.

This change does not promise continuous sharing after force-stop, permission revocation or OS termination. Android currently ends shares when its task is explicitly removed; restored server sessions are available for stopping but do not automatically resume transmission. Those are separate lifecycle cases from Home/lock-screen background sharing.

Higher update frequency can increase battery use. The Android interval remains 15 seconds with a 10-second minimum; iOS transmission is throttled to 15 seconds. Real background cadence and power use still need physical-device measurement.
