# Tic Tac Toe — the winning line

> **Files:** [`TicTacToeBoard.swift`](../../apps/ios/Voiid/Voiid/Games/TicTacToeBoard.swift) · [`TicTacToeScreen.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/TicTacToeScreen.kt) · [`TicTacToeBotScreen.kt`](../../apps/android/app/src/main/java/com/voiid/app/main/games/TicTacToeBotScreen.kt) · engine: [`engine/tictactoe/index.ts`](../../backend/games/src/engine/tictactoe/index.ts)
> **Sound:** [`SOUND_DESIGN.md`](./SOUND_DESIGN.md) §4

**The ask:** when three marks pair up for a win, draw a line through them.

---

# 1. What exists today

The data is already there and already on the wire. The engine serializes the winning triple specifically so the client never has to re-derive it:

```ts
/** Winning cell triple, so the client can highlight it without re-deriving the win. */
line: number[] | null;
```

Both clients read it — and both use it **only to make the three winning cells swell**:

```swift
let isWinning = line?.contains(index) ?? false     // TicTacToeBoard.swift:42
// The winning triple swells so the win reads instantly.   :70
```

```kotlin
val isWinning = s.line?.contains(index) == true     // TicTacToeScreen.kt:146
```

**No stroke is ever drawn through them.** The win reads as "three cells got slightly bigger," which is the weakest possible statement of the one moment the whole game exists for.

---

# 2. What to build

A line drawn **through the centres of the three winning cells**, animated as a stroke being drawn, timed to a chalk sound ([`SOUND_DESIGN.md`](./SOUND_DESIGN.md) §4.3).

## 2.1 Geometry

`line` is three row-major indices into a 3×3 board (`LINES` in the engine covers 3 rows, 3 columns, 2 diagonals). Convert index → cell centre, then stroke from the **first** cell's centre to the **last**:

```
centre(i) = (col(i) + 0.5, row(i) + 0.5) * cellSize      where col = i % 3, row = i / 3
```

**Overshoot past the end cells.** A line that stops exactly at the two outer centres looks clipped and timid. Extend it by ~35% of a cell in both directions along its own axis, so it visibly strikes *through* the row rather than connecting two dots:

```
dir   = normalize(end - start)
start = start - dir * cellSize * 0.35
end   = end   + dir * cellSize * 0.35
```

This matters most on the diagonals, where the un-extended line is visually the shortest relative to what it's crossing.

## 2.2 The animation

**Draw it, don't fade it in.** A stroke that appears at full length is a graphic; a stroke that is drawn is a gesture, and this is a game about marking a board by hand.

| Property | Value | Note |
|---|---|---|
| Technique | animate stroke completion 0 → 1 | iOS: `.trim(from: 0, to: progress)` on a `Path`. Android: `PathMeasure.getSegment` into a destination `Path`, or `drawLine` with a lerped end point |
| Duration | **340 ms** | Long enough to read as a deliberate stroke, short enough not to delay the win banner |
| Curve | ease-out | Fast on the attack, settling at the end — matches how a real stroke is drawn |
| Width | ~1.4× the mark stroke width | Marks are `lineWidth: 9`, so **12-13**. The line must dominate the marks it crosses, not match them |
| Cap | `.round` | Consistent with the existing marks (`lineCap: .round`) |
| Colour | the **winner's** mark colour, at full saturation | Says *who* won in the same gesture that says *that* someone won |

**Sequencing** — the beats must not collide:

```
0 ms     final mark lands, mark sound plays
120 ms   ← hold. Let the player SEE the third mark before it is annotated.
120 ms   line stroke begins + chalk-line sound (SOUND_DESIGN.md §4.3)
460 ms   stroke complete
460 ms   winning cells swell (the EXISTING animation, now a payoff not the whole event)
560 ms   win banner / post-match screen
```

That 120 ms hold is the important number. Firing the line on the same frame as the winning mark makes the two read as one blurred event, and the player never registers which move won.

## 2.3 Draws

A draw currently shares the "nothing happens" treatment. Since a draw is the *expected* outcome between competent players ([`TICTACTOE.md`](./TICTACTOE.md) §2.1), it needs its own beat: no line, all nine cells desaturate together over 300 ms. See [`SOUND_DESIGN.md`](./SOUND_DESIGN.md) §4.4 for the paired sound.

## 2.4 Haptics

One `.success` notification on stroke **completion**, not on start. `GameHaptics` exists on both platforms.

## 2.5 Reduce-motion

Honour it: draw the line at full length instantly, keep the colour and the sound, drop the stroke animation. The information survives; the motion does not.

---

# 3. Parity notes

- The win-line path is **pure client-side presentation** — no engine change, no new frame, no serialization change. `line` is already on the wire for both online and bot matches.
- Android draws marks with `Icons.Outlined.Clear` / `RadioButtonUnchecked` while iOS strokes paths. The win line should be a **stroked path on both**, since the trim/`PathMeasure` animation has no icon equivalent.
- **Keep all constants identical across platforms** (340 ms, 0.35 overshoot, 1.4× width, 120 ms hold). Divergence here is how two ports of the same feature end up feeling like different games.
- Android's board is inline in the screen; iOS extracted `TicTacToeBoard.swift`. Worth extracting Android's while touching this code, since the line logic is needed by both the online and bot screens.
