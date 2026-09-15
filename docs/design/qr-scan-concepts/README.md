# Scan QR design concepts

Generated with the built-in image generation tool. Concept images only; these are not app screenshots. Typography, illustrative QR codes, icons and decorative copy are provisional. Implementation must use actual community data and the existing theme tokens.

Recommended: 01 camera + join sheet, with a brief frame-to-sheet transition inspired by 03. Flow: scan → resolve community → preview → explicit Join (or Request to join) → confirmed result. Show official status only from server data. Keep expired/revoked invite, offline, camera permission, already-member and request-pending states explicit. Keep linked-device authorization in its dedicated flow. Respect reduced motion. No code changes made as part of concept generation.

## Approved implementation

Option 2 was approved after installation and launch in the separate Voiid UI app on Nehal’s iPhone 15 over the local network. The main iOS app now uses the framed camera, a community preview and a profile preview with the existing Contact PIN/request flow. It follows the user's selected light/dark appearance.

The scanner stops on capture, resolves the scanned identity using the existing services, and waits for an explicit action. Scan again returns to the camera. Community approval, existing membership, expired invites, lookup failures and profile request outcomes have distinct states. Linked-device scanning is separate. The camera supports a flashlight and stops it on capture, dismissal and backgrounding.

The Voiid UI project's `QR/QRDemoAdapters.swift` is sample-only and must never be copied into the main app. The main app uses its existing `ContactPinService`, `CommunityService` and avatar cache. UI review/test source lives in `/Users/devacc/Voiid Ui/Voiid Ui/QA/Scanner/`.

## Verified delivery

- Main app signed build passed; Firebase startup-resource check passed.
- Built source snapshot matches all four changed main-app source files.
- Main app `in.voiid.app` installed and launched on Nehal’s iPhone 15 over the network on 2026-09-10.
- Native UI demo suite: **4 tests passed, 0 failures**. Covers PIN gating, request confirmation, mutual contacts, explicit community joining, already-member state, approval, expired invites, offline retry and large text. These use local demo services, not a live cross-account backend test.
- Community QR parser: **17 checks passed** against the production parser.
- [Native screenshots](implemented/) show the implemented layout with labelled sample data. Result bundle: `/tmp/voiid-qr-ui-approved.xcresult`.

## Android implementation and APK

Android now implements option 2 with the framed camera, flashlight, profile lookup/Contact PIN/request confirmation, and community preview/explicit join. Scan again returns to the camera. Real services supply identity, membership and approval state; there are no demo adapters in the APK. Camera analysis handles padded luminance rows and releases its own camera use cases on dismissal. Discover communities has a persistent entry, including when the membership list is empty.

- Debug APK assembly and signing verification passed. All **130 JVM tests passed**, including five camera luminance packing cases. The lint ratchet passed at the existing **90 errors**; full lint is not clean.
- All Android source files in the build snapshot match the workspace. Native encryption libraries are included for arm64-v8a, armeabi-v7a, x86 and x86_64.
- Shareable file: `build/share/Voiid-Android-2026-09-10-test.apk` (165.7 MiB), with an adjacent SHA-256 checksum. Package `in.voiid.app`, Android 7.0+, existing debug signing identity, API `https://api-dev.voiid.app`. This is a test distribution, not a production-signed release.
- SHA-256: `38b9f4c4556c520e7548611bf521826c65bac287130fe2ac0a33e2af175b2f6c`.
- No Android device was connected for live camera/UI or cross-account verification. The iOS demo screenshots above are not Android runtime evidence.

## Generation prompts

### 01-camera-sheet

Use case: ui-mockup. Generate a polished high fidelity mobile app design comparison board for Voiid, a messaging app. Landscape canvas with two large straight-on phone screens side by side, fully visible and readable, minimal device frames, no perspective. Left screen scanning QR; right screen the community preview after successful scan, BEFORE joining. Native iOS SF Pro Rounded style, excellent spacing, accessible large tap targets, restrained realistic production UI. Actual Voiid palette: primary teal #13828C with white button text; dark ground #080C0E, cards #111719, raised #182124, primary text #F6F8F8, secondary #A6B0B2, light teal text #68B8BD. Light alternative ground #F6F8F8 cards white text #101617. Community shown is "Voiid Jobs", badge "Official", metadata "Public community", description "Jobs and opportunities from Voiid." No invented member counts, no encryption claims, no auto-join. Button "Join community", secondary "Scan again". Scan title "Scan QR", helper "Scan a Voiid profile or community code". Camera shows a subtle realistic paper QR against a dark desk. QR is illustrative, no need functional. No payment branding, no neon, no holographic effects, no excessive gradients, no ornamental dashboards. Board labels outside phones, crisp typography.
Direction 01 titled "01 / Camera + join sheet". Dark mode. Immersive edge to edge camera, simple white corner brackets and thin quiet teal scan line; close control upper left, flashlight round control below scanner. Right screen freezes and dims camera, native bottom sheet with drag handle taking lower half, community icon square with rounded corners, official badge, clear public-community identity, compact description, full-width teal Join community button and understated Scan again. Premium tactile minimal native app. Small board subtitle "Scan → Preview → Join".

