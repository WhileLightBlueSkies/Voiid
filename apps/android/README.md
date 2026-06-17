# VOIID Android — Build & Run (dummy frontend)

> Native **Kotlin + Jetpack Compose (Material 3)** port of the iOS app. Same UI, fully
> interactive on local dummy state (no backend, no crypto) — built 1:1 from the iOS SwiftUI
> sources in `apps/ios`. Popups/sheets use **native** Android components (Material 3
> `ModalBottomSheet`, the system photo picker) per the design brief.

## Open & run
1. Open `apps/android` in **Android Studio** (Koala / Ladybug+), or build from the CLI:
   ```bash
   cd apps/android
   ./gradlew assembleDebug          # outputs app/build/outputs/apk/debug/app-debug.apk
   ./gradlew installDebug           # install on a running device/emulator
   ```
2. Run the **app** configuration on an emulator or device. Single activity, `MainActivity`.

Requires JDK 17 (set `JAVA_HOME`), Android SDK with API 36 + build-tools 36.

## Fonts (bundled — no setup needed)
Both faces ship as **variable fonts** in `app/src/main/res/font` (OFL, Google Fonts):
- **Urbanist** — the "voiid" logo wordmark (matches the iOS Urbanist requirement).
- **Nunito** — everything else; the rounded face chosen to match iOS "SF Pro Rounded".

The splash/terms logo is the same baked PNG used on iOS (`res/drawable-nodpi/voiid_logomark.png`).

## What works (all on dummy data — mirrors the iOS build)
- **Onboarding**: Splash → Terms (agree) → Phone (searchable country sheet) → OTP (6-digit
  auto-focus) → Signup → Create Profile (native photo picker) → app.
- **Chats**: avatar-card grid, Chats/Groups tabs (animated gradient underline), search.
- **Chat**: send text → animated **sent → delivered → read** ticks, timestamps, **date
  separators**, **typing indicator**, **auto-reply** simulation, voice notes (press-hold mic
  to record + waveform, tap to play), image messages, native photo picker.
- **AI**: assistant screen with a "thinking" indicator + canned replies.
- **Clips**: feed → fullscreen (like / comment / share) → comments sheet → new-clip upload.
- **Native haptics** (`View.performHapticFeedback`) + spring animations + the elastic bottom-nav
  pill throughout.

## Compatibility / older-OS fallbacks
- `minSdk = 24` (Android 7.0), `targetSdk = 36`. Broad device coverage.
- Adaptive launcher icons are under `mipmap-anydpi-v26`; PNG mipmaps cover API 24–25.
- Haptics degrade gracefully: `CONFIRM`/`SEGMENT_TICK` (API 30/34) fall back to
  `LONG_PRESS`/`CLOCK_TICK` on older releases.
- Photo/video picking uses `ActivityResultContracts.PickVisualMedia` (system photo picker on
  Android 13+, automatic fallback on older versions — no storage permission needed).
- Variable fonts apply per-weight axes on API 26+; on API 24–25 they render at the default
  weight (no crash).

## Project structure (mirrors the iOS layout)
```
app/src/main/java/com/voiid/app/
  MainActivity.kt           app entry + root router (onboarding ↔ main)
  ui/theme/                 Color, Type (fonts), Dimens (spacing/radii), Theme
  ui/components/            Components (button/field/avatar/wordmark), Haptics
  model/                    Models, DummyData, Stores (ViewModels: Session/Chat/AI/Clips)
  onboarding/               Splash, Terms, Phone, OTP, Signup, CreateProfile, CountryPicker
  main/                     RootTabView, ChatsHome, ChatDetail, ChatUI, VoiceNote,
                            AIChatView, Clips*, DateFormatting
```

## Notes / minor deviations from iOS (intentional, to feel native)
- Sheets (country picker, comments, new clip) are Material 3 **`ModalBottomSheet`** instead of
  iOS `.sheet` — the native Android popup, as requested.
- Chat detail and clip fullscreen are full-screen covers (system/gesture **back** returns to the
  previous screen).
