# Rebrand checklist — brand colour and logo

> **Status: READY, nothing changed yet.** Written 2026-08-17 against `e3ec6b2` so the new
> values can be dropped in without hunting for the files first.
>
> Current brand: **NOCTURNE** — primary aubergine `#2E2440` (light) / `#B59BE0` (dark),
> accent amber `#B57210` / `#E8A33D`, ground `#F1EEF5` / `#0D0B14`, surface `#FFFFFF` /
> `#1C1826`. The previous brand was PEACOCK (teal `#0E6F68` / ember `#C25022`), so this has
> been done once before — the token *names* did not change then, and they should not now.

---

## Read this first: every colour is a PAIR, and one value will not do

The app ships light and dark plus a Light/Dark/System override, and the primary **lifts**
between them (`#2E2440 → #B59BE0`) for a reason recorded in `tokens.json`: one fixed value
always fails one of the two grounds. The deep aubergine is legible as text on the light
ground and invisible on near-black.

So a new brand needs **two values per token, contrast-checked against both grounds** — UI
surfaces at 3:1, text at 4.5:1 (WCAG AA). The existing palette carries measured ratios in its
comments, and several values were already adjusted away from the original design study
because they failed: `BubbleSentDark` was lifted from `#4A3B66` (1.96:1, no visible boundary
between consecutive messages), and the light amber was darkened to `#B57210` because the
bright one measured 1.88:1 on the light ground. **Expect the same to happen again.** A brand
colour that only works in one theme is the single most likely way this goes wrong.

---

## Colour — the seven places to edit

