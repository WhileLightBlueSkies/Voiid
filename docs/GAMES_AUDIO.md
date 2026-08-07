# Voiid Games — Sound Design & Audio Engine

> **Status:** specification. Nothing in this document is built yet.
> **Current state:** there is **zero audio** in any game, on either platform. No `AVAudioPlayer`, no `SoundPool`, no `MediaPlayer` in any file under `Games/` or `main/games/`.
> **Decision taken:** all sounds are **synthesized**, not sampled. See §6 for why and §7 for the recipes.
> **Companions:** [`GAMES_AUDIT.md`](./GAMES_AUDIT.md) (§5.2 logs the gap), [`GAMES_ANIMATION.md`](./GAMES_ANIMATION.md) (audio and animation share a timing table), [`snake-play.md`](../snake-play.md) §18.

---

## Contents

1. [Why synthesized](#1-why-synthesized)
2. [The one hard rule](#2-the-one-hard-rule-never-over-a-call)
3. [Architecture](#3-architecture)
4. [iOS implementation](#4-ios-implementation)
5. [Android implementation](#5-android-implementation)
6. [Format, size and latency budget](#6-format-size-and-latency-budget)
7. [The synthesis toolkit](#7-the-synthesis-toolkit)
8. [Sound catalogue — Snake](#8-sound-catalogue--snake)
9. [Sound catalogue — the three board games](#9-sound-catalogue--the-three-board-games)
10. [Sound catalogue — shared UI](#10-sound-catalogue--shared-ui)
11. [Mixing and loudness](#11-mixing-and-loudness)
12. [Settings and accessibility](#12-settings-and-accessibility)
13. [Build order](#13-build-order)

---

# 1. Why synthesized

Sampled audio is the default choice and it is the wrong one here.

| | Synthesized | Sampled (CC0 packs) |
|---|---|---|
| Licensing | **You own it.** No attribution, no LICENSE file, no audit risk | Per-asset terms; one CC-BY or GPL file slipping in is a real problem for a commercial app |
| Repo size | ~200 KB for the whole set | 2-10 MB typical |
| Tuning | Every parameter is a number you can change | You get what the clip is |
| **Parametric variation** | **Pitch/duration/timbre can follow game state** | Fixed; repetition becomes audible fast |
| Consistency | One synthesis vocabulary → the set sounds like one product | Sourced from many creators; rarely cohesive |
| Realism | Poor for organic sound (crowds, voices, real impacts) | Excellent |

Voiid's games need **arcade and UI sound** — blips, pops, zaps, sweeps, stingers. That is precisely the class synthesis does *better* than sampling, because the sounds are abstract to begin with. Nothing in the four games needs a recorded crowd or a real bat-on-ball.

The parametric point is the one that matters most in play. Snake's `eat` fires up to several times a second, and a fixed clip repeated at that rate turns into a machine-gun stutter within one match. A synthesized `eat` whose pitch tracks the snake's mass is *information* — you hear yourself getting bigger — and it never repeats identically. §7.4 covers this.

**Verified working:** stdlib Python (`wave`, `array`, `math`) renders 16-bit WAV; macOS `afconvert` encodes AAC. No numpy, ffmpeg or sox needed, and no new build dependency for either app.

---

# 2. The one hard rule: never over a call

**Voiid is a messaging app with voice and video calling. A game sound must never play over a call, interrupt a ringtone, or steal the audio route.**

This is not a nicety. Both platforms already have careful call-audio code that a naive game-audio layer will break:

- [`CallToneService.swift:165-170`](../apps/ios/Voiid/Voiid/Networking/CallToneService.swift#L165-L170) sets `.playAndRecord` / `.voiceChat`
- [`GroupCallService.swift:479`](../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L479) sets `.playAndRecord`
- [`CallTones.kt:50`](../apps/android/app/src/main/java/com/voiid/app/net/CallTones.kt#L50) uses `STREAM_VOICE_CALL` and already respects `RINGER_MODE_SILENT`

On iOS, `AVAudioSession` category is **process-global**. A game calling `setCategory(.ambient)` while a call is live will reconfigure the call's own session and can drop the microphone. The game audio layer must therefore:

1. **Never call `setCategory` while a call is active.** Query call state first and no-op.
2. **Set its category once, on game-screen entry only**, and restore nothing on exit (leave the session to whoever owns it next).
3. **Use `.ambient`**, which respects the hardware silent switch and mixes rather than ducking. A game that plays through the silent switch is a bug report.

On Android the equivalents are `USAGE_GAME` audio attributes (never `USAGE_VOICE_COMMUNICATION`), honouring `RINGER_MODE_SILENT` and `RINGER_MODE_VIBRATE` exactly as `CallTones.kt` already does, and abandoning focus on pause.

**Test case that must pass before this ships:** start a Snake match, receive an incoming call, answer it. Game audio must be silent for the whole call and must not have altered the call's routing.

---

# 3. Architecture

One small class per platform, mirroring the existing `GamesEngine` / `Haptics` shape so it is where a Voiid developer would expect to find it.

```
apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift     (next to Haptics.swift)
apps/android/app/src/main/java/com/voiid/app/main/games/GameAudio.kt
apps/*/…/Resources/GameSounds/*.wav                  (generated, committed)
tools/gamesounds/synth.py                             (the generator; run offline)
```

### The API, identical on both platforms

```
GameAudio.preload(for: .snake)        // load this game's bank; idempotent
GameAudio.play(.eat, pitch: 1.2, gain: 0.8)
GameAudio.stop(.boostLoop)            // looping sounds only
GameAudio.release()                   // free the bank on screen exit
GameAudio.isMuted = true/false        // persisted user setting
```

### Rules the layer enforces so no call site has to think about them

- **Preload, never load on demand.** Decoding a file on first play is a 10-50 ms hitch at exactly the moment something exciting happened.
- **Voice pool with stealing.** A fixed pool (16 voices). When it is full, steal the *oldest* voice of the *same* sound rather than refusing to play — a missing `eat` is more noticeable than a truncated one.
- **Per-sound rate limit.** No single sound may retrigger faster than its own floor (see the `min gap` column in §8-10). Five simultaneous `eat`s must sum to one satisfying sound, not five overlapping copies at 5× the volume.
- **Automatic pitch jitter.** Every sound gets ±3% random pitch unless the caller specifies one, which alone removes most of the machine-gun effect.
- **Silent when muted, silent when backgrounded, silent during a call.** Checked centrally.

---

# 4. iOS implementation

**Deployment target is 18.0**, so everything below is available unconditionally.

### Use `AVAudioEngine`, not `AVAudioPlayer`

`AVAudioPlayer` is file-oriented, allocates per instance, and has unpredictable start latency — fine for a voice note, wrong for a game. `AVAudioEngine` with pre-decoded `AVAudioPCMBuffer`s and a pool of `AVAudioPlayerNode`s gives sub-frame trigger latency and real-time pitch control.

```swift
final class GameAudio {
    static let shared = GameAudio()

    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]

    // Each voice is a player node + a varispeed unit, so pitch is per-voice.
    // Varispeed changes pitch AND duration together, which is what you want for
    // arcade sound — a higher-pitched blip should also be shorter.
    private struct Voice {
        let player: AVAudioPlayerNode
        let speed: AVAudioUnitVarispeed
        var startedAt: TimeInterval
        var sound: Sound?
    }
    private var voices: [Voice] = []

    func play(_ sound: Sound, pitch: Float = 1.0, gain: Float = 1.0) {
        guard !isMuted, !CallState.shared.isActive else { return }
        guard let buffer = buffers[sound] else { return }
        guard allowRetrigger(sound) else { return }        // per-sound min gap

        let v = checkoutVoice(for: sound)                  // steals oldest if full
        v.speed.rate = pitch * Float.random(in: 0.97...1.03)
        v.player.volume = gain
        v.player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        v.player.play()
    }
}
```

### Session category

```swift
// ONCE, on game screen entry — and never while a call is live.
guard !CallState.shared.isActive else { return }
try? AVAudioSession.sharedInstance().setCategory(
    .ambient,                          // respects the silent switch
    options: [.mixWithOthers])         // never interrupt the user's music
try? AVAudioSession.sharedInstance().setActive(true)
```

`.ambient` is the correct category for a casual game and is what makes the hardware mute switch work. Do **not** use `.playback` — that plays through silent mode, which users read as the app ignoring them.

### Handle interruptions

Observe `AVAudioSession.interruptionNotification`. On `.began`, stop all voices. On `.ended`, restart the engine only if the game screen is still foreground. Also observe `AVAudioEngineConfigurationChangeNotification` — plugging in headphones mid-match tears down the graph and it must be rebuilt.

### Core Haptics belongs with audio, not with animation

`Haptics.swift` currently wraps `UIImpactFeedbackGenerator` — five coarse presets, no control over envelope. That is right for UI taps and wrong for game feedback. For Snake specifically, use `CHHapticEngine` so a haptic can be *authored alongside its sound* with the same envelope:

```swift
// A kill: sharp transient, then a short decaying rumble — the haptic equivalent
// of the sound in §8.4. Authoring both from the same numbers is what makes them
// feel like one event instead of two.
let hit = CHHapticEvent(eventType: .hapticTransient, parameters: [
    .init(parameterID: .hapticIntensity, value: 1.0),
    .init(parameterID: .hapticSharpness, value: 0.9)], relativeTime: 0)
let rumble = CHHapticEvent(eventType: .hapticContinuous, parameters: [
    .init(parameterID: .hapticIntensity, value: 0.55),
    .init(parameterID: .hapticSharpness, value: 0.2)], relativeTime: 0.02, duration: 0.18)
```

Keep `Haptics.swift` for UI; add `GameHaptics.swift` for in-match events. Details in [`GAMES_ANIMATION.md`](./GAMES_ANIMATION.md) §8.

---

# 5. Android implementation

**minSdk is 24**, which constrains the choices. Everything below works at 24 with no version guard unless noted.

### Use `SoundPool` for SFX

`SoundPool.Builder` is API 21+, decodes on load, and is purpose-built for short, frequently-retriggered game sounds with per-play rate (pitch) and volume. `MediaPlayer` is the wrong tool — one instance per sound, high latency, heavy.

```kotlin
object GameAudio {
    private const val MAX_STREAMS = 16

    private val pool = SoundPool.Builder()
        .setMaxStreams(MAX_STREAMS)
        .setAudioAttributes(
            AudioAttributes.Builder()
                // USAGE_GAME, never USAGE_VOICE_COMMUNICATION — this must route and
                // duck like a game, and must never be mistaken for call audio.
                .setUsage(AudioAttributes.USAGE_GAME)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build())
        .build()

    private val ids = HashMap<Sound, Int>()
    private val loaded = HashSet<Int>()   // SoundPool.play() on an unloaded id is silent

    fun play(sound: Sound, pitch: Float = 1f, gain: Float = 1f) {
        if (muted || CallState.isActive) return
        if (!allowRetrigger(sound)) return
        val id = ids[sound] ?: return
        if (id !in loaded) return
        val p = (pitch * Random.nextFloat().let { 0.97f + it * 0.06f }).coerceIn(0.5f, 2.0f)
        pool.play(id, gain, gain, /* priority */ 1, /* loop */ 0, p)
    }
}
```

Two `SoundPool` behaviours that will bite if unhandled:

- **`load()` is asynchronous.** Playing before `OnLoadCompleteListener` fires is silently ignored. Track loaded ids (above) and preload on screen entry.
- **Pitch (`rate`) is clamped to 0.5-2.0.** Anything outside is silently clamped, so pitch mapping must be designed inside that range.

### Respect ringer mode — mirror `CallTones.kt`

```kotlin
val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
if (am.ringerMode != AudioManager.RINGER_MODE_NORMAL) return   // silent AND vibrate
```

This is the Android analogue of the iOS silent switch and the app already does exactly this for call tones — matching it keeps behaviour consistent across the product.

### Audio focus

Request `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` on game entry, abandon on exit.

```kotlin
// AudioFocusRequest is API 26+; minSdk is 24, so the legacy call is still needed.
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
    am.requestAudioFocus(focusRequest)
} else {
    @Suppress("DEPRECATION")
    am.requestAudioFocus(listener, AudioManager.STREAM_MUSIC,
                         AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
}
```

On `AUDIOFOCUS_LOSS` or `AUDIOFOCUS_LOSS_TRANSIENT` (an incoming call), mute immediately. On `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK`, drop gain to ~20% rather than stopping.

### Haptics — tiered by API level

Android's haptics story is fragmented and minSdk 24 means three tiers:

| API | Available | Use for |
|---|---|---|
| 30+ | `VibrationEffect.Composition` with `PRIMITIVE_CLICK`, `PRIMITIVE_TICK`, `PRIMITIVE_QUICK_RISE`, `PRIMITIVE_QUICK_FALL` | **Best.** Closest analogue to Core Haptics; composable, scalable intensity |
| 26-29 | `VibrationEffect.createWaveform(timings, amplitudes, -1)` | Good. Amplitude control, no primitives |
| 24-25 | `Vibrator.vibrate(longArray, -1)` | Crude on/off patterns only |

Use `VibratorManager` on API 31+ and the deprecated `getSystemService(VIBRATOR_SERVICE)` below it. Always check `hasVibrator()` and `hasAmplitudeControl()`.

---

# 6. Format, size and latency budget

| Sound length | Format | Reason |
|---|---|---|
| < 500 ms (all SFX) | **16-bit mono WAV, 44.1 kHz** | Zero decode latency, trivially small at this length, no codec artefacts on transients |
| > 500 ms (stingers, music) | AAC in `.m4a` @ 96 kbps mono | Compression worth it; latency irrelevant for a one-shot |

**Mono, always.** These are UI and gameplay sounds, not music. Stereo doubles the size for no benefit, and positional panning (if ever added) should be applied at playback from world coordinates, not baked in.

### Size budget

| | Count | Each | Total |
|---|---|---|---|
| Snake | 11 | ~12 KB | 132 KB |
| Board games | 12 | ~10 KB | 120 KB |
| Shared UI | 6 | ~8 KB | 48 KB |
| **Total** | **29** | | **~300 KB** |

Negligible against the app's existing footprint, and it ships uncompressed so there is no runtime cost.

### Latency target

**< 30 ms** from game event to audible sound. Above ~50 ms the sound reads as a separate event from the animation rather than part of it. Both engine choices above (`AVAudioEngine` with pre-decoded buffers, `SoundPool`) clear this comfortably; `AVAudioPlayer` and `MediaPlayer` do not, which is why they are excluded.

---

# 7. The synthesis toolkit

A single offline script at `tools/gamesounds/synth.py`, run manually, output committed. **It is not part of either app's build** — no new dependency, no CI step, and the generated WAVs are reviewable in a diff as binary assets that change only when someone deliberately regenerates them.

### 7.1 The core renderer

```python
import array, math, random, wave

SR = 44100

def render(path, dur, fn, gain=0.7):
    """fn(t_seconds, progress_0_to_1) -> sample in [-1, 1]"""
    n = int(SR * dur)
    buf = array.array('h')
    for i in range(n):
        t = i / SR
        s = max(-1.0, min(1.0, fn(t, i / n) * gain))
        buf.append(int(s * 32767))
    with wave.open(path, 'w') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(buf.tobytes())
```

### 7.2 The primitive vocabulary

Six building blocks cover every sound in this document. Keeping the vocabulary small is what makes the set cohere.

```python
def sine(t, f):        return math.sin(2 * math.pi * f * t)
def saw(t, f):         return 2 * ((t * f) % 1) - 1
def square(t, f, duty=0.5): return 1.0 if (t * f) % 1 < duty else -1.0
def noise():           return random.uniform(-1, 1)

def decay(p, k):       return math.exp(-p * k)          # percussive
def ar(p, a=0.05):     return p / a if p < a else (1 - p) / (1 - a)   # attack-release

def sweep(p, f0, f1, curve=1.0):
    """Pitch glide. curve > 1 = fast then slow; < 1 = slow then fast."""
    return f0 + (f1 - f0) * (p ** curve)
```

### 7.3 Anti-aliasing

Naive `saw` and `square` alias badly on upward pitch sweeps — a metallic grit that sounds like a bug. Two cheap mitigations, both sufficient at these durations:

1. Prefer `sine` plus explicit harmonics over `saw`/`square` for anything that sweeps.
2. Render at 4× (176.4 kHz), then average groups of 4 samples down to 44.1 kHz. Ten lines, and it removes the problem entirely.

### 7.4 Parametric variation — the reason for all of this

Two mechanisms, and they do different jobs:

**Bake variants** for sounds with a small number of meaningful states. Snake's `eat` ships as 4 files at rising pitch; the caller picks by mass bucket. Cheap, sounds deliberate, no runtime cost.

**Runtime pitch** for continuous variation. `GameAudio.play(.eat, pitch: 1.0 + mass / 600)` maps mass smoothly onto pitch inside SoundPool's 0.5-2.0 clamp.

Use both: variants give timbral change (a bigger snake sounds *fuller*, not just higher), runtime pitch fills the gaps between them.

---

# 8. Sound catalogue — Snake

Snake needs the most care: it is continuous, events overlap, and the same sound fires hundreds of times per match.

| # | Event | Trigger | Length | Min gap | Character |
|---|---|---|---|---|---|
| 8.1 | `eat` | food consumed | 90 ms | 60 ms | bright rising blip |
| 8.2 | `eatBig` | corpse food (`v == 2`) | 140 ms | 80 ms | fuller, lower, richer |
| 8.3 | `boostStart` | pedal pressed | 180 ms | 200 ms | rising whoosh |
| 8.4 | `boostLoop` | while boosting | loop | — | filtered noise bed |
| 8.5 | `boostEnd` | pedal released | 120 ms | 200 ms | falling tail |
| 8.6 | `kill` | you killed someone | 400 ms | 150 ms | impact + descending sweep |
| 8.7 | `death` | you died | 700 ms | — | the big one; see below |
| 8.8 | `spawn` | you respawned | 350 ms | — | rising shimmer, resolves up |
| 8.9 | `borderWarn` | near the lethal wall | loop | — | low pulse, intensity by proximity |
| 8.10 | `rankUp` | you moved up the board | 250 ms | 500 ms | two-note rise |
| 8.11 | `matchEnd` | timer expired | 1.2 s | — | resolving chord |

### Recipes

**8.1 `eat`** — the most-heard sound in the game, so it must be short, bright and *never* fatiguing. Sine plus one octave harmonic, pitch sweeping up, fast exponential decay. Ship 4 pitch variants.

```python
def eat(t, p):
    f = sweep(p, 660, 1200)
    env = decay(p, 9)
    return (sine(t, f) + 0.3 * sine(t, f * 2)) * env

render('eat_1.wav', 0.09, eat)
# Variants: multiply base/target frequency by 0.84, 1.0, 1.19, 1.41 (minor thirds).
```

**8.6 `kill`** — the reward sound. Needs weight (low transient) and clarity (audible over everything). Noise burst for impact, then a descending tone.

```python
def kill(t, p):
    impact = noise() * decay(p, 40) * 0.8
    tone = sine(t, sweep(p, 420, 130, curve=0.5)) * decay(p, 5)
    sub = sine(t, 70) * decay(p, 8) * 0.5          # felt more than heard
    return impact + tone + sub
```

**8.7 `death`** — the one sound that is allowed to be dramatic, because it stops play. It must land *with* the visual: [`GAMES_ANIMATION.md`](./GAMES_ANIMATION.md) specifies slow-mo to 0.3× for 500 ms and a 400 ms desaturation, so the audio is built to the same 700 ms envelope with its own pitch drop mirroring the time dilation.

```python
def death(t, p):
    crack = noise() * decay(p, 55)                      # the hit
    fall = saw(t, sweep(p, 300, 45, curve=0.7)) * decay(p, 3) * 0.6   # pitch collapse
    rumble = sine(t, 55) * (1 - p) * 0.7                # low bed, fades over the panel
    return crack + fall + rumble
```

**8.9 `borderWarn`** — a loop, gain driven by distance to the wall. This is *information*, not decoration: the arena border is instantly lethal and currently gives no warning at all. Pair it with the edge glow in the animation doc. Keep it low and slow (~2 Hz pulse at 90 Hz) so it reads as dread rather than an alarm.

### Polyphony rules for Snake

- `eat` is capped at **3 concurrent voices**. Beyond that, steal.
- `boostLoop` and `borderWarn` are **single-instance loops** with ramped gain — never retriggered.
- `death` **ducks everything else to 30%** for its duration. It is the only sound with priority over the mix.

---

# 9. Sound catalogue — the three board games

Turn-based games need far less: sounds are sparse, deliberate, and never overlap. The design goal is *confirmation* and *consequence*, not excitement.

### Tic Tac Toe

| Event | Length | Character |
|---|---|---|
| `markPlace` | 80 ms | soft wooden knock — pitch differs for X and O so you hear whose turn resolved |
| `markInvalid` | 120 ms | dull muted thud, distinctly unsatisfying |
| `winLine` | 500 ms | ascending three-note arpeggio, timed to the line-sweep animation |
| `draw` | 400 ms | two flat notes, unresolved |

```python
def mark_place(t, p, base=520):        # X = 520 Hz, O = 392 Hz
    body = sine(t, base) * decay(p, 22)
    click = noise() * decay(p, 90) * 0.35
    return body + click
```

### Rock Paper Scissors

| Event | Length | Character |
|---|---|---|
| `countdown` | 120 ms ×3 | three rising ticks, then silence before the reveal |
| `reveal` | 200 ms | sharp swish — both hands land together |
| `roundWin` | 350 ms | bright rising pair |
| `roundLose` | 350 ms | the same interval, inverted and darker |
| `roundTie` | 200 ms | single flat tone |

The countdown ticks should rise in pitch (`440 → 554 → 659`) so anticipation is built by the audio, not just the timer.

### Hand Cricket

| Event | Length | Character |
|---|---|---|
| `pick` | 70 ms | light tick on number selection |
| `runs` | 180 ms | pitch **scales with runs scored** — 1 run low, 6 runs high and bright |
| `four` | 400 ms | crack + short rising cheer-like swell |
| `six` | 600 ms | bigger version of the above, longer tail |
| `wicket` | 500 ms | descending break, clearly negative |
| `innings` | 700 ms | neutral transition chime |

`runs` is the parametric win here — one recipe, six audible outcomes, and the player learns the mapping without being told:

```python
def runs(t, p, n):                     # n = 1..6
    f = 300 + n * 85
    return (sine(t, f) + 0.25 * sine(t, f * 3)) * decay(p, 12)
```

Note Hand Cricket already has the richest haptics in the app ([`CricketPitch.swift:186-190`](../apps/ios/Voiid/Voiid/Games/CricketPitch.swift#L186-L190) maps boundary/four/dot/wicket to distinct patterns). **Match the audio to those existing haptic choices** rather than inventing a parallel mapping — and port both to Android, which currently has neither.

---

# 10. Sound catalogue — shared UI

Used across all four games, defined once.

| Event | Length | Character |
|---|---|---|
| `tap` | 50 ms | neutral UI tick — pairs with `Haptics.tap()` |
| `sheetOpen` | 180 ms | soft rising whoosh |
| `sheetClose` | 140 ms | the same, falling and shorter |
| `matchFound` | 500 ms | two-note confirmation |
| `inviteArrive` | 400 ms | distinct from the message tone; must not be confusable with a chat notification |
| `error` | 250 ms | low double-buzz |

`inviteArrive` deserves attention: Voiid already has a message notification sound, and a game invite arriving with a near-identical tone trains users to ignore one or the other. Make it clearly a *game* sound — brighter, more melodic.

---

# 11. Mixing and loudness

Synthesis makes it easy to produce a set where one sound is four times louder than another. Fix it at generation time, not at every call site.

- **Peak-normalize every file to −3 dBFS**, then apply a deliberate per-sound trim (the `gain` column below). Never ship a file that peaks at 0 dBFS — playback pitch-shifting can push it into clipping.
- **Relative levels**, as a starting mix:

| Tier | Trim | Sounds |
|---|---|---|
| Loud | 0 dB | `death`, `six`, `winLine`, `matchEnd` |
| Normal | −4 dB | `kill`, `wicket`, `four`, `reveal`, `spawn` |
| Frequent | −9 dB | `eat`, `markPlace`, `pick`, `tap` |
| Bed | −15 dB | `boostLoop`, `borderWarn` |

The `eat` trim is the important one. It is quiet *because* it is constant — a frequent sound at normal level is exhausting within thirty seconds.

- **Leave headroom for polyphony.** Three simultaneous `eat`s must not clip. With −9 dB trim and a master at −6 dB there is room for roughly six concurrent voices before the sum approaches full scale.
- **Duck under `death`.** The only global ducking rule in the game.
- **Check on a phone speaker, not headphones.** Phone speakers have almost no output below ~300 Hz, so the sub content in `kill` and `death` is *felt* on good hardware and simply absent on a handset. Every sound must still read correctly with everything under 300 Hz removed.

---

# 12. Settings and accessibility

There is no game settings screen at all today ([`GAMES_AUDIT.md`](./GAMES_AUDIT.md) §4.7). Audio is the reason to build one.

- **Sound on/off**, persisted, default **on**.
- **Haptics on/off**, persisted, default **on**, independent of sound. Some players want one without the other.
- **Respect the system.** iOS silent switch (automatic with `.ambient`) and Android `RINGER_MODE_SILENT`/`VIBRATE` (explicit check). Never override.
- **Never gate information behind audio alone.** `borderWarn` must always be paired with the visual edge glow — a deaf player, or anyone playing muted on a bus, must have the same information. This applies to every sound that carries meaning rather than flavour.
- **Reduce-motion implies calmer audio.** When the OS reduce-motion flag is set, drop `death`'s dramatic tail and the screen-shake-linked sounds. The information stays; the intensity goes.

---

# 13. Build order

| # | Step | Output |
|---|---|---|
| 1 | `tools/gamesounds/synth.py` with the §7 toolkit | the generator |
| 2 | Generate + audition the Snake set (§8) | 11 WAVs |
| 3 | `GameAudio.swift` — engine, voice pool, mute, call guard | iOS layer |
| 4 | `GameAudio.kt` — SoundPool, focus, ringer check, call guard | Android layer |
| 5 | Wire Snake events on both platforms | Snake has sound |
| 6 | **Verify the call test** (§2) on real devices, both platforms | the gate |
| 7 | Generate + wire the three board games (§9) | all games have sound |
| 8 | Shared UI sounds (§10) | consistency |
| 9 | Game settings screen: sound + haptics toggles | §12 |
| 10 | `GameHaptics` — Core Haptics (iOS) / tiered `VibrationEffect` (Android) | §4, §5 |
| 11 | Port Hand Cricket's existing haptic map to Android | closes a parity gap |

**Steps 1-6 are the meaningful slice.** They prove the engine, the synthesis approach and the call-safety rule on the game that needs audio most. Everything after is repetition of a proven pattern.
