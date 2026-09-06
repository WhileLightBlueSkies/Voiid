# 08 — Liquid Glass for iOS and Android

Baseline: `a2e24e5` · 2026-09-05 · All tasks TODO; fixes specified, not implemented.

## G01 — Build a shared material contract and capability-based Android renderer

**Priority:** P1 · **Evidence:** Requested capability gap · **Dependencies:** G02, A03; capture baseline before changes

**Current evidence:**
- iOS `apps/ios/Voiid/Voiid/Main/ChatsHomeView.swift:1016`: a private GlassCircle applies `.glassEffect(.regular.interactive(), in: Circle())` on iOS 26, otherwise `.ultraThinMaterial`.
- iOS `Main/RootTabView.swift:392`: `.background(.bar)`; this is not a custom app-wide liquid-glass implementation.
- Android `apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:907`, `:1015`: background alpha `0.86f`.
- Android `main/ContactProfileView.kt:937`: `glassCard` uses shadow/fill/border. Its comments document an intentional performance tradeoff; this task is a new requirement, not evidence that the old approximation was accidentally broken.
- No executable `RuntimeShader` or `RenderEffect` glass implementation was found in the Android app sources. References in comments are not implementations.

### Target and honest parity definition

Match geometry, material hierarchy, background response, edge highlights, perceived thickness, tint, interaction timing, and accessibility. Use the native iOS result as the visual reference on a documented OS version. Android's compositor/GPU output will differ; acceptance is close perceptual agreement and smooth interaction, not a claim of identical pixels.

Use glass mainly for floating navigation, compact toolbars, contextual controls, and selected sheets. Keep long-form content, message bubbles, forms, video frames, and dense lists readable with ordinary surfaces. Do not put a blur pass behind every row.

### Rendering tiers

| Platform/capability | Renderer | Requirements |
|---|---|---|
| iOS 26+ | Native `glassEffect`; `GlassEffectContainer` for related custom controls | Use public APIs; availability-gate; retain native interaction behavior |
| Earlier supported iOS | SwiftUI material + restrained edge/shadow | Same geometry and content layout; verify system accessibility response |
| Android API 33+, qualified device | Shared backdrop blur + optional AGSL edge refraction/highlight | GPU-resident backdrop; benchmarked; bounded surface region; safe shader failure fallback |
| Android API 31–32 | RenderEffect blur on a captured background layer + tint/border | No RuntimeShader; foreground text remains separate and sharp |
| Android API 24–30, low-power/low-tier, or unsupported backdrop | Existing styled translucent/opaque approximation | Keep hierarchy, corners, selected state, and contrast; no CPU screenshot blur loop |
| Any platform, reduced transparency/high contrast | Opaque or near-opaque surface | Legible content; no decorative refraction |

