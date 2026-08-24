# apps/ios/vendor — pinned binary dependencies

The contents of this directory are **gitignored** (they're large prebuilt
binaries), so the exact versions live here instead. Anyone setting up a fresh
checkout re-fetches them with the commands below, and any security update to
these dependencies is a deliberate, recorded bump of this file.

---

## WebRTC — REMOVED as a vendored dependency (2026-08)

The vendored `stasel/WebRTC` M150 build was removed and the call stack now
compiles against **LiveKit's WebRTC fork**, delivered by the existing
`client-sdk-swift` SPM dependency as its `LiveKitWebRTC` product.

### Why

1. **True E2EE for 1:1 calls.** The frame-level encryption API
   (`RTCFrameCryptor` / `RTCFrameCryptorKeyProvider`, AES-GCM over every RTP
   payload) exists only in LiveKit's fork. Plain Google/stasel builds do not
   expose it, which is why 1:1 calls were DTLS-SRTP-only (audit finding B1/M5).
2. **One WebRTC per process.** The app already loaded LiveKit's fork through
   SPM alongside the vendored one; two libwebrtc runtimes in one process is a
   class-collision hazard we no longer carry.

### Consequences

- Every call-stack file imports `LiveKitWebRTC` instead of `WebRTC`.
- LiveKit's fork prefixes its Objective-C classes `LKRTC…` (e.g.
  `LKRTCPeerConnection`), so call-stack type names gained the prefix.
- Media stays P2P: direct device-to-device where ICE allows, TURN relay only
  as a fallback pipe. Frame encryption rides ON TOP of DTLS-SRTP with keys that
  never touch any server.
- Upgrades now follow `client-sdk-swift` releases
  (<https://github.com/livekit/client-sdk-swift/releases>), which bump the
  pinned `webrtc-xcframework` checksum in their own Package.swift.
- `apps/ios/vendor/WebRTC.xcframework` can be deleted from disk; nothing
  references it any more (`Voiid.xcodeproj` has no remaining entry).

---

<!-- The stasel/WebRTC section below is retained for history only. -->

## WebRTC.xcframework (REMOVED)

| | |
|---|---|
| **Version** | `150.0.0` (Chromium milestone **M150**) |
| **Source** | [stasel/WebRTC](https://github.com/stasel/WebRTC) — prebuilt Google WebRTC, BSD-3-Clause |
| **Release** | <https://github.com/stasel/WebRTC/releases/tag/150.0.0> (published 2026-07-11) |
| **Asset** | `WebRTC-M150.xcframework.zip` |
| **SHA-256 (zip)** | `f9890492b0016e4c88ab20f07867b8b420054caedc8a692b2ec6ac041f3cf6b2` |
| **SHA-256 (`ios-arm64/WebRTC.framework/WebRTC`)** | `2884d8adb224656b2570794aae4c429ef5064c2e3e2ab9a30eafd41daee2f7d3` |
| **Slices** | `ios-arm64`, `ios-x86_64_arm64-simulator`, `ios-x86_64_arm64-maccatalyst`, `macos-x86_64_arm64` |
| **Min OS** | iOS 12.0 (the app itself targets iOS 18) |

The version was confirmed by byte-for-byte SHA-256 comparison of the vendored
`ios-arm64` slice against the M150 release asset — the framework bundle itself
carries no version string (`CFBundleShortVersionString` is a useless `1.0`), so
**the checksums above are the only reliable identity**. Re-verify after any
re-fetch.

### Re-fetch

```sh
cd apps/ios/vendor
curl -L -o WebRTC-M150.xcframework.zip \
  https://github.com/stasel/WebRTC/releases/download/150.0.0/WebRTC-M150.xcframework.zip

# Verify BEFORE unzipping.
echo "f9890492b0016e4c88ab20f07867b8b420054caedc8a692b2ec6ac041f3cf6b2  WebRTC-M150.xcframework.zip" \
  | shasum -a 256 -c -

rm -rf WebRTC.xcframework
unzip -q WebRTC-M150.xcframework.zip
rm WebRTC-M150.xcframework.zip

# Confirm the slice we actually ship.
shasum -a 256 WebRTC.xcframework/ios-arm64/WebRTC.framework/WebRTC
# expected: 2884d8adb224656b2570794aae4c429ef5064c2e3e2ab9a30eafd41daee2f7d3
```

The Xcode project finds it via `FRAMEWORK_SEARCH_PATHS = $(PROJECT_DIR)/../vendor`
— no path changes needed as long as it lands at
`apps/ios/vendor/WebRTC.xcframework`.

### Upgrading

WebRTC ships security fixes on the Chromium cadence and is directly exposed to
untrusted network input (SRTP/ICE/DTLS from whoever is on the other end of a
call), so it is one of the highest-value dependencies to keep current. Watch
<https://github.com/stasel/WebRTC/releases>. To bump: change the version, URL and
both checksums above, re-run the re-fetch block, and rebuild — the API surface
used by `CallService.swift` (`RTCPeerConnectionFactory`, `RTCCameraVideoCapturer`,
`RTCAudioSession` manual-audio mode) is stable across milestones, but re-check
after each bump.

---

## firebase-ios-sdk

Also vendored here (checked out source, used for Firebase Auth phone/OTP).
**Version not yet pinned in this file** — whoever next touches the Firebase
integration should record the exact tag/commit and fetch command here in the same
format as WebRTC above.

```sh
# to find what's currently vendored:
cd apps/ios/vendor/firebase-ios-sdk && git describe --tags && git rev-parse HEAD
```
