# VOIID — WebRTC dependency pinning & security tracking

> WebRTC (libwebrtc) parses untrusted network input (SDP, RTP/RTCP, STUN, media
> frames) from anyone who can call you. It has a real CVE history. Google no
> longer ships official prebuilt mobile binaries, so both our platforms depend on
> **third-party builds of upstream libwebrtc** — which means *we* own the job of
> pinning them and pulling security updates.
>
> Last updated: 2026-07-20

---

## Current pins

| Platform | Source | Version | Pinned how |
|---|---|---|---|
| **Android** | [GetStream/webrtc-android](https://github.com/GetStream/webrtc-android) — `io.getstream:stream-webrtc-android` (Maven Central) | **1.3.8** | Exact version in `apps/android/gradle/libs.versions.toml` (`streamWebrtc = "1.3.8"`), referenced via `version.ref`. No version range, no `+`. ✅ |
| **iOS** | [stasel/WebRTC](https://github.com/stasel/WebRTC) — prebuilt `WebRTC.xcframework` | see `apps/ios/vendor/README.md` | Vendored binary at `apps/ios/vendor/WebRTC.xcframework` (**gitignored**, like the Firebase vendor). ⚠️ |

**Note on the iOS binary:** the framework's own `CFBundleShortVersionString` is a
placeholder (`1.0`), so the real version is **not recoverable from the artifact**.
It must be recorded at fetch time — that's what `apps/ios/vendor/README.md` is
for (exact release tag + download URL + how to re-fetch). Keep it accurate; it is
the only record of what we ship.

**Why the iOS one is gitignored:** it's ~93 MB. Same tradeoff as the vendored
Firebase SDK. The cost is that a fresh clone can't build iOS until the framework
is fetched — hence the README with the exact version and fetch steps.

---

## How to update (do this when a CVE lands, and on a routine cadence)

### Android
1. Check for a newer release: <https://github.com/GetStream/webrtc-android/releases>
   (note which upstream libwebrtc milestone, e.g. `M125`, it corresponds to).
2. Bump `streamWebrtc` in `apps/android/gradle/libs.versions.toml`.
3. `./gradlew :app:assembleDebug` → must reach `BUILD SUCCESSFUL` + produce an APK.
4. Smoke-test a real 1:1 call on a device (WebRTC API breakage between milestones
   is common — a green build is not sufficient).

### iOS
1. Check <https://github.com/stasel/WebRTC/releases> for a newer prebuilt.
2. Download the new `WebRTC.xcframework`, replace `apps/ios/vendor/WebRTC.xcframework`.
3. **Update `apps/ios/vendor/README.md` with the new version + URL** (this is the
   only version record — do not skip).
4. Rebuild: `xcodebuild -project apps/ios/Voiid/Voiid.xcodeproj -scheme Voiid \
   -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
   -configuration Debug build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`.
5. Smoke-test a real 1:1 call on a device.

---

## Tracking process (the "track" half)

- [ ] **Watch upstream security advisories:** Chrome releases carry libwebrtc
      fixes — <https://chromereleases.googleblog.com/> (WebRTC CVEs appear in
      Chrome stable notes) and the WebRTC bug tracker. Also watch both vendor repos'
      releases (GitHub "Watch → Releases only" on GetStream/webrtc-android and
      stasel/WebRTC).
- [ ] **Quarterly review** even with no CVE — vendors lag upstream, and drifting
      many milestones behind makes the eventual jump risky. Don't let it rot.
- [ ] **Treat a libwebrtc CVE as high priority.** Attack surface is reachable by
      anyone who can initiate a call to a user; some historical bugs are
      pre-authentication and memory-unsafe (C++).
- [ ] **Record every bump** (version → version, upstream milestone, date, reason)
      in the commit message so there's an auditable history.
- [ ] Consider automating the Android check via Renovate/Dependabot (Maven
      coordinate is standard). The iOS vendored binary **cannot** be automated by
      those tools — it needs the manual step above, which is exactly why the README
      version record matters.

---

## Why we don't build libwebrtc ourselves (and when we might)

Signal builds libwebrtc from their own patched fork and wraps it in **RingRTC**.
That gives maximum control and immediate patching, at the cost of a heavy build
pipeline (depot_tools, GN/Ninja, multi-hour cross-platform builds) and owning
every merge from upstream.

**We deliberately do not use RingRTC** — it is Signal code, and staying clear of
Signal code is a hard requirement for this project. Using neutral third-party
builds of *upstream* libwebrtc keeps us clean.

Revisit building in-house only if: (a) vendors stop tracking upstream promptly,
(b) we need patches they don't carry, or (c) supply-chain review demands we build
from source we control. Until then, pin + track is the right tradeoff.

---

## Supply-chain note

Both builds are **third-party binaries**. Mitigations worth doing:
- [ ] Record a **SHA-256 checksum** of the vendored iOS xcframework in the vendor
      README, and verify it on re-fetch (protects against a swapped artifact).
- [ ] Gradle **dependency verification** for the Android artifact (checksum/signature
      pinning) — the Android build already supports it.
- [ ] Fetch releases over HTTPS from the canonical repos only.
