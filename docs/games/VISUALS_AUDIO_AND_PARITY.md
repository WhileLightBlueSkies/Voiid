# Voiid Games — Visuals, Audio & Android Parity

> **Date:** 2026-08-17
> **Status:** plan. Nothing in here is implemented yet. Every "today" claim below was read out of the code on this date and is cited with a file and line.
> **Scope:** make the five non-trivial games *look and feel* like commercial games, fix game sound so it obeys media volume instead of the ringer, and close the Android↔iOS gap.
> **Companions:** [`../GAMES_ANIMATION.md`](../GAMES_ANIMATION.md) (the motion language — §3 there is still canonical), [`../GAMES_AUDIO.md`](../GAMES_AUDIO.md), [`SOUND_DESIGN.md`](./SOUND_DESIGN.md), [`../ANDROID_IOS_PARITY.md`](../ANDROID_IOS_PARITY.md), [`CARD_ART.md`](./CARD_ART.md).

---

## Contents

- [0. TL;DR](#0-tldr)
- [1. Sound — P0, both platforms](#1-sound--p0-both-platforms)
- [2. Android parity — P0/P1](#2-android-parity--p0p1)
- [3. RPS — a hand that actually makes the shape](#3-rps--a-hand-that-actually-makes-the-shape)
- [4. Hand Cricket — a batter that bats and a bowler that bowls](#4-hand-cricket--a-batter-that-bats-and-a-bowler-that-bowls)
- [5. Ludo — Ludo King grade board and pieces](#5-ludo--ludo-king-grade-board-and-pieces)
- [6. Sea Battle — boats, a cannon, and a lobbed bomb](#6-sea-battle--boats-a-cannon-and-a-lobbed-bomb)
- [7. Snake — obstacles that read as what they are](#7-snake--obstacles-that-read-as-what-they-are)
- [8. Tic Tac Toe — done, leave it alone](#8-tic-tac-toe--done-leave-it-alone)
- [9. Win, defeat and tie screens — one system, every game](#9-win-defeat-and-tie-screens--one-system-every-game)
- [10. The one architectural decision this document makes](#10-the-one-architectural-decision-this-document-makes)
- [11. Build order](#11-build-order)
- [12. Definition of done](#12-definition-of-done)

---

# 0. TL;DR

| # | Thing | Where it hurts | Priority |
|---|---|---|---|
| 1.1 | **iOS sound toggle is wired backwards** — turning Sound ON in settings mutes every game | iOS only | **P0 bug** |
| 1.2 | Games are silent when the ring switch is on silent; they should follow **media** volume | iOS | **P0** |
| 1.3 | Same on Android — an explicit `ringerMode` gate silences all game audio on vibrate/silent | Android | **P0** |
| 2.1 | **Sea Battle and Ludo have no Practice mode on Android**; iOS has both | Android | **P0** |
| 2.2 | Android Sea Battle has **no shell travel, no sunk reveal, no hit shake** — a shot just resolves | Android | **P1** |
| 2.3 | Android Snake is Compose `Canvas`; iOS is Metal. Different game at 60 fps | Android | **P1** |
| 3 | RPS hands are **emoji** (`✊✋✌️`) with a rotation wobble | Both | **P1** |
| 4 | Cricket batter is **three rounded rectangles**; there is no bowler at all | Both | **P1** |
| 5 | Ludo tokens are lit discs; the die is a flat pip face | Both | **P1** |
| 6 | Sea Battle is an ink-on-paper chart — no boats, no cannon, no bomb arc | Both | **P1** |
| 7 | Snake rocks/spikes/slicks are all **stacked flat circles**; a rock does not read as a rock | Both | **P1** |
| 8 | Tic Tac Toe | — | **Ship as-is** |
| 9 | **No win / defeat / tie screen in any game.** A result is a line of text next to a Rematch button. There is no defeat sound in the catalogue at all — a loss plays the neutral "match ended" chord | Both | **P0** |

Sound and parity are bugs. Everything from §3 to §8 is art and motion work. §9 is the one piece of *product* in here and it applies to all six games at once. §10 explains the decision that has to be made before any of it starts.

---

# 1. Sound — P0, both platforms

The ask: **game sound should play when the phone is on silent, and should follow the media volume slider, not the ringer.** That is how every game on both stores behaves. Three separate things are stopping it today, and one of them is a plain inversion bug.

## 1.1 iOS: the Sound toggle is inverted

[`GameAudio.swift:62-65`](../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L62-L65):

```swift
static var isMuted: Bool {
    get { !UserDefaults.standard.bool(forKey: "voiid.gameSoundEnabled_v1_default_on") ? false : true }
    set { UserDefaults.standard.set(!newValue, forKey: "voiid.gameSoundEnabled_v1_default_on") }
}
```

The setter stores `soundEnabled` (correct — that is what the key name says). The getter reads `soundEnabled` and then returns it **unchanged**: `!stored ? false : true` collapses to `stored`. So `isMuted == soundEnabled`.

Trace what a player actually experiences, with [`GameSettingsSheet.swift:44`](../../apps/ios/Voiid/Voiid/Games/GameSettingsSheet.swift#L44) writing `GameAudio.isMuted = !on`:

| Player does | Stored | `isMuted` returns | Result |
|---|---|---|---|
| Fresh install, never touches settings | *(absent → false)* | `false` | Sound plays ✅ *(right by accident)* |
| Turns Sound **ON** | `true` | **`true`** | **Every game goes silent** ❌ |
| Turns Sound **OFF** | `false` | `false` | Sound plays ❌ |

It is also self-inconsistent: the sheet seeds `@State private var soundOn = !GameAudio.isMuted` ([line 31](../../apps/ios/Voiid/Voiid/Games/GameSettingsSheet.swift#L31)), so re-opening settings shows the switch snapped back to the opposite of what was just set.

**Fix:**

```swift
static var isMuted: Bool {
    // The key stores soundEnabled and DEFAULTS TO ON, so an absent key must read as
    // "enabled" — `bool(forKey:)` returns false for a missing key, which is why this
    // goes through `object(forKey:)` rather than trusting the primitive default.
    get {
        let d = UserDefaults.standard
        guard d.object(forKey: soundKey) != nil else { return false }   // default: not muted
        return !d.bool(forKey: soundKey)
    }
    set { UserDefaults.standard.set(!newValue, forKey: soundKey) }
}
private static let soundKey = "voiid.gameSoundEnabled_v1_default_on"
```

Android's identical property is **correct** already ([`GameAudio.kt:112-120`](../../apps/android/app/src/main/java/com/voiid/app/main/games/GameAudio.kt#L112-L120)) — it uses `getBoolean(PREF_KEY, true)` for the default and negates on read. Port the shape, not the bug.

> Add a unit test. This is four lines of logic that silently disables the entire audio system, and it survived a full sound-design pass because nothing asserts it.

## 1.2 iOS: `.ambient` is what makes the silent switch bite

[`GameAudio.swift:284-295`](../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L284-L295):

```swift
try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
```

`.ambient` is the category that *obeys* the hardware ring/silent switch and rides the ringer volume. `.playback` ignores the switch and rides the **media** volume — which is exactly what was asked for.

**Fix:**

```swift
// .playback, NOT .ambient. `.ambient` obeys the hardware ring/silent switch and rides the
// ringer volume; a game is media, not a notification, and every game on the store plays
// through silent on the media slider. `.mixWithOthers` is kept so a player's music is
// ducked-not-killed by a cricket match, and the CallService guard above still means a game
// can never touch the session while a call is live.
try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
```

Three things that must not regress:

1. **`.mixWithOthers` stays.** Without it, opening a game stops the player's Spotify. With it, both play.
2. **The call rule is untouched.** `configureSessionIfNeeded()` already returns `false` while a call is live ([line 285](../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L285)) and every entry point checks `callIsActive`. `.playback` does not change that; the guard is what enforces it.
3. **No `UIBackgroundModes: audio`.** The app must not keep playing when backgrounded. `.playback` without the background mode is deactivated by the system on suspend, which is the behaviour we want. Do not add the capability.

Also update the settings footer at [`GameSettingsSheet.swift:66`](../../apps/ios/Voiid/Voiid/Games/GameSettingsSheet.swift#L66), which currently promises the opposite:

```
- "Games always respect the silent switch and never play over a call."
+ "Games play at your media volume, even on silent. They never play over a call."
```

## 1.3 Android: delete the ringer gate

[`GameAudio.kt:314-319`](../../apps/android/app/src/main/java/com/voiid/app/main/games/GameAudio.kt#L314-L319):

```kotlin
private fun ringerAllowsSound(): Boolean {
    val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return true
    return runCatching { am.ringerMode }.getOrDefault(RINGER_MODE_NORMAL) == RINGER_MODE_NORMAL
}
```

Called from `play` ([141](../../apps/android/app/src/main/java/com/voiid/app/main/games/GameAudio.kt#L141)), `startBed` ([208](../../apps/android/app/src/main/java/com/voiid/app/main/games/GameAudio.kt#L208)) and `startLoop` ([257](../../apps/android/app/src/main/java/com/voiid/app/main/games/GameAudio.kt#L257)). On vibrate or silent, every game sound is dropped.

The `AudioAttributes` are **already right**: `USAGE_GAME` + `CONTENT_TYPE_SONIFICATION` ([lines 74-77](../../apps/android/app/src/main/java/com/voiid/app/main/games/GameAudio.kt#L74-L77)) routes to `STREAM_MUSIC`, which is the media slider and is unaffected by ringer mode. The gate is the only thing silencing it.

**Fix:** delete `ringerAllowsSound()` and its three call sites. Replace the comment with why:

```kotlin
// NO RINGER CHECK, deliberately. The old code mirrored CallTones and dropped every sound on
// vibrate/silent — but a ringtone is a notification and a game is media. USAGE_GAME already
// routes this to STREAM_MUSIC, so the media slider is the volume control and silent mode is
// not a mute button. The isMuted toggle in GameSettingsSheet is the in-app control.
```

**Do not** change `CallTones.kt`. Call and notification audio *should* keep respecting the ringer; this change is scoped to `GameAudio` only.

While in here, consider `AudioAttributes.CONTENT_TYPE_GAME_SPEECH`/`CONTENT_TYPE_MUSIC` for the cricket crowd bed — it is already on `CONTENT_TYPE_MUSIC` at [line 228](../../apps/android/app/src/main/java/com/voiid/app/main/games/GameAudio.kt#L228), which is correct, so no change needed there.

## 1.4 Do not fight Do Not Disturb

DND on both platforms suppresses *notifications*, not media. Neither fix above touches DND, and neither should try to. A player who opens a game inside DND expects the game to make noise.

## 1.5 Test matrix

Run per platform, per game, after the fixes:

| Condition | Expected |
|---|---|
| Ring switch / ringer mode = silent, media volume up | Full game audio |
| Media volume at zero | Silence, volume HUD shows *media* when a game sound fires |
| In-app Sound toggle OFF | Silence, and it stays OFF when settings are reopened |
| In-app Sound toggle ON | Audio, and it stays ON when settings are reopened |
| Music playing in Spotify, then open a game | Both audible, music not stopped |
| Incoming call mid-match | Game audio stops instantly, call audio unaffected, mic works |
| Call ends | Game audio resumes |
| Background the app mid-match | Game audio stops |
| Headphones in/out mid-match | Audio continues on the new route |

The last four are the ones that regress silently. The call cases are non-negotiable — [`GAMES_AUDIO.md`](../GAMES_AUDIO.md) §2 is the hard rule and it is the reason `.playback` gets a guard rather than a free hand.

---

# 2. Android parity — P0/P1

iOS is the reference ([`ANDROID_IOS_PARITY.md`](../ANDROID_IOS_PARITY.md)). Current file-level diff of the two `games/` folders:

| iOS file | Android equivalent | Gap |
|---|---|---|
| `SeaBattleBot.swift`, `SeaBattleBotMatch.swift`, `SeaBattleBotView.swift` | **none** | No Sea Battle practice |
| `LudoBot.swift`, `LudoBotMatch.swift`, `LudoBotView.swift` | **none** | No Ludo practice |
| `SeaBattleMotion.swift` | **none** | No shell travel / sunk reveal / hit shake |
| `SnakeMetalView.swift` + `Snake.metal` | `SnakeArenaScreen.kt` (Compose `Canvas`) | Different renderer |
| `CoinSceneView.swift` (SceneKit) | `CoinView.kt` (hand-projected) | **Acceptable** — see §2.4 |

## 2.1 Sea Battle and Ludo have no Practice mode on Android — P0

iOS offers practice for six slugs ([`GamesHomeView.swift:86-88`](../../apps/ios/Voiid/Voiid/Games/GamesHomeView.swift#L86-L88)):

```swift
["tictactoe", "rps", "cricket", "snake", "seabattle", "ludo"].contains(slug)
```

Android offers it for four ([`RootTabView.kt:600`](../../apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt#L600)):

```kotlin
onPlayBot = if (game.slug !in listOf("tictactoe", "rps", "cricket", "snake")) null
```

So on Android the "Practice — offline, doesn't count" row simply does not appear for Sea Battle or Ludo. Both games are online-only there, which means both are unplayable without a friend online.

There is also a **latent trap** underneath it. The practice router at [`RootTabView.kt:656-663`](../../apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt#L656-L663) is:

```kotlin
when (slug) {
    "rps"     -> RpsBotScreen(...)
    "cricket" -> CricketBotScreen(...)
    else      -> TicTacToeBotScreen(...)     // ← catch-all
}
```

The moment somebody adds `"seabattle"` to the allow-list without adding a branch here, tapping Practice on Sea Battle silently opens **Tic Tac Toe**. Change the `else` to an explicit `"tictactoe" ->` plus an `else -> { }` that logs, so a missing branch fails visibly instead of opening the wrong game.

**Work:** port `SeaBattleBot.swift` (277 lines) → `SeaBattleBot.kt`, `SeaBattleBotMatch.swift` (247) → `SeaBattleBotMatch.kt`, `SeaBattleBotView.swift` (303) → `SeaBattleBotScreen.kt`; same for the three Ludo files (214 + 338 + 243). The bot *logic* files port almost mechanically — they are pure state machines with no platform API in them. The views are the real work.

> The bot match classes build a state object shaped exactly like a server frame, so both the online and practice screens read the board through one function ([`SeaBattleBoard.swift:491`](../../apps/ios/Voiid/Voiid/Games/SeaBattleBoard.swift#L491) `SeaBattleCells`). Android's `SeaBattleBoard.kt` already has the same shape, so the practice screen can reuse it unchanged. Keep that property.

## 2.2 Android Sea Battle has no shot animation — P1

iOS runs [`SeaBattleMotion.swift`](../../apps/ios/Voiid/Voiid/Games/SeaBattleMotion.swift): a 380 ms shell travel that the reticle contracts along, a sunk-ship outline drawn in cell by cell after a 120 ms hold, and a 2 px hit shake. That 380 ms is load-bearing — it is the window the server's answer arrives in, and it runs its full length even when the frame comes back in 40 ms, so the game feels identical on fast and slow connections.

Android has none of it. [`SeaBattleBoard.kt:385-393`](../../apps/android/app/src/main/java/com/voiid/app/main/games/SeaBattleBoard.kt#L385-L393) draws a **static dot** on the firing cell:

```kotlin
firing?.let {
    drawCircle(color = Ink.copy(alpha = 0.8f), radius = cellSize * 0.16f, center = ...)
}
```

and [`SeaBattleScreen.kt:110-118`](../../apps/android/app/src/main/java/com/voiid/app/main/games/SeaBattleScreen.kt#L110-L118) clears it the instant `lastShot` changes. So an Android shot is: dot appears, dot vanishes, result is there. No suspense, no travel, and on a fast connection the whole thing is under 50 ms.

**Work:** port `SeaBattleMotion.swift` to a `SeaBattleMotion.kt` holding the same three published values, then thread `shellProgress` / `sunkReveal` / `shake` into `SeaBattleGrid`. Keep the constants identical — `travel = 0.38`, `sinkHold = 0.12`, `perCell = 0.06` — and keep the "reveal on land, not on frame arrival" rule. Note this becomes §6's foundation: the bomb arc replaces the contracting reticle on **both** platforms, so do the port first and the art second, or the work is done twice.

The rest of the Android board is already at parity: paper grain, caustic shimmer, scorch, burning-hull flicker are all ported faithfully ([`SeaBattleBoard.kt:259-360`](../../apps/android/app/src/main/java/com/voiid/app/main/games/SeaBattleBoard.kt#L259-L360)).

## 2.3 Android Snake is a different renderer — P1

iOS: [`SnakeMetalView.swift`](../../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift) (2,010 lines) + [`Snake.metal`](../../apps/ios/Voiid/Voiid/Games/Snake.metal) — instanced circles, triangulated body ribbons, a label atlas, a bloom pass. Android: [`SnakeArenaScreen.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/SnakeArenaScreen.kt) (2,291 lines) of Compose `Canvas`.

This is not a bug — [`GAMES_ANIMATION.md`](../GAMES_ANIMATION.md) §1 planned exactly this asymmetry and specifies a three-tier Android design (AGSL 33+, `RenderEffect` 31-32, Canvas 24-30). What is missing is the *tiering*: Android ships tier C to everybody, including flagship devices that could run tier A.

Defer this. It is the largest single piece of work in the document and the least visible — a Compose `Canvas` Snake looks fine, it just costs more CPU. Revisit after §1-§7. When it is revisited, the entry point is an AGSL `RuntimeShader` for the food halos and body glow on API 33+, gated behind a `Build.VERSION` check with the current Canvas path as the fallback — not a rewrite.

## 2.4 What is *correctly* different, and should stay that way

- **The coin.** iOS uses a real `SCNCylinder` ([`CoinSceneView.swift`](../../apps/ios/Voiid/Voiid/Games/CoinSceneView.swift)); Android hand-projects the cylinder in Compose ([`CoinView.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/CoinView.kt)) rather than pulling in Filament for one spinning object. Both produce the right silhouette. **This is the pattern to copy for every 3D-ish object in this document** — see §5.3 and §10.
- **Fonts.** SF Pro Rounded vs Nunito, by licensing. Already documented.

## 2.5 Parity guard

Add to CI, or to the pre-merge checklist:

```
# Every iOS Games file must have an Android counterpart or an entry in the
# "deliberately different" list.
diff <(ls apps/ios/Voiid/Voiid/Games/*.swift  | xargs -n1 basename | sed 's/\.swift//' | sed 's/View$//') \
     <(ls apps/android/.../games/*.kt         | xargs -n1 basename | sed 's/\.kt//'    | sed 's/Screen$//')
```

It will be noisy the first time. Suppressing the noise *is* the exercise: everything left over is either a port to do or a decision to write down.

---

# 3. RPS — a hand that actually makes the shape

## 3.1 What is there today

Two emoji in a spotlit panel ([`RpsBotView.swift:132-149`](../../apps/ios/Voiid/Voiid/Games/RpsBotView.swift#L132-L149)):

```swift
Text(RpsBot.emoji(revealing ? nil : throwIdx))
    .font(.system(size: 56))
    .rotationEffect(.degrees(mirrored ? -tilt : tilt))
```

The shake is a `±18°` rotation of a glyph, three beats at 110 ms with a rising fist-pump sound ([lines 297-304](../../apps/ios/Voiid/Voiid/Games/RpsBotView.swift#L297-L304)). The *choreography is right* — the beats, the pitch climb, the reveal timing are all correct and should survive untouched. The thing being choreographed is an emoji.

## 3.2 The rig: a 2D skeletal hand, not a sprite swap

The ask was fingers that genuinely form the shape, with a static-model fallback. **Do the rig — it is not much harder than four static models and it is strictly better.**

A hand is a palm plus five finger chains. Each finger is three bones, and a pose is one **curl scalar per finger**. Every RPS shape is a different vector of five numbers, so morphing between shapes is interpolating five floats — which is what makes the transition read as fingers moving rather than one picture cross-fading into another.

Put the whole spec in **one shared constants file per platform, ported literally**, exactly the way [`LudoBoard.swift`](../../apps/ios/Voiid/Voiid/Games/LudoBoard.swift) pins the board geometry. Two hand rigs that disagree by a few degrees is the same parity drift that file exists to prevent.

**Bone lengths**, as fractions of finger length — anatomically real ratios, they matter more than they sound:

| Bone | Fraction |
|---|---|
| Proximal (knuckle → first joint) | `0.42` |
| Middle | `0.32` |
| Distal | `0.26` |

**Maximum joint flexion** at full curl (`curl = 1.0`):

| Joint | Degrees |
|---|---|
| MCP (knuckle) | `88` |
| PIP | `100` |
| DIP | `70` |

Actual angle per joint = `curl × maxFlexion`, so one scalar drives a whole finger and a half-curl looks like a half-curl rather than a straight finger at an angle.

**Finger lengths** relative to palm width (`1.0`), and rest angles fanning out from the knuckle line:

| Finger | Length | Rest splay |
|---|---|---|
| Index | `1.00` | `-13°` |
| Middle | `1.08` | `-2°` |
| Ring | `0.98` | `+9°` |
| Pinky | `0.80` | `+21°` |

**Thumb is special and must not be treated as a sixth finger.** It rotates *across* the palm rather than curling in plane: two bones, one `adduction` scalar that swings it from `-38°` (out, paper) to `+34°` (folded across the fingers, rock), plus its own curl.

## 3.3 The four poses

| Pose | index | middle | ring | pinky | thumb curl | thumb adduction | splay |
|---|---|---|---|---|---|---|---|
| **Neutral** (between rounds, and during the pumps) | `0.34` | `0.30` | `0.32` | `0.38` | `0.28` | `-6°` | `0.30` |
| **Rock** | `1.00` | `1.00` | `1.00` | `1.00` | `0.55` | `+34°` | `0.00` |
| **Paper** | `0.00` | `0.00` | `0.00` | `0.00` | `0.05` | `-38°` | `1.00` |
| **Scissors** | `0.00` | `0.00` | `1.00` | `1.00` | `0.70` | `+22°` | `0.55` |

`splay` scales the rest-splay column — at `1.0` paper's fingers fan wide, at `0.0` rock's are packed. Scissors' `0.55` applies to the two extended fingers only, which is what gives the V its opening.

## 3.4 Drawing it

Per finger, walk the three bones accumulating rotation, and stroke the resulting polyline as a **tapered capsule chain**: `lineCap = .round`, width `0.30 × palmWidth` at the knuckle down to `0.21` at the tip. Three strokes per finger at three widths beats one stroke, because the taper is most of what makes it read as a finger.

Layer order, back to front:

1. Contact shadow on the panel — offset `+4 pt` y, blur `10`, opacity `0.22`. Scales down and softens on the pump upstroke.
2. Forearm — tapered capsule entering from the panel edge.
3. Back fingers (ring, pinky) — these pass *behind* the palm in a fist.
4. Palm — rounded quad, slight barrel on the outer edge.
5. Front fingers (index, middle), thumb.
6. Outline — a single `2 pt` dark stroke over the whole silhouette (union of the paths), which is what gives it the flat pop-art look rather than a gradient blob.

Two colours only: skin fill and outline ink. Add one soft top-left highlight on the palm. Resist shading the fingers individually — it muddies at the 56 pt size these run at.

## 3.5 The choreography

Keep the existing three-beat cadence and the `pumpPitches` table ([`RpsBotView.swift:38`](../../apps/ios/Voiid/Voiid/Games/RpsBotView.swift#L38)) — those are already tuned and the sound is already generated. Layer on:

| Beat | Forearm | Hand | Fingers |
|---|---|---|---|
| Pump 1-3, upstroke (55 ms) | `-24°` at the elbow | lags forearm by ~40 ms | neutral, tightening `+0.06` on each pump |
| Pump 1-3, downstroke (55 ms) | `+9°`, overshoot then settle | leads by ~30 ms | — |
| Beat 3 downstroke → reveal (130 ms) | settles to `0°` | — | **neutral → thrown pose**, spring `response 0.18 / damping 0.55` |
| Reveal +0 ms | — | — | paper hyperextends to `curl = -0.10` then settles; rock's knuckles pop `1.04` scale for 90 ms |
| Reveal +180 ms | winner: `1.06` scale pulse | loser: droops `6°`, desaturates 15% | — |

The lag between forearm and hand is the single detail that makes this look human rather than mechanical. It is one extra interpolation with a delayed target — cheap, and it is doing most of the work.

**Under reduce-motion:** no pumps, no lag, no droop. Cut straight to the thrown pose. The result text already carries the outcome.

## 3.6 The online screen stays honest — but can now shake

[`RpsMatchView.swift:11-19`](../../apps/ios/Voiid/Voiid/Games/RpsMatchView.swift#L11-L19) refuses to shake, correctly: the server sends `hasThrown` booleans and never the throw, so the reveal arrives whenever the opponent taps, and faking a wind-up would be lying about timing.

That reasoning holds only while *one* player has thrown. Once **both** `hasThrown` flags are true, the resolved frame is imminent and known to be imminent — so the client can legitimately run the three-beat wind-up and reveal at the end of it, exactly the way Sea Battle's shell runs its full 380 ms and reveals on landing ([`SeaBattleMotion.swift:13-17`](../../apps/ios/Voiid/Voiid/Games/SeaBattleMotion.swift#L13-L17)). If the frame lands early, hold it until the wind-up ends. If it has not landed after ~600 ms, drop straight to the covered hands and reveal on arrival.

This makes online RPS feel like the bot game without inventing a single piece of state the client was not given. Update that file header when it ships — the current comment will read as a rule being broken otherwise.

## 3.7 Files

| Platform | New | Changed |
|---|---|---|
| iOS | `Games/HandRig.swift` (pose table + bone maths), `Games/HandView.swift` (renderer) | `RpsBotView.swift` (§3.5), `RpsMatchView.swift` (§3.6) |
| Android | `games/HandRig.kt`, `games/HandView.kt` | `RpsBotScreen.kt`, `RpsMatchScreen.kt` |

Port `HandRig` literally. Every number in §3.2-§3.3 must be identical on both platforms.

---

# 4. Hand Cricket — a batter that bats and a bowler that bowls

## 4.1 What is there today

[`CricketPitch.swift:157-171`](../../apps/ios/Voiid/Voiid/Games/CricketPitch.swift#L157-L171) — the batter is one rounded rectangle, the bat is another:

```swift
RoundedRectangle(cornerRadius: 6)                 // "a simple figure that leans into the shot"
    .fill(Color(red: 0.93, green: 0.91, blue: 0.96))
    .frame(width: 13, height: 40)
    .rotationEffect(.degrees(10 * Double(strike)), anchor: .bottom)
```

There is **no bowler at all**. On a bowled the ball simply appears at `x = 0.86` and travels left into the stumps ([lines 285-295](../../apps/ios/Voiid/Voiid/Games/CricketPitch.swift#L285-L295)).

What is already excellent and must be preserved: the `BallEvent` enum and its three tables — `reach`, `arc`, `flightDuration` ([lines 55-107](../../apps/ios/Voiid/Voiid/Games/CricketPitch.swift#L55-L107)). A six travels `0.88` of the frame with `0.66` arc over `0.90 s`; a four stays deliberately flat at `0.10` arc. That is real design, it is shared by the bot and online screens through one mapping, and the new figures should be **driven by** those tables, not replace them.

## 4.2 The rig: same technique as the hand

A side-on batter is seven bones: `pelvis`, `torso`, `head`, `frontArm`, `backArm`, `bat`, `frontLeg`, `backLeg`. A pose is one angle per bone. A shot is four keyframes.

Draw exactly like §3.4 — tapered capsules, one dark outline over the silhouette, two-colour fill (kit + skin), one contact shadow. At the 210 pt pitch height these run at, silhouette is everything and internal detail is wasted.

## 4.3 The shot table

Keyframes as `(t, [bone angles])`, with `t` normalised over the ball's `flightDuration`. Contact stays pinned at the existing `strike` timing — 170 ms ease-out ([line 259](../../apps/ios/Voiid/Voiid/Games/CricketPitch.swift#L259)) — so the bat still meets the ball at the frame it does now.

| Event | Backlift | Contact | Follow-through | Feel |
|---|---|---|---|---|
| `runs(1)`, `runs(2)` | `28°` | bat to `-40°`, wrists roll | stops at vertical | a push, weight stays back |
| `runs(3)` | `52°` | full extension, front leg strides | `100°` | a drive |
| `runs(4)` | `58°` | **flat bat**, high bat speed | `124°`, head still | along the ground — matches `arc = 0.10` |
| `runs(5)`, `runs(6)` | `72°` | front leg plants, torso rotates `30°`, head tilts up | `156°` over the shoulder | lofted, the whole body goes |
| `dot` | `20°` | bat straight down, soft hands | none | defensive block — `bat_block` already exists |
| `caught` | `44°` | bat face open `20°`, ball deflects up | truncated at `60°` | a leading edge |
| `bowled` | `62°` | **no contact**, bat continues past the line | `140°` through thin air | swing and a miss |

`bowled` currently skips the swing entirely ([line 258](../../apps/ios/Voiid/Voiid/Games/CricketPitch.swift#L258): `if e != .bowled`). Change that — a batter who is bowled *did* play a shot and missed, and the miss is the drama. The stumps' existing `68°` cartwheel stays; add two bails as separate small bodies with their own arcs, because bails flying is the single most recognisable image in cricket.

## 4.4 The bowler

New, and it costs the most timing. A run-up before every ball would get old by the third over, so:

- **First ball of an over:** full sequence — bowler enters from the right (`500 ms`), delivery stride, arm rotates `360°`, release at the top. Then the existing flight.
- **Balls 2-6:** shortened — bowler is already at the crease, arm rotation only (`260 ms`), then flight.
- **Tap anywhere to skip** to the delivery. Remember the choice for the session.
- **Reduce-motion:** no run-up at all, ever.

The ball must leave the bowler's hand at the release frame, not before. Today `ballPosition` starts a non-bowled ball at `x = 0.24` ([line 291](../../apps/ios/Voiid/Voiid/Games/CricketPitch.swift#L291)) — that origin becomes the bowler's release point for every event, not just `bowled`, so the ball is always seen to be bowled at the batter.

## 4.5 Should this be 3D?

No. WCC-style 3D means a model pipeline, a rig, an animation set, and a renderer that exists on both platforms — and the repo has already made this call once, correctly, for the coin (§2.4). A well-drawn 2D side-on figure with real weight transfer reads better at 210 pt than a low-poly 3D one, and it ships on both platforms from one spec.

If the pitch later grows to fill the screen, revisit — but that is a different game, not a polish pass.

## 4.6 Files

| Platform | New | Changed |
|---|---|---|
| iOS | `Games/CricketFigures.swift` (bone table, keyframes, renderer) | `CricketPitch.swift` |
| Android | `games/CricketFigures.kt` | `CricketPitch.kt` |

`BallEvent` and its three tables do not change. If a port needs them changed, the port is wrong.

---

# 5. Ludo — Ludo King grade board and pieces

## 5.1 Tokens → pawns

[`LudoBoardView.swift:120-141`](../../apps/ios/Voiid/Voiid/Games/LudoBoardView.swift#L120-L141) draws a lit disc via `GameSurface.token` — contact shadow, lit body, off-centre specular. Good, and not a piece you can pick up.

A Ludo pawn is four stacked shapes, and drawing it as a *solid* rather than a disc is what changes it:

| Part | Geometry |
|---|---|
| Base | ellipse, `rx = 0.50 × r`, `ry = 0.22 × r`, at the token's ground point |
| Waist | two mirrored quadratic curves from base edge to `0.30 r` at height `0.55 r` |
| Head | circle, `0.34 r`, centred at height `0.78 r` |
| Collar | thin ellipse between waist and head — this is the detail that makes it read as moulded plastic |

Lighting: one linear gradient down the body (top-left light, shared app-wide), one hard specular ellipse on the head's upper-left at `0.12 r`, one rim-light stroke on the lower-right at 25% opacity. Glossy, not matte — Ludo King's pieces read as polished plastic and that is most of the appeal.

**Keep the accessibility marker.** [`LudoBoard.swift:50-57`](../../apps/ios/Voiid/Voiid/Games/LudoBoard.swift#L50-L57) gives each seat a shape as well as a colour precisely because four-player colour-only identification fails for ~8% of men. Move the marker from the centre of the disc onto the **base band**, where it stays legible without fighting the head's highlight.

The hop already lifts and shrinks the shadow ([lines 150-151](../../apps/ios/Voiid/Voiid/Games/LudoBoardView.swift#L150-L151)). With a pawn silhouette, add a `0.92 / 1.08` squash-stretch on takeoff and landing — a solid object deforming on impact is worth more than another 20 ms of airtime.

## 5.2 The board

The geometry is already correct and pinned ([`LudoBoard.swift:79-108`](../../apps/ios/Voiid/Voiid/Games/LudoBoard.swift#L79-L108)) — do not touch the tables. Everything here is decoration on top:

- **Printed arrows** at each arm mouth showing the direction of travel. A new player cannot currently tell which way round the board goes, and this is the cheapest possible fix.
- **A board edge** — a `6 pt` bevelled border with a drop shadow, so the board sits *on* a table rather than being a pattern filling a square.
- **Glossy centre triangles** — a linear gradient plus a specular streak per triangle, matching the pawns' material.
- **Deepen the yard pockets** — `GameSurface.inset` at a higher depth, so a yard reads as a recess the pawns sit inside.
- Keep `GameSurface.felt` ([line 196](../../apps/ios/Voiid/Voiid/Games/LudoBoardView.swift#L196)) — the warm mat texture is right and is already shared.

## 5.3 The die

Today it is a flat pip face with a tumble ([`LudoView.swift:251`](../../apps/ios/Voiid/Voiid/Games/LudoView.swift#L251), `LudoDiePips`). Ludo King's die tumbles as a solid, and that is the single most-watched object in the game — it is on screen for every turn.

**Use the coin technique.** [`CoinView.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/CoinView.kt) already hand-projects a cylinder in Compose because adding a 3D framework for one object was the wrong trade. A cube is *easier* than a cylinder: eight vertices, project through a fixed camera, back-face cull, fill three visible faces with the light-direction shading, draw pips on each face with the same projection. Under 100 lines, identical on both platforms, no dependency.

Motion: tumble on two axes over `700 ms` with easing out, land with a `1.12 → 1.0` bounce and a small board shake, settle to the face the server sent. The `die_roll` / `die_settle` sounds already exist and already fire ([`LudoView.swift:104`, `241`](../../apps/ios/Voiid/Voiid/Games/LudoView.swift#L104)).

**The landed face must be the server's.** The tumble is presentation; the frame is the truth. Never let the animation pick the number.

## 5.4 Moments worth animating

- **Capture** — the captured pawn gets knocked (rotate `35°`, hop back along the track toward its yard over `420 ms`) rather than teleporting. `capture` sound already exists.
- **Home** — the pawn rises into the centre triangle with a burst of that seat's colour, and the triangle fills a little more each time. `home` sound exists.
- **Three sixes** — the die needs to visibly *reject* the turn: shake left-right and grey out. `three_sixes` exists and currently plays with no visual.

All three sounds are already generated and wired; they are firing against nothing.

## 5.5 Files

| Platform | New | Changed |
|---|---|---|
| iOS | `Games/LudoPawn.swift`, `Games/LudoDie.swift` | `LudoBoardView.swift`, `LudoView.swift`, `GameSurface.swift` |
| Android | `games/LudoPawn.kt`, `games/LudoDie.kt` | `LudoBoard.kt`, `LudoScreen.kt`, `GameSurface.kt` |

Plus the §2.1 practice-mode port, which should land **first** — otherwise all of this is invisible to Android players without a friend online.

---

# 6. Sea Battle — boats, a cannon, and a lobbed bomb

## 6.1 This is an art-direction change, and it should be written down as one

Sea Battle today is deliberately **ink on paper**: a naval chart, paper grain, splash rings drawn as hollow circles, scorches as burns. [`SeaBattleBoard.swift:239-242`](../../apps/ios/Voiid/Voiid/Games/SeaBattleBoard.swift#L239-L242) states the reasoning:

> Ink on paper (§8.2). Not naval-realistic and not Snake's retro-neon: the fiction is a naval chart, which is what the player is actually working, and it makes "nothing moves" an aesthetic rather than a limitation.

The reference screenshots are the opposite fiction: saturated cartoon sea, illustrated boat hulls, a big cannon that lobs a bomb, a fleet strip dividing two colour-coded halves. Both are coherent; they are not compatible, and half of each would look like neither.

**Recommendation: take the cartoon direction, and update [`SEA_BATTLE.md`](./future/SEA_BATTLE.md) §8.2 in the same PR.** The chart aesthetic was chosen partly because "nothing moves" — and §6.4 is specifically about making things move, so the constraint it was solving is going away. A doc left contradicting the code is how the next person reintroduces the old look by accident.

What survives the change and must not be dropped:

- **Hit and miss differ in shape before they differ in colour** ([lines 357-360](../../apps/ios/Voiid/Voiid/Games/SeaBattleBoard.swift#L357-L360)) — splash ring vs explosion. The board must still work in greyscale. The reference screenshots satisfy this: a cross is a cross.
- **Coordinate labels A–J / 1–10.** A player calling "D7" in chat has to read D7 off the screen.
- **The visibility rules in `SeaBattleCells`** ([line 491](../../apps/ios/Voiid/Voiid/Games/SeaBattleBoard.swift#L491)). Enemy ships that are not sunk are not in the frame at all. Prettier boats must not become a way to draw a ship the server did not send.

## 6.2 Layout

Match the reference:

```
┌─────────────────────────────┐
│                             │
│      ENEMY SEA (blue)       │   ← you fire here; only your shots + sunk hulls
│                             │
├──╮                       ╭──┤
│ 2│  ▬▬ ▬▬ ▬▬ ▬▬ ▬▬       │E │   ← fleet strip: their ships, then yours
│ 8│  ▬▬ ▬▬ ▬▬ ▬▬ ▬▬       │X │      sunk ones grey out
├──╯                       ╰──┤
│                             │
│    YOUR BOARD (sand)        │   ← your fleet, their shots
│                             │
└─────────────────────────────┘
```

- Two clearly different ground colours — that is the "team division" in the screenshots and it removes any doubt about which board is which.
- The **fleet strip in the middle** carries both fleets as ship silhouettes at a glance. It replaces reading two numbers, and it is the thing that makes the endgame legible.
- Round pills at the strip's ends: score on the left, EXIT on the right.
- The board you are **not** acting on dims — that behaviour already exists ([`SeaBattleGrid.dimmed`](../../apps/ios/Voiid/Voiid/Games/SeaBattleBoard.swift#L232)).

## 6.3 Ships have to be drawn per ship, not per cell

This is the structural change and it is worth being explicit about, because the current renderer makes it impossible.

Today `draw()` loops `0..<100` and renders each cell independently ([line 327](../../apps/ios/Voiid/Voiid/Games/SeaBattleBoard.swift#L327)) — `.ship` is a flat `ink.opacity(0.62)` square. A cell has no idea it is the bow of a Carrier.

Add a ship pass that runs **after** the cell pass and **before** the hit/miss markers:

```
for ship in visibleShips:
    rect = boundingBox(ship.cells)                  # already contiguous & collinear
    path = hullPath(length: ship.cells.count, horizontal: ship.isHorizontal)
    draw path into rect, rotated 90° if vertical
```

`SeaBattleRules.isContiguousLine` ([line 76](../../apps/ios/Voiid/Voiid/Games/SeaBattleBoard.swift#L76)) already guarantees the bounding box is exactly the ship, so there is no geometry to invent.

Five hulls for five lengths, matching `fleetSpec = [5, 4, 3, 3, 2]`:

| Length | Ship | Silhouette |
|---|---|---|
| 5 | Carrier | flat deck, island tower at 60%, two aircraft |
| 4 | Battleship | pointed bow, two turrets, bridge |
| 3 | Cruiser | single turret, tall mast |
| 3 | Submarine | rounded both ends, conning tower, no deck detail |
| 2 | Destroyer | small, single funnel |

Two per-ship states beyond the hull:

- **Damaged** — hit cells get a scorch *over the hull*, not instead of it.
- **Sunk** — hull rotates `8°`, sinks `0.15` cell down, desaturates, gains a smoke plume. The existing per-cell burning flicker ([lines 395-421](../../apps/ios/Voiid/Voiid/Games/SeaBattleBoard.swift#L395-L421)) becomes one plume on the whole wreck.

Same five silhouettes appear in the fleet strip and in the placement tray, so a player learns the shapes once.

## 6.4 The cannon and the bomb

Replace the contracting reticle ([lines 436-449](../../apps/ios/Voiid/Voiid/Games/SeaBattleBoard.swift#L436-L449)) with a real projectile. Four phases:

| Phase | Duration | What happens |
|---|---|---|
| **Charge** | `140 ms` | Cannon (bottom-centre of the target board, as in the screenshots) rotates toward the target and recoils back `0.06`. `fire_launch` fires here. |
| **Flight** | `380 ms` | Bomb arcs from muzzle to cell. **Unchanged budget** — this is still the server round-trip window (§2.2). |
| **Impact** | `120 ms` | Miss → splash rings + a white flash. Hit → explosion, `6` debris specks, screen shake `2 px`. |
| **Aftermath** | `400 ms` | Smoke drifts and dissipates; the cross/scorch marker settles into its permanent form. |

Flight details that sell it:

- The bomb **scales along the arc** — `1.0` at launch → `1.55` at apex → `0.85` at impact. Perspective in a top-down view, and it is the difference between "thrown" and "slid".
- A **shadow tracks along the sea at ground level**, staying on the straight line between muzzle and target while the bomb arcs above it. Without the shadow the arc reads as the bomb moving sideways.
- The bomb **tumbles** — `2.5` rotations over the flight.
- Arc height scales with distance: `arc = 0.28 × distance` in cells, clamped to `[0.9, 3.2]` cells.

Only the `380 ms` flight is in the latency budget; charge and impact happen outside the window, so total added latency is zero. **Keep the rule that the result is revealed on landing, never on frame arrival** ([`SeaBattleMotion.swift:13-17`](../../apps/ios/Voiid/Voiid/Games/SeaBattleMotion.swift#L13-L17)) — that is why the game feels the same on a fast and a slow connection.

**Reduce-motion:** no arc, no shake, no tumble. Cannon rotates, result appears. `SeaBattleMotion.fire` already has exactly this branch ([lines 47-51](../../apps/ios/Voiid/Voiid/Games/SeaBattleMotion.swift#L47-L51)).

## 6.5 Ordering

§2.2 (port `SeaBattleMotion` to Android) must land **before** §6.4, or the bomb gets built twice — once on iOS against the existing motion driver and once on Android against nothing.

## 6.6 Files

| Platform | New | Changed |
|---|---|---|
| iOS | `Games/SeaBattleShipArt.swift` (five hull paths), `Games/SeaBattleCannon.swift` | `SeaBattleBoard.swift`, `SeaBattleView.swift`, `SeaBattleBotView.swift`, `SeaBattleMotion.swift` |
| Android | `games/SeaBattleShipArt.kt`, `games/SeaBattleCannon.kt`, **`games/SeaBattleMotion.kt`** (§2.2) | `SeaBattleBoard.kt`, `SeaBattleScreen.kt` |
| Docs | — | [`future/SEA_BATTLE.md`](./future/SEA_BATTLE.md) §8.2 |

Also: **Sea Battle and Ludo have no card art.** [`CARD_ART.md`](./CARD_ART.md) §1 notes both fall back to a tinted glyph on the games grid. Two 1448×1086 PNGs, spec in that doc, drop-in with no client change.

---

# 7. Snake — obstacles that read as what they are

## 7.1 What is there today

Every hazard is stacked flat circles. [`SnakeMetalView.swift:1237-1293`](../../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift#L1237-L1293) and, ported literally, [`SnakeArenaScreen.kt:1420-1460`](../../apps/android/app/src/main/java/com/voiid/app/main/games/SnakeArenaScreen.kt#L1420-L1460):

```swift
case "rock":
    circles.append(CircleInstance(centre: centre, radius: r, softness: 0,
                                  colour: SIMD4(0.30, 0.30, 0.38, 1)))     // grey circle
    circles.append(CircleInstance(centre: centre + SIMD2(-r*0.16, -r*0.16),
                                  radius: r * 0.72, ...))                  // lighter circle
    circles.append(CircleInstance(centre: centre, radius: r * 1.06, ...))  // dark rim
```

The *intent* is documented and correct — a rock is opaque because it kills like a wall, a slick is translucent because it is passable. The execution is three concentric circles, so a rock, a retracted spike and a slick are the same shape in three colours. "I don't know what those obstacles are" is the expected outcome.

Backend context ([`hazards.ts`](../../backend/games/src/engine/snake/hazards.ts)): three kinds, all **static**, broadcast **once** at match start and never again. That is the key fact for §7.5 — geometry that never changes can be built once and reused for the whole match, so it can be as detailed as you like.

## 7.2 Rock

An irregular, faceted boulder. Not a circle.

- **Silhouette:** a 9-gon with per-vertex radius jitter in `[0.78, 1.18] × r`, and angular jitter of `±0.12` rad. Not smooth — a rock's outline has corners.
- **Facets:** split the polygon into 3 regions by a light direction of `(-0.6, -0.8)` — top face `+22%` lightness, side face base, shadow face `-30%`. Hard edges between them, no gradient. Faceting is what makes it read as stone rather than a blob.
- **Detail:** 2 cracks as short dark polylines following facet edges; 3-5 speckles. `GameSurface.speckle` already exists on both platforms.
- **Ground contact:** a hard elliptical shadow, `1.15 × r` wide and `0.45 × r` tall, offset down-right, opacity `0.45`. Currently the "rim" is a soft circle centred on the rock, which makes it float.
- **No glow.** It kills like the wall and must look like it.

**Four variants**, selected by `hazardIndex % 4`. A field of eight identical boulders reads as UI; four shapes is enough that it reads as terrain.

## 7.3 Spike

Its *state* is the gameplay, so the state has to be the silhouette.

- **Extended:** a ring of 6 triangular teeth around a dark socket, tips at `1.0 × r`, bases at `0.45 × r`, plus a hot centre. Sharp, high contrast, unmistakable.
- **Retracted:** the socket only — a dark ring with the tips flush inside it. Still shows *where* it is, which is the existing (correct) rule: a player must be able to plan a route through rather than be surprised.
- **The transition is currently a hard cut.** Animate it: teeth rise over `180 ms` with a `1.1` overshoot, retract over `140 ms`. `spikeExtended()` is a pure function of simulation time ([`hazards.ts:70-76`](../../backend/games/src/engine/snake/hazards.ts#L70-L76)), so the client can compute the phase *fraction* and drive the animation from it — no new wire field, no desync risk.
- **A tell before it fires.** The socket brightens over the last `250 ms` before extension. The phase is already known client-side; this is free, and it converts a spike death from bad luck into a mistake.

## 7.4 Slick

- **Irregular boundary**, not a circle — a 12-point closed spline with `±0.15 r` jitter. Oil does not have a radius.
- **A sheen band** sweeping across it on an 4-second cycle, at the same `0.04`-ish amplitude as the Sea Battle caustics. It should look wet.
- **No rim, no hard edge**, ever. A slick that looks like a wall costs the player position for nothing — the current soft double-circle gets this right and the shape change must not break it.
- Optional: a faint ripple when a snake head crosses the boundary. Presentation only.

## 7.5 How to render it

**iOS.** There is already a sprite pipeline — `SpriteInstance` + textured quads, used for name plates and the floor tile ([`Snake.metal:118-183`](../../apps/ios/Voiid/Voiid/Games/Snake.metal#L118-L183), `LabelAtlas` at [`SnakeMetalView.swift:1920`](../../apps/ios/Voiid/Voiid/Games/SnakeMetalView.swift#L1920)). Hazards are static, so:

1. At match start, render the four rock variants + the spike socket + a slick blob into one texture with Core Graphics.
2. Draw hazards as sprite instances against it — one draw call for the whole field.

**One trap, already documented in the file.** Do **not** reuse `spriteFragment`:

```metal
fragment float4 spriteFragment(SpriteOut in, texture2d<float> atlas, sampler s) {
    float4 texel = atlas.sample(s, in.uv);
    return float4(in.tint.rgb, texel.a * in.tint.a);   // ← RGB comes from TINT, not the texel
}
```

It hardcodes RGB to `tint.rgb` because a glyph atlas is white-on-transparent and only alpha carries shape. Colour art through it renders as a flat tint — this is the exact bug that made the whole arena wash out white when the bloom pass reused it ([`Snake.metal:185-192`](../../apps/ios/Voiid/Voiid/Games/Snake.metal#L185-L192)). Add a `hazardFragment` that samples the real texel colour, the way `bloomCompositeFragment` does.

**Android.** Build the same shapes as Compose `Path`s once, `remember`ed keyed on the hazard list (which never changes mid-match), and draw them each frame. Or rasterise to an `ImageBitmap` at match start and `drawImage` — measure both; the path version is simpler and 20-40 shapes is nothing.

## 7.6 Determinism is a hard requirement

Rock variant selection and vertex jitter **must** be a pure function of data both clients already have — the hazard's index and `(x, y)` — with an identical implementation on both platforms. `GameSurface.noise(x, y, seed:)` exists on both and is the right tool.

This is not cosmetic. If a rock is a different shape on two devices, two players see different cover and different escape routes, and Snake's whole netcode design is built on both clients agreeing about the world ([`SNAKE.md`](./SNAKE.md) §2). Never use `Random()` here.

## 7.7 Files

| Platform | New | Changed |
|---|---|---|
| iOS | `Games/SnakeHazardArt.swift` (shape generation + atlas build) | `SnakeMetalView.swift` (`buildHazards`), `Snake.metal` (add `hazardFragment`) |
| Android | `games/SnakeHazardArt.kt` | `SnakeArenaScreen.kt` (`drawHazards`) |

No backend change. `hazards.ts` already sends everything needed.

---

# 8. Tic Tac Toe — done, leave it alone

The chalk board is finished: three X variants with two audible strokes each, three O variants with one continuous sweep, so a player can hear whose turn resolved without looking ([`GameAudio.swift:51-58`](../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L51-L58)). Board and bot are at parity across platforms.

The only open item is [`TICTACTOE_WIN_LINE.md`](./TICTACTOE_WIN_LINE.md) — `line` is on the wire and no stroke is drawn. That is a small, separate, already-specified piece of work.

**One exception:** §9 applies here like it does everywhere else. Tic Tac Toe's *board* is finished; its *ending* is a line of text, same as every other game.

Its win-stroke timing is in fact the model §9 is built on. [`TicTacToeView.swift:107-109`](../../apps/ios/Voiid/Voiid/Games/TicTacToeView.swift#L107-L109) already refuses to play the win sound on the state change, because the sound belongs to the stroke that draws it — and `resultRevealed` already gates the verdict text on the stroke finishing ([lines 43-44](../../apps/ios/Voiid/Voiid/Games/TicTacToeView.swift#L43-L44)). That "the board finishes its sentence before the verdict speaks" rule is exactly §9.2, already implemented in one game. §9 generalises it to the other five.

---

# 9. Win, defeat and tie screens — one system, every game

## 9.1 What happens at the end of a match today

Nothing, in five of six games.

| Game | What the player gets when the match ends | Sound |
|---|---|---|
| **Sea Battle** | `"You win"` / `"You lose"` as inline text, plus `RematchBar` ([`SeaBattleView.swift:358-373`](../../apps/ios/Voiid/Voiid/Games/SeaBattleView.swift#L358-L373)) | `rank_up` on win, **`match_end` on loss** |
| **Ludo** | Same shape — a status line, plus `RematchBar` ([`LudoView.swift:54-55`, `188`](../../apps/ios/Voiid/Voiid/Games/LudoView.swift#L188)) | `rank_up` on win, **`match_end` on loss** |
| **Cricket** | A status line | `match_end` + `crowd_roar`/`crowd_groan` at +180 ms ([`CricketSound.swift:147-149`](../../apps/ios/Voiid/Voiid/Games/CricketSound.swift#L147-L149)) — **the best-handled ending in the app** |
| **RPS** | `"You win the match"` scaled 1.15×, plus a record card ([`RpsBotView.swift:151-172`](../../apps/ios/Voiid/Voiid/Games/RpsBotView.swift#L151-L172)) | **none at all** — only the last round's `round_win`/`round_lose` |
| **Tic Tac Toe** | A verdict line gated on the win stroke, plus a record card | `win_line` (on the stroke) / `draw` |
| **Snake** | The only real panel: `"Match over"`, final mass, personal best, share button ([`SnakeArenaView.swift:220-275`](../../apps/ios/Voiid/Voiid/Games/SnakeArenaView.swift#L220-L275)) | `match_end` |

[`CROSS_CUTTING.md`](./CROSS_CUTTING.md) §2 already named this — *"Snake's entire post-match experience is `You finished with 47`"* — and Snake is the **best** case.

Three concrete problems:

1. **There is no defeat sound in the catalogue.** Check the shipped set: `rank_up`, `match_end`, `win_line`, `draw`, `round_win`, `round_lose`, `round_tie`. `match_end` is *"a resolving chord — three sines landing on a major triad"* ([`synth.py:261-263`](../../tools/gamesounds/synth.py#L261-L263)) — it is the sound of a match *ending*, and it is major. Ludo and Sea Battle play it as the loss stinger. **Losing currently sounds like a pleasant resolution.**
2. **There is no tie treatment anywhere except Tic Tac Toe.** Cricket can tie, RPS can tie, and neither has a sound or a screen for it.
3. **Everything fires on the same frame as the state change**, so the result arrives while the board is still moving and lands on nobody.

## 9.2 The rule the whole section is built on

> **The board finishes its sentence before the verdict speaks.**

Tic Tac Toe already does this and it is the only game that does. The win stroke draws, *then* the verdict appears — `onLineComplete` is what reveals it ([`TicTacToeView.swift:131`](../../apps/ios/Voiid/Voiid/Games/TicTacToeView.swift#L131)), and the file explains why: the banner is the last beat, not the first.

Everywhere else the result overwrites its own cause. A ship sinks and the "You win" text appears in the same frame, so the player never sees the ship go down. **The last game event must play out in full, in its own visual language, before anything overlays it.**

The corollary matters just as much: **the board is never cleared and never fully covered.** The overlay dims it to 25% and sits on top. A player must be able to see the final board while reading the verdict — that is the difference between a result and a receipt.

## 9.3 One component, six skins

Do **not** write six end screens. Write one overlay per platform, driven by a descriptor each game fills in:

```swift
struct MatchEndResult {
    enum Outcome { case win, lose, tie }
    let outcome: Outcome
    /// "You win", "Bowled out", "2nd of 4". One short line, past tense.
    let headline: String
    /// Why, when the why is not obvious: "They resigned", "You ran out of time".
    let detail: String?
    /// 2-4 rows. `highlight` gives one row the accent colour — a personal best,
    /// the winning margin. Never more than one.
    let stats: [(label: String, value: String, highlight: Bool)]
    /// The game's own colour, so the overlay belongs to the board behind it.
    let accent: Color
    /// Muted presentation: won by resignation, timeout or abandonment. See §9.7.
    let hollow: Bool
}
```

The overlay owns: scrim, verdict, stat rows, particles, sound, haptics, the action row and the share sheet. A game owns only the descriptor. That is what makes six games consistent instead of six games that each drifted.

`RematchBar` is absorbed as the overlay's action row rather than sitting next to it — it keeps its own logic ([`RematchBar.swift`](../../apps/ios/Voiid/Voiid/Games/RematchBar.swift) already handles minting a new match, the in-flight state and the deliberately vague failure message; none of that changes).

## 9.4 The beat table — shared by all games and all three outcomes

Times are from the moment the *final game event* finishes, not from the state change.

| t (ms) | Beat | Notes |
|---|---|---|
| `0` | Last game event resolves in its own language | Chalk stroke completes, ship rolls and sinks, token reaches home, bails fly, snake collapses. **Nothing is cleared.** |
| `0 – 450` | **Hold.** Nothing moves. | The single most important number here. The player reads the board and understands *why* before being told *what*. |
| `450` | Scrim fades in, `260 ms` ease-out | Board dims to **25%**, stays visible. Never a black screen. |
| `560` | **Verdict lands** + outcome sound + haptic | The three fire on the same frame. See §9.5 for how they differ. |
| `760` | Stat rows stagger in, `60 ms` apart | Each rises `12 pt` and fades in over `220 ms`. |
| `1100` | Action row rises from the bottom, `260 ms` | Rematch / Play again, Exit, Share. |
| `1250` | Outcome flourish | Win only — see §9.5. |

Total: **1.6 s** for a win, and the player can tap through from `560 ms` onward. Tapping during the sequence skips it to the end state — never trap someone in a celebration.

## 9.5 The three outcomes differ in *direction*, not just in colour

This is the whole design. Same component, three genuinely different motions, so a player knows the result from across the room before reading a word.

| | **Win** | **Defeat** | **Tie** |
|---|---|---|---|
| **Verdict entrance** | scales **up** `0.70 → 1.0`, spring `response 0.42 / damping 0.55`, overshoots to `1.08` | scales **down** `1.25 → 1.0`, `easeOut 320 ms`, **no overshoot** — it settles like a weight | halves slide in from left and right, meet at centre, `380 ms` |
| **Direction of everything else** | rises | settles downward `6 pt` | converges inward |
| **Full sequence** | `1.6 s` | **`1.2 s`** — deliberately shorter | `1.3 s` |
| **Colour** | game accent, full saturation | desaturated 40%, one step darker | neutral `textSecondary` |
| **Scrim** | `0.72` opacity, accent-tinted | `0.80`, cool grey, no tint | `0.76`, neutral |
| **Particles** | **confetti** — 24 pieces in the accent colour, gravity `900 pt/s²`, `1.4 s` life, from the verdict's baseline | **none, ever** | none |
| **Haptic** | `.notification(.success)` then `Haptics.boundary()` at `+120 ms` | one `Haptics.rigid()` — a single thud | `Haptics.soft()` |
| **Sound** | `result_win` | `result_lose` | `result_tie` |
| **Stat row highlight** | pulses `1.06` once | static | both scores nudge `4 pt` toward each other |

### Defeat gets *less*, and that is the point

Write this down where the next person will find it, because the instinct is always to add more:

> **A defeat screen that is as loud as a win screen makes winning feel like nothing.** Defeat is short, quiet, and puts the rematch button under the thumb fast. It never mocks, never plays a sad trombone, never says "You lost!" with an exclamation mark. The shortest honest path back into a game is the respect.

Practically: `1.2 s` not `1.6 s`, no particles, one haptic not two, a desaturated palette, and the action row arrives `200 ms` earlier than on a win.

### Tie is not a small win

A tie's motion **converges** — it neither rises nor falls, because that is exactly what a tie is. `result_tie` must be an unresolved chord (a suspended second, no third), so it sounds like a question rather than an answer. Playing a diminished-sounding "you lost" for a draw is the common mistake and it misreads the result.

## 9.6 The three new sounds

Generate these with [`tools/gamesounds/synth.py`](../../tools/gamesounds/synth.py), in the existing style — they are recipes in code, not recordings, which is why the whole set is under a few hundred KB.

| Name | Duration | Recipe | Gain |
|---|---|---|---|
| `result_win` | `1.40 s` | Major arpeggio **rising** — root/third/fifth/octave at 262/330/392/523 Hz, each entering `90 ms` after the last with a `0.12 s` attack, all sustaining into a final octave. Same staggered-entrance trick as `match_end` so it reads as *arriving*, but it climbs instead of landing. | `0.85` |
| `result_lose` | `1.15 s` | Minor triad **falling** — 330/262/196 Hz entering `110 ms` apart, each `8 cents` flat of the last so it sags, `decay(k=6)` so it dies rather than sustains. Low-passed. Deliberately quieter and shorter than `result_win`. | `0.70` |
| `result_tie` | `1.00 s` | **Suspended, unresolved** — root and fourth only (262 + 349 Hz), no third, entering together, holding flat and fading. Nothing to resolve to is the sound of nothing being decided. | `0.72` |

Then in [`GameAudio.swift`](../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L369) / [`GameAudio.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/GameAudio.kt#L333) `soundNames`, add all three to **every** game's list — the same reasoning that puts `catch_shared` in every list ([`GameAudio.swift:365-368`](../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L365-L368)): a result vocabulary that only exists in some games teaches nothing.

**Then fix the two call sites that are lying:**

```swift
// LudoSound.swift:79 and SeaBattleSound.swift:86 — both currently:
GameAudio.shared.play(winner == me ? "rank_up" : "match_end", gain: 0.7)
// becomes:
GameAudio.shared.play(winner == me ? "result_win" : "result_lose", gain: 0.7)
```

`match_end` keeps its real job — the neutral "this match is over" chord for an abandoned match, where nobody won and nothing should be celebrated. `rank_up` goes back to meaning a rank change, which is what it was written for.

### Per-game layering on top of the shared stinger

The shared sound carries the outcome; each game layers **one** thing on top so the ending still sounds like *that game*. Cricket already does exactly this and is the model:

| Game | Layer | Delay |
|---|---|---|
| **Cricket** | `crowd_roar` (win) / `crowd_groan` (loss) / `crowd_applause` (tie) — **already built** ([`CricketSound.swift:147-149`](../../apps/ios/Voiid/Voiid/Games/CricketSound.swift#L147-L149)) | `+180 ms` |
| **Sea Battle** | `sink_groan` — the last ship going down under the verdict | `+150 ms` |
| **Ludo** | `home` — the winning token arriving | `+140 ms` |
| **Tic Tac Toe** | `chalk_erase` — the board being wiped for the next game | `+400 ms` |
| **RPS** | `hand_reveal` on the losing hand dropping | `+160 ms` |
| **Snake** | `rank_up` **only** on a personal best | `+300 ms` |

The delay is the same trick as the cricket crowd, and for the same reason ([`GameAudio.swift:197-206`](../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L197-L206)): fired together the two read as one mushy noise and the impact is lost. A reaction has to arrive *after* the event.

## 9.7 Winning because someone left is not a victory

Existing code already gets this right and it must survive the rewrite. Both [`LudoSound.swift:76-78`](../../apps/ios/Voiid/Voiid/Games/LudoSound.swift#L76-L78) and [`SeaBattleSound.swift:83-85`](../../apps/ios/Voiid/Voiid/Games/SeaBattleSound.swift#L83-L85) do:

```swift
// An abandoned match has no winner and gets no stinger — nothing was won.
guard let winner = s.winnerUserId else { return }
```

Extend that principle to the visuals with the `hollow` flag:

| Ending | Screen |
|---|---|
| Won by playing better | Full win treatment |
| Won by **resignation** or **timeout** | `hollow: true` — verdict and detail line ("They resigned"), **no confetti, no fanfare**, `result_win` at `0.5` gain. Action row arrives immediately. |
| **Abandoned**, no winner | No overlay at all. A neutral "Match abandoned" line and an Exit button. `match_end` at `0.4` gain, or silence. |

Sea Battle already writes the right *words* for these ([`SeaBattleView.swift:362-363`](../../apps/ios/Voiid/Voiid/Games/SeaBattleView.swift#L362-L363)) — `"They resigned — you win"`, `"They ran out of time — you win"`. The presentation just has to stop treating them as triumphs.

## 9.8 What each game puts in the stat rows

2-4 rows, all of it already in the frame or already tracked locally. **Nothing here needs a new wire field or a new endpoint.**

| Game | Rows | Source |
|---|---|---|
| **RPS** | Rounds `3 – 1` · Your most-thrown · Record vs this bot/friend | `RpsState.wins`, `history`, `BotScoreStore` |
| **Tic Tac Toe** | Won / Drawn / Lost · Moves played | `BotScoreStore` — the record card already exists ([`TicTacToeBotView.swift:106-118`](../../apps/ios/Voiid/Voiid/Games/TicTacToeBotView.swift#L106-L118)) |
| **Cricket** | Final scores, both innings · Won by *N* runs / *N* wickets · Best shot | `CricketState` |
| **Ludo** | Placement (`2nd of 4`) · Tokens home · Captures made / suffered | `LudoState.tokens`, move history |
| **Sea Battle** | Shots fired · Accuracy % · Ships sunk · *"Sunk with 3 ships still hidden"* | `SeaBattleState.shots` / `results` |
| **Snake** | Length · Kills · Rank (`1st of 6`) · Personal best | `SnakeState`, `SnakeRecordStore` — partly built already |

The Sea Battle line is the template for what a good stat row does: `"Sunk with 3 ships still hidden"` turns a number into a story, and it is one comparison against data already on screen.

## 9.9 Share, in every game

[`SnakeArenaView.swift:248-267`](../../apps/ios/Voiid/Voiid/Games/SnakeArenaView.swift#L248-L267) has "Challenge a friend" on the ordinary share sheet, and [`CROSS_CUTTING.md`](./CROSS_CUTTING.md) §2 calls share-to-chat *"the app's single structural advantage over every standalone game"*. It exists in exactly one game.

Promote it into the shared overlay with a per-game line:

| Game | Share text |
|---|---|
| RPS | `"Beat me at Rock Paper Scissors 3–1. Rematch?"` |
| Tic Tac Toe | `"Forced a draw again. Nobody wins this one."` |
| Cricket | `"Chased 84 with two balls to spare."` |
| Ludo | `"Won Ludo from last place. Ask me how."` |
| Sea Battle | `"Sank your fleet with 3 ships still hidden."` |
| Snake | `"I got 142 in Snake. Beat that."` *(exists)* |

On a **loss**, the button becomes **Rematch**, never Share. Nobody shares a loss, and offering it reads as a joke at the player's expense.

## 9.10 Accessibility — non-negotiable

- **Reduce motion:** no scrim fade, no stagger, no confetti, no verdict spring. The overlay is simply *there* with the stats already in place. **Sound still plays** — reduce-motion is about motion, not audio, and the outcome stinger is often how the result is perceived. Both platforms already thread a `reduceMotion` flag through the games ([`SeaBattleMotion.swift:45`](../../apps/ios/Voiid/Voiid/Games/SeaBattleMotion.swift#L45), `ReduceMotion.kt`); reuse it.
- **Colour is never the only channel.** Win / defeat / tie must be distinguishable in a greyscale screenshot. The **word** and a **glyph** carry the outcome — trophy, a downward chevron, an equals sign — and the accent tint is decoration on top. Same rule as [`SeaBattleBoard.swift:357-360`](../../apps/ios/Voiid/Voiid/Games/SeaBattleBoard.swift#L357-L360) and [`LudoBoard.swift:44-49`](../../apps/ios/Voiid/Voiid/Games/LudoBoard.swift#L44-L49).
- **VoiceOver:** the verdict is a header (`.isHeader`), and the overlay's appearance posts a screen-change announcement so the result is read out without hunting. Stat rows read as `"Accuracy, 41 percent"`, not `"41%"`.
- **Never trap the player.** Tapping anywhere during the sequence skips to the end state. The action row is reachable within `560 ms` of the verdict.
- **Sound off is a supported way to play.** Every outcome must be fully legible with `GameAudio.isMuted` — which, after §1.1, will actually be respected.

## 9.11 Files

| Platform | New | Changed |
|---|---|---|
| iOS | `Games/MatchEndOverlay.swift` (component), `Games/MatchEndResult.swift` (descriptor + per-game builders) | `RpsBotView`, `RpsMatchView`, `TicTacToeView`, `TicTacToeBotView`, `CricketMatchView`, `CricketBotView`, `LudoView`, `LudoBotView`, `SeaBattleView`, `SeaBattleBotView`, `SnakeArenaView`, `RematchBar` (absorbed), `LudoSound`, `SeaBattleSound`, `GameAudio` (`soundNames`) |
| Android | `games/MatchEndOverlay.kt`, `games/MatchEndResult.kt` | the matching `*Screen.kt` set, `RematchBar.kt`, `LudoSound.kt`, `SeaBattleSound.kt`, `GameAudio.kt` |
| Sounds | `result_win.wav`, `result_lose.wav`, `result_tie.wav` | [`tools/gamesounds/synth.py`](../../tools/gamesounds/synth.py) (3 recipes + 3 `Sound` entries), then run [`verify.py`](../../tools/gamesounds/verify.py) — it asserts mono/44.1 kHz across **both** platforms' asset folders, which is what stops the format crash documented at [`GameAudio.swift:108-119`](../../apps/ios/Voiid/Voiid/DesignSystem/GameAudio.swift#L108-L119) |
| Docs | — | [`CROSS_CUTTING.md`](./CROSS_CUTTING.md) §2 — mark the post-match screen as spec'd here |

**Order within the section:** sounds first (they are three functions and a table, and everything else can be tuned against them) → the overlay component on iOS → one game wired through it end to end → the other five → the Android port → the share lines.

Wire **Sea Battle first**. It has all three outcomes, has resignation and timeout endings, has the richest stats, and already has `RematchBar` in place — so if the component survives Sea Battle, the other five are a descriptor each.

---

# 10. The one architectural decision this document makes

Every section above assumes: **richer procedural drawing on both platforms from one shared spec, and no new dependency.** Worth stating plainly because it was a real choice.

| Option | Verdict |
|---|---|
| **Procedural, shared spec** *(chosen)* | No dependency, no asset pipeline, no app-size cost, infinitely resolution-independent, and parity is enforceable by porting a constants table literally — the trick [`LudoBoard.swift`](../../apps/ios/Voiid/Voiid/Games/LudoBoard.swift) already uses for board geometry. Costs: more code, and a designer cannot iterate without an engineer. |
| **Lottie** | Genuinely good at exactly this, exists on both platforms, and a designer could own the animation. But: two new dependencies, a JSON asset pipeline, ~1-2 MB per platform, and animations that cannot be driven by *game state* — a cricket shot's arc comes from `flightDuration`, which Lottie cannot read. Reasonable for a decorative one-shot; wrong for state-driven motion, which is nearly everything here. |
| **Sprite sheets** | Best-looking ceiling, and the right answer if there is an artist. Costs app size, needs an atlas pipeline on both platforms (iOS already has one for labels; Android has none), and every new state is new art. Revisit for the cricket batter specifically if §4 lands and still looks flat. |
| **3D (SceneKit / Filament)** | No. The repo already rejected this once for the coin and hand-projected a cylinder instead ([`CoinView.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/CoinView.kt)), which was right. SceneKit on iOS with no Android equivalent is the parity failure this whole document is trying to close. |

The `GameSurface` helpers (`felt`, `paper`, `inset`, `token`, `speckle`, `noise`, `vignette`) already exist on **both** platforms with matching signatures. Every section above builds on them. Add new primitives there rather than inline in a view, so the second platform's port is a translation instead of a redesign.

---

# 11. Build order

Ordered so that nothing gets built twice and each step is shippable on its own.

### Step 1 — Sound *(hours, not days)*
§1.1 iOS inversion → §1.2 `.playback` → §1.3 drop Android's ringer gate → §1.5 test matrix. Highest value per line changed in the whole document. Ship it alone.

### Step 2 — Android parity, functional
§2.1 Sea Battle + Ludo practice (six file ports) and the `else`-branch guard. Until this lands, half of §5 and §6 is invisible to Android players.

### Step 3 — Android parity, motion
§2.2 `SeaBattleMotion.kt`. Prerequisite for §6.4.

### Step 4 — Win / defeat / tie screens
§9. **The highest-value step after the sound fix**, because it is one component that lands in all six games at once and it is the moment every match currently throws away. Do the three sounds first, wire Sea Battle end to end, then the rest. Depends on nothing above it except Step 1 (the sounds have to actually be audible) and Step 2 (or Android's Sea Battle and Ludo have no practice mode to end).

### Step 5 — Snake obstacles
§7. Self-contained, no backend change, and the most-played game. Do the iOS `hazardFragment` first, then Android.

### Step 6 — RPS hands
§3. The clearest visible win per unit of work, and `HandRig` is a self-contained new file that nothing else depends on.

### Step 7 — Sea Battle art
§6. The largest single piece. Land §6.1's doc update in the same PR. Order within: layout → ship art → cannon/bomb.

### Step 8 — Ludo
§5. Pawn → board → die → capture/home/three-sixes moments.

### Step 9 — Cricket figures
§4. Batter first (reuses the existing `strike` timing so it can ship alone), bowler second (needs the run-up timing decision).

### Deferred
§2.3 Android Snake tiering. Real work, low visibility, and it should not block anything above it.

---

# 12. Definition of done

Per section, the thing to actually check on a device:

| § | Done when |
|---|---|
| 1 | The full matrix in §1.5 passes on a physical iPhone **and** a physical Android device. Simulators do not have a ring switch. |
| 2.1 | Practice opens the right game for all six slugs on both platforms, and an unhandled slug fails visibly. |
| 2.2 | An Android shot takes the same wall-clock time as an iOS shot on the same connection, and a sunk ship draws in cell by cell. |
| 3 | Screen-record both platforms side by side at 0.25×. The finger curl and the forearm lag are frame-comparable. |
| 4 | A six and a single are distinguishable **with the banner hidden**. If they are not, the pose table is not doing its job. |
| 5 | A pawn casts a shadow that moves when it hops, and the die's landed face always matches the frame. |
| 6 | The bomb's shadow stays on the muzzle→target line while the bomb arcs above it. Result still reveals on landing, not on frame arrival. |
| 7 | A screenshot of the arena, shown to someone who has never played, gets "rocks" as the answer. Same four hazards, same shapes, on two devices in the same match. |
| 8 | Board untouched. Ending goes through §9 like every other game. |
| 9 | **Play a match to each of win, defeat and tie in all six games.** With the screen turned away, the outcome is identifiable from sound alone; with sound off, from motion alone; in a greyscale screenshot, from the word and glyph alone. The final board is visible behind the overlay in every case. A resignation win shows no confetti. Defeat reaches the rematch button faster than a win does. |

Two rules that apply to every section:

- **Reduce-motion has a real path everywhere.** Not "the animation but faster" — the animation *not happening*, with the outcome still legible. [`CROSS_CUTTING.md`](./CROSS_CUTTING.md) §13 records Snake shipping hitstop and shake with no opt-out; this document must not repeat it.
- **Colour is never the only channel.** Hit vs miss, seat vs seat, hazard vs hazard — every one of these must survive a greyscale screenshot. It is already the rule in [`LudoBoard.swift:44-49`](../../apps/ios/Voiid/Voiid/Games/LudoBoard.swift#L44-L49) and [`SeaBattleBoard.swift:357-360`](../../apps/ios/Voiid/Voiid/Games/SeaBattleBoard.swift#L357-L360). New art is the easiest place to lose it.
