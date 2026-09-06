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

## TabTransitionCheck.swift (U05)

Models both implementations of the tab bar's "release the indicator stretch" timer
and runs U05's acceptance sequence — rapid A→B→C→A taps, 30ms apart, well inside
the 100–140ms release delays — against each.

```sh
xcrun -sdk macosx swiftc -O -o /tmp/tabcheck apps/ios/checks/TabTransitionCheck.swift
/tmp/tabcheck
```

The first check asserts the OLD behaviour still reproduces (an earlier tap's
uncancellable `asyncAfter` sets `isSliding = false` during a later transition). If
that check ever starts failing, the harness has stopped modelling the defect and
the remaining checks prove nothing.

Measured 2026-09-06: 90ms after the final tap, the old bar reports
`isSliding = false` — its stretch was cancelled mid-flight by a stale callback —
while the new bar reports `true` and releases on its own schedule.

## ChatHistoryCostCheck.swift (I01)

Measures what a long history costs on the path that runs while the user is typing,
using the real `DecryptedMessage` field shape, and models both the old and new read
paths.

```sh
xcrun -sdk macosx swiftc -O -o /tmp/chatcheck apps/ios/checks/ChatHistoryCostCheck.swift
/tmp/chatcheck
```

Measured 2026-09-06 on a development Mac (a phone is slower, so these are floors):

| history | encode whole conversation | as frames @60fps |
|---|---|---|
| 1,000 | 5.1 ms | 0.3 |
| 10,000 | 33.7 ms | 2.0 |
| 50,000 | 147.3 ms | 8.8 |

Cold-launch decode of one 50k shard: 130.7 ms. Taking the newest 50-message page
instead: 3.2 ms.

It also pins two correctness bugs, not just costs:
- `ORDER BY created_at ASC LIMIT 500` returns the **oldest** 500 messages, so opening
  a 10k-message chat showed "Message 0", not "Message 9950".
- A cursor on `created_at` alone stalls inside a block of tied timestamps: it reached
  **25 of 320** messages. The `(created_at, id)` keyset reaches all 320.

## PersistWindowCheck.swift (I01)

Guards a bug that making `persist()` async *introduced*, and which the async change
would otherwise have shipped: a message arriving while the write is suspended had its
dirty mark eaten by `dirtyConversations.subtract(committed)`, leaving it in memory,
not on disk, with nothing scheduled to retry — lost at exit.

```sh
xcrun -sdk macosx swiftc -O -o /tmp/persistcheck apps/ios/checks/PersistWindowCheck.swift
/tmp/persistcheck
```

Restore the `subtract(committed)` line and it must FAIL, printing an empty dirty set.