Android API constraints are verified in [AGSL documentation](https://developer.android.com/develop/ui/views/graphics/agsl) and [RenderEffect reference](https://developer.android.com/reference/android/graphics/RenderEffect). A RenderEffect filters its own layer content; applying blur to a toolbar does **not** automatically blur arbitrary siblings behind it. Backdrop capture/composition must be designed explicitly. Apple's [custom Liquid Glass guidance](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views) supports the native/container approach.

### Implementation steps, each independently reviewable

1. **G01a — Reference fixture.** Create a development-only material gallery on both native apps: light/dark ground, checkerboard/text/photo backdrop, scrolling content, one capsule, one circle, one toolbar and one sheet. Use identical logical sizes and fixture images. Capture iOS 26 reference screenshots and interaction video before tuning Android. Keep this out of user navigation in production.
2. **G01b — Shared API.** Add iOS `DesignSystem/VoiidGlass.swift` and Android `ui/components/VoiidGlass.kt` plus `ui/components/VoiidGlassHost.kt`. These are proposed new files. Expose material role, shape, tint, prominence, interactive state and fallback policy. Reuse existing theme tokens. Keep rendering policy out of individual screens.
3. **G01c — Backdrop host proof.** Separate one recorded content layer from foreground chrome in a shared coordinate space. Sample only the intersecting background region with blur padding; exclude the glass/foreground itself to prevent recursive feedback. Reuse GPU layers while dirty content updates. Track scroll, window insets, IME, density, clipping, rotation, and layout changes. Prove this on one toolbar before any app-wide migration.
4. **G01d — API 31 blur.** Apply blur to the background layer only. Cache effects by material/size/density; keep text/icons in an unfiltered foreground. Clip the effect to the correct shape without clipping its shadow. Test busy moving backgrounds and overlapping controls. Avoid per-frame bitmap allocation or readback.
5. **G01e — API 33 enhancement.** Add a small edge-only refraction/highlight shader only if the basic renderer meets budgets. Compile/cache shader instances away from hot draws, update uniforms without recomposing the full screen, clamp sample coordinates, handle premultiplied alpha and color space correctly. Never distort foreground text. Shader support alone does not qualify a slow device for this tier.
6. **G01f — Native surface exceptions.** Maps, camera previews, video SurfaceView, secure windows, and dialogs can use separate surfaces/windows that a Compose layer cannot capture correctly. Test each actual component. Use a legible fallback when a real backdrop is unavailable; do not add continuous PixelCopy/screenshots or change protected content handling to fake parity. A dialog window needs an explicit backdrop strategy, not assumptions about the parent host.
7. **G01g — Progressive rollout.** Migrate tab/header chrome first, then chat controls, call controls, and selected sheets. Keep profile/list cards conservative. Keep games and clip content renderers independent. Add a feature flag and renderer diagnostic available in development. Compare normal/low-power/thermal-stressed behavior; lower the tier when appropriate with hysteresis rather than flickering between modes.

### Initial calibration values — product starting points, not Apple internals

| Parameter | Starting value |
|---|---|
| Compact control shape | Circle/capsule; at least 44pt iOS / 48dp Android hit region |
| Toolbar/sheet corners | Role token; retain current 16dp sheet top corners initially; gallery may calibrate |
| Blur on sampled background | 16dp equivalent for compact chrome; 20dp for broader toolbar; convert to pixels once by density |
| Light tint alpha | 0.60 starting point; increase as needed for contrast |
| Dark tint alpha | 0.64 starting point; increase as needed for contrast |
| Fallback tint alpha | 0.94; opaque for accessibility mode |
| Edge highlight | 1 physical pixel, white alpha 0.18 light / 0.12 dark; tune in fixture |
| Press transform | 0.97 scale, 100ms response; interruptible release; no layout resize |
| Android settle | Existing sheet `dampingRatio=0.86`, `stiffness=380` initially; preserve consistency |
| Reduced-motion feedback | 140ms opacity/color transition; no refraction travel, parallax or overshoot |

Do not freeze these visual values as a correctness oracle. Record calibrated values and corresponding screenshots per role after device review. Contrast and frame budgets overrule decorative fidelity.

### Performance gate

Start with one shared backdrop producer per window/content region and a small bounded number of visible glass consumers. Reuse captured layers; never capture the full display into CPU memory per frame. Pause animation/capture when not visible. Proposed gate: additional p95 frame cost from glass ≤2ms on the chosen mid-tier test device and ≤1 percentage-point increase in janky frames versus identical non-glass interaction. Measure CPU/GPU, memory, and thermal behavior for at least ten minutes. These are project acceptance targets, not measurements from this audit.

### Verification and done criteria

- Native Android API 24/25, 30, 31/32, 33 and 36 branches run; at least one older/low-memory device and one 120Hz device are tested physically. API branch smoke checks may use emulators, performance gates may not.
- Bright/dark/busy backgrounds preserve readable text; TalkBack/VoiceOver semantics and focus order are unchanged. High contrast, large text and transparency/motion reduction work.
- Scroll, repeated tab taps, drag interruption, sheet/keyboard transitions and rotation have no stale backdrop, black rectangle, self-sampling, clipped halo or blurred foreground.
- Review side-by-side screenshots at equivalent logical sizes, plus slow-motion recordings of press, drag, and release. Log approved differences for lower tiers.
- No glass work runs offscreen; shader failure degrades without crashing; flag rollback restores the previous renderer and layout.

## G02 — Reconcile design tokens before generating more variants

**Priority:** P2 · **Evidence:** Confirmed drift · **Dependencies:** None

**Location:** `packages/design-tokens/tokens.json:10` defines aubergine primary `#2E2440/#B59BE0`; iOS `DesignSystem/Theme.swift:61` uses teal `#13828C`; inspect Android `ui/theme/Color.kt` and web `app/globals.css` as the current teal counterparts.

The shared JSON claims to be authoritative but disagrees with current clients. Glass colors created from it would introduce another visual system.

**Fix:** retain the current product teal unless explicitly rebranded. Reconcile semantic light/dark, foreground-on-material, status, shape, elevation and motion tokens. Mark intentional platform optical adjustments separately. Define one hex-alpha convention and validate it. Generate or check native/web representations from that contract; do not overwrite game-specific palettes mechanically. Add material tokens only after reference-fixture calibration.

**Done when:** a parity check catches changed/missing tokens, common components consume role tokens, and the material gallery matches the agreed current brand. Historical docs may describe old colors; current source and approved fixtures decide the implementation.
