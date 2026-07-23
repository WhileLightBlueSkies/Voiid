# apps/ios/vendor — pinned binary dependencies

The contents of this directory are **gitignored** (they're large prebuilt
binaries), so the exact versions live here instead. Anyone setting up a fresh
checkout re-fetches them with the commands below, and any security update to
these dependencies is a deliberate, recorded bump of this file.

---

## WebRTC.xcframework

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
