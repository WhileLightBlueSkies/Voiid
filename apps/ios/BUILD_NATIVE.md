# VOIID iOS — Build & Run (dummy frontend)

> The iOS app is a **fully interactive dummy build** — no backend, no crypto. Everything runs on
> local state so you can experience the whole app on a device/simulator. Built to the Figma design
> (file: Voiid App Design). Verify against Figma and send screenshots for pixel-tuning.

## Open & run
1. Open `apps/ios/Voiid/Voiid.xcodeproj` in **Xcode 16+** (project format requires it).
2. Select the **Voiid** scheme + an iPhone simulator (e.g. iPhone 15) or your device.
3. **Run (⌘R).** That's it — files are auto-included (see "Project structure" below).

## ⚠️ Required: add the Urbanist font (for the "voiid" logo on Splash + Terms)
The logo wordmark uses **Urbanist Bold**. Without it, those two screens fall back to system bold.
1. Download Urbanist from Google Fonts (https://fonts.google.com/specimen/Urbanist) — free, OFL.
2. Drag **`Urbanist-Bold.ttf`** into the `Voiid/` folder in Xcode (check "Copy items if needed").
3. Add to Info: since this project uses `GENERATE_INFOPLIST_FILE = YES`, add the font via
   **Target → Info → Custom iOS Target Properties →** add `Fonts provided by application` (UIAppFonts)
   → item 0 = `Urbanist-Bold.ttf`.
4. The code references the PostScript name `Urbanist-Bold` (see `LogoMark` / `VoiidFont.logo`).

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
