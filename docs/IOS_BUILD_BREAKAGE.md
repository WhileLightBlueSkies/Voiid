# iOS build breakage — `main` does not compile

**Status as of 2026-08-24.** Android builds and runs. iOS does **not** compile, so it cannot be
installed or launched on a simulator or device.

Both faults are in committed code on `main`, in `Onboarding/` and `DesignSystem/`. Neither comes
from the cricket work in `Games/`.

---

## 1. `a127832` — "the brand moves off the lime to Tide"

The commit added `Onboarding/OnboardingKit.swift` (575 new lines) and rewrote
`DesignSystem/Theme.swift`, **deleting the lime palette**. The new file then calls a wordmark API
that has never existed, using the token the same commit removed:

```swift
// OnboardingKit.swift:164 and :167
BrandWordmark(size: Self.wordmarkSize, color: .white, dotColor: VoiidBrand.lime)
```

Two separate problems in one line:

| Referenced | Reality |
|---|---|
| `dotColor:` | `BrandWordmark` (`DesignSystem/BrandMark.swift:40`) declares only `size`, `color`, `opacity`. There is no `dotColor` parameter. |
| `VoiidBrand.lime` | Removed by this very commit. The brand moved to Tide, but 12 new references to `lime` were added alongside the removal. |

`BrandMark.swift` was last touched in `31f3710` ("Electric Lime"), well before this commit — so
the wordmark never gained the `dotColor` parameter the new code assumes.

**Compiler error**

```
Onboarding/OnboardingKit.swift:164:88: error: extra argument 'dotColor' in call
```

**Also affected:** `Onboarding/OnboardingFlow.swift:188` makes the same `dotColor:` +
`VoiidBrand.lime` call, and `Onboarding/VerifiedScreen.swift` carries 5 more `VoiidBrand.lime`
references.

**To fix, two product decisions are needed**

1. What colour is the wordmark dot now that lime is gone — a Tide token, or does the dot go away?
2. Should `BrandWordmark` gain a real `dotColor` parameter, or should the call sites drop it?

---

## 2. `3d873ef` — "the verified moment, and errors a user can act on"

A **half-finished refactor**. `OnboardingFlow.swift` was rewritten for a two-step
signup → profile handoff that carries a draft, but neither screen was updated and the draft type
was never written.

```swift
// OnboardingFlow.swift:28
case profile(draft: ProfileDraft)
```

`ProfileDraft` **is not defined anywhere in the repository.**

The flow also calls both screens with signatures they do not have:

| Call site (`OnboardingFlow.swift`) | Actual signature |
|---|---|
| `SignupScreen(onContinue: { draft in … })` | `onContinue: () -> Void` — takes no argument (`SignupScreen.swift:11`) |
| `CreateProfileScreen(draft: draft, onFinish:)` | only `onFinish` — no `draft` parameter |

`CreateProfileScreen` still manages `username`, `about` and `photo` in its own `@State`, i.e. it is
the older self-contained version that predates the intended handoff.

**Compiler errors**

```
Onboarding/OnboardingFlow.swift:28:29: error: cannot find type 'ProfileDraft' in scope
Onboarding/OnboardingFlow.swift:19:10: error: type 'OnboardingFlow.Step' does not conform to protocol 'Hashable'
Onboarding/OnboardingFlow.swift:19:10: error: type 'OnboardingFlow.Step' does not conform to protocol 'Equatable'
```

The `Hashable`/`Equatable` failures are downstream of the missing type: `Step` cannot synthesise
conformance while one of its cases has an unresolvable associated value.

**To fix, one product decision is needed**

Should signup collect a draft (username/photo) and pass it to the profile screen so the save
happens once on page two — the design the flow implies? Or should `profile` become a plain case
with no payload, matching the screens that exist today?

---

## Errors surface one file at a time

Swift stops at the first failing file, so these two faults appeared in **separate** build runs:
the first clean build reported only the `ProfileDraft` errors, the second only `dotColor`.

**There may be further breakage behind these two.** The build cannot be declared healthy until it
completes, not merely until these errors are gone.

---

## A caching trap worth knowing about

Builds run against an existing `-derivedDataPath` can report **`** BUILD SUCCEEDED **`** while the
app is broken. Xcode skips recompiling files it believes are unchanged, so a fault in a file you
did not touch is never re-surfaced.

The build product in that state is a shell — resource bundles only, with **no executable and no
`Info.plist`** — and the failure only appears at install time:

```
Simulator device failed to install the application.
Missing bundle ID.
Failed to get bundle ID from …/Voiid.app
```

**When verifying a build actually works, clear derived data first**, or confirm the product
contains a binary:

```sh
rm -rf /tmp/voiid-dd
xcodebuild -scheme Voiid -project apps/ios/Voiid/Voiid.xcodeproj \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/voiid-dd build

# a real product has these:
ls /tmp/voiid-dd/Build/Products/Debug-iphonesimulator/Voiid.app/Voiid
ls /tmp/voiid-dd/Build/Products/Debug-iphonesimulator/Voiid.app/Info.plist
```

---

## Platform status

| Platform | Builds | Runs | Notes |
|---|---|---|---|
| Android | ✅ `BUILD SUCCESSFUL` | ✅ | Verified on device `I2221` (Sony Xperia, wireless ADB) |
| iOS | ❌ | ❌ | Blocked on both faults above |