There is no codegen. `tokens.json` says so plainly ("MIRROR, NOT SOURCE… iOS is the reference
when the two disagree"), so all seven are hand-synced and all seven must move together.

### 1. iOS — the reference

- [ ] `apps/ios/Voiid/Voiid/DesignSystem/Theme.swift` — `VoiidColor`, ~L48–L110.
      Hex ints (`dyn(0x2E2440, 0xB59BE0)`), light first. **This file wins when the platforms
      disagree**, so change it first and derive the rest from it.

### 2. Android — the twin

- [ ] `apps/android/app/src/main/java/com/voiid/app/ui/theme/Color.kt` — `VoiidPalette`,
      ~L146–L200. `Color(0xFF2E2440)`, note the `FF` alpha prefix.
- [ ] `apps/android/app/src/main/res/values/colors.xml` — `voiid_primary`,
      `voiid_background`, `voiid_field_fill` (light).
- [ ] `apps/android/app/src/main/res/values-night/colors.xml` — the same three (dark).

  The two XML files are a **deliberate** duplicate, not sloppiness: the launch window is
  drawn by the platform before Compose is alive, so it cannot read the Kotlin tokens. Miss
  the night file and every cold start in dark mode flashes the light ground for a frame.
  `themes.xml` and the call icons reference `@color/voiid_*` and need no edit.

### 3. Web

- [ ] `apps/web/app/globals.css` — 60 custom properties. Light block ~L22–L65, dark block
      from ~L160. Lowercase hex here.
- [ ] `apps/web/app/layout.tsx` L36–38 — **the one leak that cannot be tokenised.** A
      `<meta name="theme-color">` is read by browser chrome before any stylesheet is parsed,
      so `var()` is unavailable. Must stay equal to `--color-background` in both themes.
      The file says so; keep that comment true.

### 4. Admin web — its own palette, different names

- [ ] `apps/admin-web/app/globals.css` L7–L14 — `--bg`, `--surface`, `--border`, `--text`,
      `--text-dim`, `--primary`, plus `color: #17121f` at ~L36 (button label on primary).

  These are **not** the same token names as `apps/web`, so a find-replace tuned to
  `--color-primary` will silently skip this file. Dark-only, and `--border` / `--text-dim`
  are *derived* from the brand hue — re-derive them rather than substituting.

### 5. The mirror doc

- [ ] `packages/design-tokens/tokens.json` — the whole `color` block, plus the `$comment`
      prose at L9 and L1 which names both the old and new brand by hex.

### 6. Tracked scaffold copies — decide before you spend time

- [ ] `.mapcheck/app/globals.css` + `.mapcheck/app/layout.tsx`
- [ ] `apps/_clipscheck/app/globals.css` + `apps/_clipscheck/app/layout.tsx` +
      `apps/_clipscheck/components/FeatureCard.module.css`

  These are full forks of the web app, **tracked in git** (last touched in `af0b145`), each
  with its own copy of every value. Either update them or delete them — leaving them is how
  the next person finds two different brands in one repo. `out/` build output in each
  contains baked hex: regenerate, never hand-edit.

### 7. Docs (cosmetic, do last)

- [ ] `apps/web/README.md` (token table), `docs/LANDING_PAGE_BRIEF.md`,
      `docs/research/06_reels_ui.md`

---

## Logo — three different implementations, one mark

This is the part most likely to surprise you: **the wordmark is drawn a different way on
every platform.** A single new SVG does not drop in everywhere.

| Surface | How "voiid" is rendered | File |
|---|---|---|
| iOS | **SVG image asset** | `Assets.xcassets/VoiidWordmark.imageset/voiid-wordmark.svg` |
| Android | **Text** in the Urbanist logo face | `ui/components/Components.kt:284` `VoiidWordmark()` |
| Web | **CSS-drawn text** with a custom drawn i-dot pair | `apps/web/components/Wordmark.tsx` + `.module.css` |

- [ ] **iOS wordmark** — replace `voiid-wordmark.svg`. Note the current file's fills are
      `#E8E0E0` / `white`, i.e. drawn for **dark grounds**, and it is used at 0.22–0.3 opacity
      as a watermark (`Components.swift:42`, `GroupInfoView.swift:99`, `ChatsHomeView.swift:832`,
      `DraggableChatGrid.swift:255`, `CreateProfileScreen.swift:104`). If the new brand is
      light-ground-first, a near-white mark disappears — supply both, or tint at the call site.
- [ ] **iOS logomark** — `Assets.xcassets/VoiidLogoMark.imageset/voiid-logomark.png` (268K).
- [ ] **Android logomark** — `res/drawable-nodpi/voiid_logomark.png` (268K, same asset).
- [ ] **Android wordmark** — decide whether it stays as text or switches to the image. If the
      new mark has any drawn detail (like the web version's i-dots) text will not reproduce it,
      and the two platforms will diverge visibly.
- [ ] **Web wordmark** — `Wordmark.tsx` draws the i-dots as elements ("one filled, one hollow
      — a sealed thing and its counterpart key"). If the new mark drops that idea, this
      component is rewritten, not recoloured.

---

## Four things that are broken or missing right now

Found while inventorying. None is a value to change — each is something absent. Worth doing
in the same pass, because they are all "brand reaches this surface" work.

1. **iOS has no app icon.** `AppIcon.appiconset/Contents.json` declares universal + dark +
   tinted 1024 slots and contains **no PNG files**. Needs artwork, in all three appearances.
2. **iOS global tint is not the brand.** `project.pbxproj:450` and `:505` set
   `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor`, but
   `AccentColor.colorset/Contents.json` has no colour components — so every system control
   tints **default iOS blue** today, not aubergine. Fill the colorset (both appearances).
3. **Android launcher icon is still the stock green robot.** `ic_launcher_background.xml:8`
   is `#3DDC84` (Android green) with the default bugdroid foreground, plus default
   `ic_launcher*.webp` rasters at all five densities. The brand never reached it.
4. **No Android notification accent.** No `setColor`, no `notification_color` resource, no
   `com.google.firebase.messaging.default_notification_color` in the manifest — so
   notification chrome uses the system accent. The iOS NSE likewise sets no tint.

---

## Suggested order

1. Agree the **pairs** — light and dark for primary, accent, ground, surface — and check
   contrast on both grounds before touching code. This is where the work actually is.
2. `Theme.swift` first (the reference), then `Color.kt`, then the two `colors.xml`.
3. Web: `globals.css`, then the `layout.tsx` meta, then `admin-web`.
4. `tokens.json` to match, then decide the scaffold-copy question.
5. Logo assets, and the wordmark-rendering decision for Android.
6. The four gaps above: iOS app icon, iOS AccentColor, Android launcher, notification accent.

## Verifying you did not miss one

```bash
# Old brand should return NOTHING outside docs and build output once done.
grep -rniE "2e2440|b59be0|b57210|e8a33d|f1eef5|0d0b14|1c1826" \
  --include="*.swift" --include="*.kt" --include="*.xml" --include="*.css" \
  --include="*.tsx" --include="*.json" \
  apps packages | grep -v node_modules | grep -v "/out/" | grep -v "/build/"
```

Then build all three: `xcodebuild` for iOS, `./gradlew assembleDebug` for Android,
`npm run build -w apps/web`. A colour change cannot break a test, so the build and your own
eyes on both themes are the only checks that mean anything here.