### 02-framed-scanner

Use case: ui-mockup. Generate a polished high fidelity mobile app design comparison board for Voiid, a messaging app. Landscape canvas with two large straight-on phone screens side by side, fully visible and readable, minimal device frames, no perspective. Left screen scanning QR; right screen the community preview after successful scan, BEFORE joining. Native iOS SF Pro Rounded style, excellent spacing, accessible large tap targets, restrained realistic production UI. Actual Voiid palette: primary teal #13828C with white button text; dark ground #080C0E, cards #111719, raised #182124, primary text #F6F8F8, secondary #A6B0B2, light teal text #68B8BD. Light alternative ground #F6F8F8 cards white text #101617. Community shown is "Voiid Jobs", badge "Official", metadata "Public community", description "Jobs and opportunities from Voiid." No invented member counts, no encryption claims, no auto-join. Button "Join community", secondary "Scan again". Scan title "Scan QR", helper "Scan a Voiid profile or community code". Camera shows a subtle realistic paper QR against a dark desk. QR is illustrative, no need functional. No payment branding, no neon, no holographic effects, no excessive gradients, no ornamental dashboards. Board labels outside phones, crisp typography.
Direction 02 titled "02 / Framed scanner". Light mode native layout, pale neutral page, bold dark Scan QR header, spacious rounded camera rectangle contained in page occupying middle, fine teal corner marks. Caption below and a flashlight pill. Right screen a dedicated clean community preview page on pale background with large elegant white information card, abstract teal community icon, official badge, short metadata and description, generous whitespace; bottom pinned teal Join community button above secondary Scan again. Distinct editorial clean hierarchy, no bottom sheet, no glass. Small board subtitle "A clearer, focused layout".

### 03-focus-card

Use case: ui-mockup. Generate a polished high fidelity mobile app design comparison board for Voiid, a messaging app. Landscape canvas with two large straight-on phone screens side by side, fully visible and readable, minimal device frames, no perspective. Left screen scanning QR; right screen the community preview after successful scan, BEFORE joining. Native iOS SF Pro Rounded style, excellent spacing, accessible large tap targets, restrained realistic production UI. Actual Voiid palette: primary teal #13828C with white button text; dark ground #080C0E, cards #111719, raised #182124, primary text #F6F8F8, secondary #A6B0B2, light teal text #68B8BD. Light alternative ground #F6F8F8 cards white text #101617. Community shown is "Voiid Jobs", badge "Official", metadata "Public community", description "Jobs and opportunities from Voiid." No invented member counts, no encryption claims, no auto-join. Button "Join community", secondary "Scan again". Scan title "Scan QR", helper "Scan a Voiid profile or community code". Camera shows a subtle realistic paper QR against a dark desk. QR is illustrative, no need functional. No payment branding, no neon, no holographic effects, no excessive gradients, no ornamental dashboards. Board labels outside phones, crisp typography.
Direction 03 titled "03 / Focus transition". Dark mode. Left scanner on dark camera with large subtly rounded square brackets and a small bottom guidance card containing the helper, discreet flashlight control. Right is after scan, background camera blurred and darkened, brackets visually resolve into a centered raised community preview card with slim subtle teal outline, small label "Community found" (not Joined), large teal icon, Voiid Jobs name, Official badge and Public community, short description, generous full width Join community button inside card; Scan again underneath outside card. Extremely restrained dimensionality, polished realistic SwiftUI composition, no confetti or false security indicators. Small board subtitle "Scan frame becomes the preview".

## iOS camera detection follow-up

Removed preview-derived metadata cropping, which could be computed before a live capture connection was ready; metadata now scans the full sensor frame. Rear wide-angle camera selection, continuous focus/exposure, preview rotation, and startup torch-state reporting are explicit. Runtime errors/interruption show a retry action, and dismantling clears error callbacks as well as scan callbacks. Signed iOS build and startup resource checks passed. A real-device scan is still required to confirm the reported failure is resolved.
