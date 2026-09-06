# iOS bounds checks

Standalone measurement harnesses for iOS behaviour that has no unit-test target in
this project. Each is a single Swift file with a `main`, compiled for the simulator
and run there — no XCTest, no app launch.

They exist because "it compiles" proves nothing about a memory bound, and I02 asks
for measurement rather than a claim that a refactor made things faster.

## AvatarBoundsCheck.swift (I02)

Exercises the two bounding mechanisms in
`Voiid/Voiid/Networking/AvatarCache.swift` — ImageIO downsampling and the
cost-bounded `NSCache` — against real JPEG data.

```sh
UDID=$(xcrun simctl list devices available | grep -m1 'iPhone 16 Pro (' | grep -o '[0-9A-F-]\{36\}')
xcrun simctl boot "$UDID" 2>/dev/null
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator \
    -o /tmp/avatarcheck apps/ios/checks/AvatarBoundsCheck.swift
xcrun simctl spawn "$UDID" /tmp/avatarcheck
```

Measured 2026-09-06 (iPhone 16 Pro simulator):

| | before I02 | after |
|---|---|---|
| one 4000x3000 photo, resident | 411 MB | 1 MB |
| 600 avatars retained | 600 (~12150 MB) | 21 (~47 MB) |

The harness is kept honest the same way the backend tests are: run it against the
old implementation (plain `UIImage(data:)` into a `[String: UIImage]`) and four of
the nine checks must fail. If they all pass, the harness is measuring nothing.

Two bugs in the harness itself were found this way, and both are noted in the file:
inserting the same `UIImage` instance under every key (so `NSCache` saw one live
object and evicted nothing), and comparing an image's pixel dimensions against a
point value (a phantom "upscale" that never occurred).
