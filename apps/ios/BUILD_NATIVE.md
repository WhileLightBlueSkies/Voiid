# VOIID iOS — Build & Run (dummy frontend)

> The iOS app is a **fully interactive dummy build** — no backend, no crypto. Everything runs on
> local state so you can experience the whole app on a device/simulator. Built to the Figma design
> (file: Voiid App Design). Verify against Figma and send screenshots for pixel-tuning.

## Open & run
1. Open `apps/ios/Voiid/Voiid.xcodeproj` in **Xcode 16+** (project format requires it).
2. Select the **Voiid** scheme + an iPhone simulator (e.g. iPhone 15) or your device.
3. **Run (⌘R).** That's it — files are auto-included (see "Project structure" below).

## 🔴 REQUIRED: add the Urbanist font — the logo lettering depends on it
The "voiid" wordmark uses **Urbanist Bold**. The font is **NOT bundled** (binary), so you must add it.
Without it iOS falls back to the system font and **the lettering will look wrong** (this is the #1
cause of "logo doesn't match Figma").

**`UIAppFonts` is already registered in the project** (`= "Urbanist-Bold.ttf"`), so you only need to
add the file:

1. Download **Urbanist** from Google Fonts → https://fonts.google.com/specimen/Urbanist (free, OFL).
2. Drag **`Urbanist-Bold.ttf`** into the `Voiid/` folder in Xcode → check **"Copy items if needed"**
   and the **Voiid target**. (Filename must be exactly `Urbanist-Bold.ttf`.)
3. Build & run. The wordmark should now render in Urbanist.

**Verify it loaded** (if the lettering still looks off): add this temporarily in `VoiidApp.init()`:
```swift
for f in UIFont.familyNames where f.contains("Urbanist") { print("✅", UIFont.fontNames(forFamilyName: f)) }
```
You should see `Urbanist-Bold`. If nothing prints, the file wasn't added to the target.

**If `UIAppFonts` build-setting doesn't take** (varies by Xcode): create a real `Info.plist`, add
`Fonts provided by application → item 0 = Urbanist-Bold.ttf`, set `INFOPLIST_FILE` to it, and set
`GENERATE_INFOPLIST_FILE = NO`. (The build-setting form works on most Xcode 16+ setups.)

> The code references the PostScript name **`Urbanist-Bold`** (see `VoiidWordmark` in OnboardingFlow.swift).
> If your file's PostScript name differs, update the string there.

Everything else uses **SF Pro Rounded** (system `.rounded` design — no font files needed).

## Project structure (auto-synced)
This project uses Xcode's **synchronized folders** (`PBXFileSystemSynchronizedRootGroup`), so every
`.swift` file inside `Voiid/` is compiled automatically — no manual "Add Files" step. Layout:

```
Voiid/
  VoiidApp.swift            app entry
  ContentView.swift         root router (onboarding ↔ main) + injects stores
  DesignSystem/             Theme (tokens), Components, Haptics
  Models/                   Models, DummyData, Stores (local interactive state)
  Onboarding/               Splash, Terms, Phone, OTP, Signup, Create Profile
  Main/                     RootTabView, ChatsHome, ChatDetail, VoiceNote,
                            AIChatView, ClipsViews, DateFormatting
```

## What works (all on dummy data)
- **Onboarding**: Splash → Terms (agree) → Phone → OTP (auto-advance) → Signup → Create Profile → app.
- **Chats**: grid of avatar cards, Chats/Groups tabs, search.
- **Chat**: send text → animated **sent → delivered → read** ticks, **timestamps**, **date separators**
  (Today/Yesterday/date), **typing indicator**, **auto-reply** simulation.
- **Voice notes**: press-and-hold mic to record (timer + live waveform), release to send; tap to play back.
- **Images**: pick from library → sends as an image bubble; tap to view fullscreen.
- **AI**: chatbot screen with "thinking" indicator + canned replies.
- **Clips**: feed → fullscreen (like/comment/share) → comments sheet → new-clip upload.
- Haptics + spring animations throughout.

## Permissions
Camera / microphone / photos / contacts usage strings are set in the target build settings
(`INFOPLIST_KEY_NS*UsageDescription`). iOS will prompt on first use.

> Note: the project has `ENABLE_APP_SANDBOX = YES` (it targets macOS too). If you build the **macOS**
> variant and camera/photos misbehave, that's the sandbox — for **iOS** simulator/device it's fine.

## Pixel-tuning loop
I built to exact Figma values but can't render here. Run it, compare to Figma, and send screenshots
of anything off (esp. the embossed logo shadow + bubble spacing) — I'll adjust.
