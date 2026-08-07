# Voiid Games — Animation Bible

> **Status:** specification. The motion language in §3 is the canonical source — [`GAMES_AUDIT.md`](./GAMES_AUDIT.md) §9 defers to this document.
> **Goal:** animation that reads as *alive, weighty and reactive* on both platforms, built entirely from native APIs — no game engine, no WebView, consistent with the repo's "stay native" rule ([`GAMES.md`](./GAMES.md) §4).
> **Companions:** [`GAMES_AUDIO.md`](./GAMES_AUDIO.md) (shares the timing table), [`GAMES_SNAKE_BUGS.md`](./GAMES_SNAKE_BUGS.md) Part B (**fix the camera before adding effects**), [`snake-play.md`](../snake-play.md) §16-17.

---

## Contents

1. [The platform asymmetry, stated up front](#1-the-platform-asymmetry-stated-up-front)
2. [Three layers, kept separate](#2-three-layers-kept-separate)
3. [The shared motion language](#3-the-shared-motion-language)
4. [Native capability matrix](#4-native-capability-matrix)
5. [Snake — the showcase](#5-snake--the-showcase)
6. [Tic Tac Toe, RPS, Hand Cricket](#6-tic-tac-toe-rps-hand-cricket)
7. [Navigation and shared-element motion](#7-navigation-and-shared-element-motion)
8. [Haptics as an animation channel](#8-haptics-as-an-animation-channel)
9. [Performance budgets and degradation](#9-performance-budgets-and-degradation)
10. [Accessibility](#10-accessibility)
11. [Build order](#11-build-order)

---

# 1. The platform asymmetry, stated up front

This is the single most important fact for planning animation work in Voiid:

| | iOS | Android |
|---|---|---|
| Deployment target | **18.0** | **minSdk 24**, target/compile 36 |
| Effective capability | Everything current | Tiered — key APIs start at 31 and 33 |
| GPU shaders | Metal, always | AGSL `RuntimeShader` **API 33+** |
| Blur / `RenderEffect` | Always | **API 31+** |
| Haptic primitives | Core Haptics, always | `VibrationEffect.Composition` **API 30+** |
| Shared-element transitions | `matchedGeometryEffect` / `.zoom` | `SharedTransitionLayout` (Compose 1.7, present) |

**iOS can be given a single, uniformly excellent implementation. Android cannot.** Android needs a deliberate three-tier design:

| Tier | API | What it gets |
|---|---|---|
| **A** | 33+ | AGSL shaders — visual parity with iOS Metal |
| **B** | 31-32 | `RenderEffect` blur + additive blending; close, no custom shaders |
| **C** | 24-30 | Compose `Canvas` with layered strokes; clean and readable, no glow |

Pretending Android is one platform is how this work goes wrong. Design tier C first — it must be *good*, not merely functional — then add A and B as enhancements. A player on Android 11 should get a game that looks intentional, not a broken version of the iOS one.

> **Rough coverage today:** API 33+ is a large majority of active devices and growing; API 24-30 is a small but real tail. Tier C is worth doing properly, and worth capping in ambition.

---

# 2. Three layers, kept separate

Every good real-time renderer keeps these apart. Conflating them is why "more animation" usually produces mush.

| Layer | Rate | Authority | Example |
|---|---|---|---|
| **Simulation** | 10 Hz (server) | server only | where the snake actually is |
| **Interpolation** | display rate | derived from buffered server frames | smooth motion between ticks |
| **Presentation** | display rate | **client-only, never authoritative** | glow, trails, particles, shake, squash |

The presentation layer is where "out of this world" lives, and it carries **zero correctness risk** — nothing in it can desync a match or change an outcome. That is the licence to be extravagant there, and the reason to be conservative in the other two.

> **Prerequisite.** The interpolation layer is currently broken on both platforms — the render clock is re-anchored to network arrival time every frame, so the whole scene jitters ([`GAMES_SNAKE_BUGS.md`](./GAMES_SNAKE_BUGS.md) Part B). **Adding presentation effects on top of a jittering camera will make things look worse, not better.** Fix the camera spring and render clock first; they are steps 1-2 of §11 for that reason.

---

# 3. The shared motion language

**One table, both platforms, all four games.** Divergence here is what makes two builds feel like different products, and it happens silently unless the numbers are written down.

### 3.1 Timing

| Motion | Curve | Duration | Notes |
|---|---|---|---|
| UI element enter | spring, damping 0.75 | 280 ms | ~4% overshoot |
| UI element exit | ease-in | 160 ms | **always faster than enter** |
| Button press down | spring, damping 0.5 | 90 ms | scale → 0.94 |
| Button release | spring, damping 0.6 | 140 ms | scale → 1.0 |
| Card → full screen | shared element | 350 ms | never a cross-fade |
| Sheet present | spring, damping 0.85 | 320 ms | |
| Sheet dismiss | ease-in | 200 ms | |
| Score tick-up | ease-out | 400 ms | count up, never snap |
| Panel in (death/game over) | ease-out + backdrop blur | 300 ms | slow-mo runs *underneath* it |
| Camera follow | critically damped spring | ~120 ms settle | never rigid |
| Screen shake | decaying sine | 200 ms | 3-6 px |
| Hitstop on kill | freeze | 120 ms | then 0.3× for 380 ms |
| Eat pop | spring, damping 0.4 | 180 ms | scale 1.0 → 1.18 → 1.0 |
| Mark place (TTT) | spring, damping 0.55 | 220 ms | |
| Win line sweep | ease-in-out | 450 ms | |

### 3.2 Springs, expressed natively

The same feel, written the way each platform wants it:

```swift
// iOS — SwiftUI. `response` is roughly the period; damping 0.75 gives slight overshoot.
.animation(.spring(response: 0.28, dampingFraction: 0.75), value: state)
// For physical motion prefer the newer form, which is defined in the same terms:
.animation(.spring(duration: 0.28, bounce: 0.25), value: state)
```

```kotlin
// Android — Compose. dampingRatio 0.75 ≈ SwiftUI dampingFraction 0.75.
animateFloatAsState(
    targetValue = target,
    animationSpec = spring(dampingRatio = 0.75f, stiffness = Spring.StiffnessMediumLow),
)
```

**Never use `Spring.DefaultDisplacementThreshold` blindly for pixel values, and never use a plain `tween` for anything that represents a physical object.** Menus tween; things with mass spring.

### 3.3 Colour and light rules

- **Neon on near-black.** The existing Snake palette is the right direction — commit to it and use it everywhere.
- **Every bright thing emits.** If it is saturated, it gets bloom. This single rule does more for the "out of this world" feel than any other item in this document.
- **Player colour is never the only signal.** Pair hue with a shape or pattern cue on the head — required for colourblind players (§10).
- **Lethal things pulse.** The arena border kills on contact and is currently visually silent about it.

### 3.4 Restraint rules — these matter as much as the effects

- Never animate two things competing for the same attention.
- Every effect is **interruptible**. A player action always wins over a playing animation.
- **60 fps is the floor, not the target.** An effect that costs frames is a net negative no matter how it looks in a screenshot.
- If an effect cannot be explained in terms of *what the player just did*, cut it.

---

# 4. Native capability matrix

What to actually reach for, per platform. Everything listed for iOS is available at deployment target 18.0.

### iOS

| Need | API | Notes |
|---|---|---|
| Per-frame custom rendering | `MTKView` + Metal | already used by Snake; correct choice |
| **Shaders on ordinary SwiftUI views** | `.colorEffect` / `.distortionEffect` / `.layerEffect` + `ShaderLibrary` | **iOS 17+. Underused and extremely powerful** — a real Metal shader on any view without leaving SwiftUI |
| Multi-step scripted animation | `.keyframeAnimator` | iOS 17+ |
| Discrete state cycling | `.phaseAnimator` | iOS 17+ |
| Shared element | `matchedGeometryEffect`, or `.navigationTransition(.zoom)` | `.zoom` is iOS 18 |
| Immediate-mode 2D | `Canvas` + `TimelineView(.animation)` | fine for board games; **not** for Snake (see below) |
| Gradient fields | `MeshGradient` | iOS 18 — excellent for arena backgrounds |
| Icon motion | `.symbolEffect(.bounce/.pulse/.variableColor)` | iOS 17+ |
| Haptics | Core Haptics `CHHapticEngine` | §8 |

> **Do not move Snake back to SwiftUI `Canvas`.** [`SnakeMetalView.swift:7-16`](../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift#L7-L16) records why it was moved off: trail state was mutated inside the draw closure while `@Published` frames re-entered the same view, and SwiftUI's render pass must be a pure function of state. That was a structural incompatibility, not a performance problem. `Canvas` remains right for the board games, which have no motion between frames.

### Android

| Need | API | Min | Fallback |
|---|---|---|---|
| Per-frame rendering | `withFrameNanos` + Compose `Canvas` | 24 | — |
| **GPU shaders** | `RuntimeShader` (AGSL) | **33** | layered strokes |
| Blur | `RenderEffect` / `Modifier.blur` | **31** | pre-baked gradient sprite |
| Additive blending | `BlendMode.Plus` on `DrawScope` | 24 | — |
| Cheap transforms | `Modifier.graphicsLayer` | 24 | — |
| Shared element | `SharedTransitionLayout` | Compose 1.7 ✓ | `AnimatedContent` cross-fade |
| Scripted animation | `Animatable` / `updateTransition` / `keyframes` | 24 | — |
| Haptic primitives | `VibrationEffect.Composition` | **30** | `createWaveform` (26) → `vibrate()` (24) |

**AGSL is the strategic choice.** It is essentially SkSL, so the same SDF/glow/bloom logic written once for Metal ports to Android with only syntax changes. One shader *design* serves both platforms — that is what keeps the two games looking like one game.

```kotlin
// Guard once, high up, and branch the whole render strategy — not per-effect.
val tier = when {
    Build.VERSION.SDK_INT >= 33 -> RenderTier.SHADER
    Build.VERSION.SDK_INT >= 31 -> RenderTier.BLUR
    else                        -> RenderTier.FLAT
}
```

---

# 5. Snake — the showcase

Snake is the only game with continuous motion and therefore the only one where animation is *gameplay* rather than polish.

### 5.1 Body rendering: signed distance fields, not stroked polylines

Draw the body as an SDF of capsules. This gives, in one pass and at essentially no cost: perfectly round joints, a glow that is a pure function of distance, an outline for free, and smooth blending where segments meet.

```metal
// Snake.metal — the primitive the entire body should be built from.
float sdCapsule(float2 p, float2 a, float2 b, float r) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}
```

Layer four things off that one distance value:

| Layer | Rule |
|---|---|
| Core | full-saturation fill where `d < 0` |
| Rim | `smoothstep` band at `d ≈ 0`, brighter on the head |
| Bloom | `exp(-d * k)` falloff outside the body, **additively blended** |
| Shimmer | low-amplitude sine along arc length, phase-shifted by time |

The bloom layer is what makes neon read as *emitting light* rather than merely being a bright colour. It is the highest-value single change in this document.

**Android tier A:** the identical logic in AGSL. **Tier B:** draw the body twice — wide and translucent under narrow and opaque — with `RenderEffect` blur on the wide pass. **Tier C:** three layered strokes at decreasing width and increasing alpha with `BlendMode.Plus`. Tier C will not match tier A, but it will look deliberate.

### 5.2 The camera is a character

Currently the camera is locked rigidly to the head with no smoothing on either platform. Four changes, in order of value:

1. **Follow spring** — critically damped, ~120 ms settle. *This alone removes most of the flicker in [`GAMES_SNAKE_BUGS.md`](./GAMES_SNAKE_BUGS.md) Part B and is the prerequisite for everything else here.*
2. **Look-ahead** — offset toward the heading, scaled by speed. The player sees where they are going instead of where they are.
3. **Mass zoom** — `1.0 → 1.35` across the mass range, so a big snake *feels* big. (A zoom already exists; it needs to be spring-damped rather than applied instantly.)
4. **Screen shake** — 3-6 px, 200 ms, decaying, on kills and near-misses only.

### 5.3 Particles — one instanced draw call

A single GPU buffer of ~2000 particles (`{pos, vel, life, colour, size}`), stepped on the CPU (trivial at this count) and drawn as instanced quads. The Snake renderer already draws instanced circles, so the pipeline exists.

**The events are already on the wire.** The server emits `{k: 'death'|'kill'|'eat'|'spawn', x, y, id, c}` ([`snake/index.ts:164-165`](../backend/games/src/engine/snake/index.ts#L164-L165)) and iOS parses them into `SnakeState.events` and renders almost nothing from them.

> **Android does not parse them at all** — `parseSnake` in [`GamesEngine.kt`](../apps/android/app/src/main/java/com/voiid/app/net/GamesEngine.kt) drops the field. **No VFX is possible on Android until that one line exists.** It is the cheapest unlock in the whole games surface.

| Event | Effect |
|---|---|
| `eat` | 6-10 sparks converging into the head + head scale pop (1.0 → 1.18 → 1.0, 180 ms) |
| `kill` | radial burst in the victim's colour, white flash, 120 ms hitstop, strong haptic |
| `death` (yours) | chromatic aberration pulse, desaturate over 400 ms, slow-mo to 0.3× for 500 ms |
| `spawn` | expanding ring; snake fades in over 250 ms with a shield shimmer for the `INVULN` window |
| boost (state) | continuous tail emission, screen-edge speed lines, mild FOV push |

### 5.4 Time as an effect

Hitstop and slow-mo are the cheapest impact tools in games and cost nothing but a multiplier on the presentation clock. **They must never touch the simulation or interpolation clocks** — the server is still running at normal speed and the match does not pause because you died.

### 5.5 HUD motion

- **Minimap** — specified in `snake-play.md` §19 and absent. With a 1400-radius arena and a head-locked camera, you cannot see danger coming.
- **Kill feed** — slides in, holds 3 s, fades. Events already on the wire.
- **Boost meter** — mass *is* the fuel (`MIN_BOOST_MASS: 12`) and the player cannot currently see how much is left. Pulses red when nearly empty.
- **Danger vignette** — directional edge glow that intensifies with proximity to the lethal border. Pair with `borderWarn` audio ([`GAMES_AUDIO.md`](./GAMES_AUDIO.md) §8.9). **This is information, not decoration** — it must exist in every render tier.
- **Live rank badge** — "#3 of 6" near your own head, animating on change.

---

# 6. Tic Tac Toe, RPS, Hand Cricket

Turn-based games get their character from **anticipation and consequence**, not continuous motion. The design goal is that every tap feels *answered*.

### 6.1 Tic Tac Toe

| Moment | Motion |
|---|---|
| Mark placed | Stroke **draws on** over 220 ms — X as two strokes 60 ms apart, O as an arc sweep. Never fade in. |
| Invalid tap | Cell shakes 3 px, 150 ms |
| Turn change | Active player's indicator scales 1.0 → 1.06 and glows; the other dims |
| Win | Line sweeps along the triple (450 ms), then the three winning cells pulse in sequence, 80 ms apart |
| Draw | Whole board desaturates over 400 ms |
| Board entry | Cells stagger in, 30 ms apart, spring damping 0.7 |

**The draw-on stroke is the whole trick.** A mark that fades in feels like data arriving; a mark that draws feels like someone placed it.

- iOS: `Path.trimmedPath(from:to:)` animated via `.keyframeAnimator`, or a `Shape` with an animatable `trimEnd`.
- Android: `PathMeasure.getSegment()` driven by an `Animatable`.

### 6.2 Rock Paper Scissors

| Moment | Motion |
|---|---|
| Countdown | Three beats — number scales 1.4 → 1.0 with spring, ticks rising in pitch |
| Commit | Chosen hand lifts and glows; opponent's slot shows a pulsing "?" |
| Reveal | **Both hands slam in from opposite sides**, meet centre, 100 ms hitstop on contact |
| Win | Winning hand scales up and glows; loser recoils and desaturates |
| Tie | Both bounce apart, neutral |
| Score | Pip fills with a spring, 200 ms |

The reveal is the entire game — it deserves the hitstop and the most attention. Currently it resolves with no impact at all.

### 6.3 Hand Cricket

Richest opportunity of the three, and it already has the best haptics in the app ([`CricketPitch.swift:186-190`](../apps/ios/Voiid/Voiid/Games/CricketPitch.swift#L186-L190)).

| Moment | Motion |
|---|---|
| Number pick | Button depresses, springs back, glows briefly |
| Ball bowled | Ball travels along an arc, 400 ms, ease-in |
| Runs scored | Ball deflects along a **trajectory that varies with the runs** — 1 is a nudge, 6 is a launch off-screen |
| Four | Ball skims the ground, boundary rope flashes |
| Six | Ball arcs high, leaves the frame, crowd-swell colour wash |
| Wicket | **Hard cut** — stumps scatter, screen shake, 150 ms hitstop, everything desaturates for 600 ms |
| Scoreboard | Runs **tick up** digit by digit over 400 ms, never snap |
| Innings change | Pitch rotates 180°, sides swap, 600 ms |

Distinct run trajectories are what make the game readable at a glance: you know it was a six before you read the number. Match the animation to the *existing* haptic map rather than inventing a second one — and port both to Android, which has neither.

---

# 7. Navigation and shared-element motion

The Games home is a grid of cards that open into full-screen games. **A card should transform into the game, never cross-fade to it.** That single transition does more for perceived quality than any in-game effect.

```swift
// iOS 18 — the zoom transition is purpose-built for exactly this.
GameCard(game: game)
    .matchedTransitionSource(id: game.id, in: namespace)
// destination:
.navigationTransition(.zoom(sourceID: game.id, in: namespace))
```

```kotlin
// Android — Compose 1.7 SharedTransitionLayout (present in BOM 2024.12.01).
SharedTransitionLayout {
    AnimatedContent(targetState = screen) { s -> /* … */ }
    // Modifier.sharedElement(rememberSharedContentState(key = "game-${'$'}{game.id}"), …)
}
```

Also worth doing:

- **Sheets spring, they do not slide linearly.** Damping 0.85, 320 ms.
- **The lobby is a waiting state and should feel alive** — a slow pulsing avatar, an animated "waiting for {name}" — not a static spinner.
- **Exiting a game returns to the card it came from**, reversed. The transition must be symmetrical or it reads as a different screen.

---

# 8. Haptics as an animation channel

Haptics are part of the animation, not a separate feature. Author them **with** the visual and the sound, from the same envelope.

Current state: iOS has 20 `Haptics.*` call sites using coarse `UIImpactFeedbackGenerator` presets. **Android games have zero.**

### iOS — add `GameHaptics` on Core Haptics

Keep [`Haptics.swift`](../apps/ios/Voiid/Voiid/DesignSystem/Haptics.swift) for UI taps; add a game-specific layer where envelope actually matters:

```swift
// A kill: sharp transient, then a short decaying rumble. Same shape as the sound
// in GAMES_AUDIO.md §8.6 — authoring both from the same numbers is what makes
// them land as one event rather than two.
let hit = CHHapticEvent(eventType: .hapticTransient, parameters: [
    .init(parameterID: .hapticIntensity, value: 1.0),
    .init(parameterID: .hapticSharpness, value: 0.9)], relativeTime: 0)
let rumble = CHHapticEvent(eventType: .hapticContinuous, parameters: [
    .init(parameterID: .hapticIntensity, value: 0.55),
    .init(parameterID: .hapticSharpness, value: 0.2)], relativeTime: 0.02, duration: 0.18)
```

### Android — three tiers again

| API | Use |
|---|---|
| 30+ | `VibrationEffect.Composition` — `PRIMITIVE_CLICK`, `PRIMITIVE_TICK`, `PRIMITIVE_QUICK_RISE`, `PRIMITIVE_QUICK_FALL`, composable with scale |
| 26-29 | `VibrationEffect.createWaveform(timings, amplitudes, -1)` |
| 24-25 | `Vibrator.vibrate(longArray, -1)` |

Use `VibratorManager` on 31+, the deprecated `getSystemService(VIBRATOR_SERVICE)` below. Always check `hasVibrator()` and `hasAmplitudeControl()`.

### The mapping (both platforms)

| Event | Haptic |
|---|---|
| Snake eat | light tick, intensity scaled by food value |
| Snake boost start | quick rise |
| Snake kill | sharp transient + 180 ms rumble |
| Snake death | heavy transient + 400 ms decaying rumble |
| Snake near border | soft pulse at ~2 Hz, intensity by proximity |
| TTT mark | light click |
| TTT win | three ascending ticks matching the cell pulses |
| RPS reveal | medium impact **exactly on the hitstop frame** |
| Cricket four/six | existing map — keep, and port to Android |
| Cricket wicket | heavy transient + shake |

---

# 9. Performance budgets and degradation

| Target | Value |
|---|---|
| Frame budget | 16.6 ms (60 fps) — **hard floor** |
| Ideal | 8.3 ms (120 fps) on ProMotion / high-refresh Android |
| Particles | ≤ 2000 concurrent (tier A/B), ≤ 300 (tier C) |
| Draw calls, Snake | ≤ 6 per frame |
| Bloom pass | half resolution, always |

**Measure, then degrade — never guess.** Both platforms can report frame time (`CADisplayLink.targetTimestamp` vs actual; `withFrameNanos` deltas). If the rolling average crosses 14 ms, step down in this order:

1. particle count → 50%
2. bloom → quarter resolution
3. bloom → off
4. shimmer / secondary effects → off
5. body detail → reduced point count

**Never degrade below the point where information is lost.** The danger vignette, the border pulse and the head/body distinction survive every tier — those are gameplay, not decoration.

---

# 10. Accessibility

Non-negotiable, and currently absent everywhere.

- **Reduce motion.** `UIAccessibility.isReduceMotionEnabled` / `Settings.Global.TRANSITION_ANIMATION_SCALE == 0`. When set: no screen shake, no slow-mo, no chromatic aberration, no parallax. Replace with a brief flash. **Keep every piece of information; drop the vestibular load.**
- **Colourblind-safe identity.** Snake identifies players by hue alone. Add a shape or pattern cue on the head and a distinct outline for the local player. Roughly 8% of men have some form of colour vision deficiency — for a competitive game this is a fairness issue, not just a comfort one.
- **No information in animation alone.** Anything communicated by motion must also be communicated by text, shape or position. Whose turn it is must never be *only* a glow.
- **Contrast.** Neon-on-black is high contrast for the bright elements and often terrible for secondary text. Check HUD text against WCAG AA at its actual rendered size.
- **VoiceOver / TalkBack.** Board games need labelled cells ("row 2, column 3, empty") and a turn announcement. Snake is not meaningfully playable non-visually — say so honestly rather than shipping a broken screen-reader experience.
- **Dynamic type.** HUD labels currently use fixed point sizes. At minimum, respect the system size for the leaderboard and score text.

---

# 11. Build order

### Phase 0 — prerequisites (do not skip)
| # | Step | Why |
|---|---|---|
| 1 | Camera follow spring, both platforms | removes most of the existing flicker; every camera effect depends on it |
| 2 | Free-running render clock | [`GAMES_SNAKE_BUGS.md`](./GAMES_SNAKE_BUGS.md) Part B — **effects on a jittering camera look worse, not better** |
| 3 | **Parse `events` in Android `parseSnake`** | one line; unblocks all Android VFX |
| 4 | Android render-tier detection (§4) | every later step branches on it |

### Phase 1 — highest value per unit of work
| # | Step |
|---|---|
| 5 | Additive bloom pass, both platforms (§5.1) |
| 6 | Particle system + the four Snake events (§5.3) |
| 7 | Camera look-ahead, mass zoom, screen shake (§5.2) |
| 8 | Hitstop + slow-mo on kill/death (§5.4) |
| 9 | Game haptics, both platforms (§8) |

### Phase 2 — reach and readability
| # | Step |
|---|---|
| 10 | Snake HUD: minimap, kill feed, boost meter, danger vignette (§5.5) |
| 11 | Android tier A: AGSL body shader (§5.1) |
| 12 | Card → game shared-element transition (§7) |
| 13 | Board-game motion passes: TTT, RPS, Cricket (§6) |

### Phase 3 — polish and correctness
| # | Step |
|---|---|
| 14 | Reduce-motion support everywhere (§10) |
| 15 | Colourblind-safe player identity (§10) |
| 16 | Frame-time measurement + automatic degradation (§9) |
| 17 | VoiceOver / TalkBack for board games (§10) |

**Phase 0 plus steps 5-7 is the meaningful first slice.** It fixes the existing visual bug, unlocks Android, and delivers the three effects that carry most of the perceived quality — bloom, particles and a camera with weight.
