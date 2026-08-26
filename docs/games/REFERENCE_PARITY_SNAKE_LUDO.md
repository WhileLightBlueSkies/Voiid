# Reference Parity — Snake & Ludo

> **Status: implemented.** See "What actually shipped" at the end for where the
> plan below survived contact and where it did not.

Comparing the standalone reference builds in `~/Downloads/Snake` and `~/Downloads/Ludo`
against Voiid's shipping implementations, and deciding what to actually adopt.

**Sources reviewed**
- Reference Snake: `SnakeCore.swift`, `SnakeWorld.swift`, `SnakeScene.swift`, `SnakeGameView.swift` (1,175 lines, SpriteKit, fully local)
- Reference Ludo: `LudoTheme.swift`, `LudoDiceView.swift`, `LudoBoardView.swift`, `LudoEngine.swift`, `LudoGame.swift`, `LudoGameView.swift` (1,665 lines, SwiftUI, fully local)
- Ours (iOS): `Games/Snake*.swift` + `Snake.metal` (3,915 lines), `Games/Ludo/*.swift` (3,741 lines)
- Ours (Android): `main/games/ludo/*.kt`, `main/games/snake/*`

---

## The headline finding

The two references are **single-player local prototypes**. Ours are **server-authoritative
multiplayer**. That difference decides almost every call below.

| | Reference | Voiid |
|---|---|---|
| Truth | Client owns the simulation | Server owns it; client renders |
| Snake renderer | SpriteKit sprite-per-segment | Metal, instanced circles + triangulated ribbons, triple-buffered |
| Snake body | Path history resampled (`Trail`) | Path history resampled (`TrailStore`) — **same idea, already shipped** |
| Ludo dice | 6 faces, per-face quaternion, `Animatable` | 2.5D projected cube in `Canvas`, cross-platform parity with Compose |
| Platforms | iOS only | iOS + Android must stay pixel-parity |

**So: we are not porting either reference.** Our Snake is already ahead of it on the exact
axis you asked about (smoothness). What we take is a short list of *specific feel details*
the reference gets right and we don't.

---

## Snake — what "the smoothness" actually is

The reference's core insight is in its own header comment: *a snake is a path history plus a
sampler, not a list of segments that chase each other.* That is the thing that stops the
body drifting and stretching on fast turns.

**We already do this.** `TrailStore` (`SnakeArenaView.swift:573`) appends to a path at render
rate from the interpolated head, resamples to a fixed 4-unit step, and trims through the final
segment rather than dropping whole segments — which is strictly better than the reference,
because the reference's `Trail.sample` re-walks the whole path every frame while ours trims
incrementally. We also predict the local snake instead of interpolating it, so your own steering
has zero added latency. The reference has no network at all, so it never had to solve that.

### What we adopt

**S1 · Head magnetism on pellets** *(server-side)*
Reference `Cfg.magnetRange = 4.2` head-radii, pellets slide toward the head at 430 u/s.
We currently require an exact overlap, which makes eating feel like threading a needle.
This is the single biggest feel win in the reference. Must land in the **server** engine
(`backend/games/src/engine/snake`) so both clients agree — a client-side magnet would
desync instantly.

**S2 · Frame-rate-independent camera easing**
Reference eases the camera with `lerp(t: dt * 9)` instead of snapping to the head, explicitly
because fast turns otherwise feel like whiplash. We have exponential smoothing already
(`SnakeMetalView.swift:1119`) — this is a **tuning pass**, not new code: audit the tau against
the reference's effective ~110 ms and adjust if ours is tighter.

**S3 · Pupils track intent, not heading**
Reference points pupils at `desiredHeading` — where you're steering — not `heading`, where the
snake currently points. Cheap, and it's what makes the blob read as alive and as *anticipating*
the turn. Ours points eyes at the joystick for the local snake only (`SnakeMetalView.swift:1469`);
extend it to remote snakes using their last-known turn direction.

**S4 · Tail alpha falloff**
Reference darkens segments toward the tail by up to 18% (`1 - t * 0.18`), which reads as depth
without a shader. We render flat bands. One multiply in the fragment shader.

**S5 · Corpse scatter pops outward**
Reference gives death pellets a velocity that decays at `0.88`/frame, so a kill *bursts* rather
than materialising. Server-side, small.

### What we explicitly reject

| Reference feature | Why not |
|---|---|
| SpriteKit rendering | A downgrade. Ours is Metal-instanced; the reference caps out ~12 snakes. |
| Client-owned simulation | Breaks multiplayer entirely. Non-starter. |
| Client-side bots (`SnakeWorld.think`) | Our bots are server-side and already shared with Android. |
| Held-BOOST-only control | We ship a joystick + configurable schemes; the reference has no scheme choice. |
| Its spatial hash | Ours is server-side and already O(1)-bucketed. |
| Full-screen drag steering | Worth **considering as an added scheme**, not a replacement — see S6. |

**S6 · "Drag anywhere to steer" as an optional control scheme** *(proposed, needs your call)*
The reference's argument is good: no stick to find, no dead zone, and your thumb never covers
what it's steering. We have a scheme picker already (`SnakeChoiceStore.ControlScheme`), so this
is additive and low-risk. Flagged rather than assumed.

---

## Ludo — dice, tokens, and the board radius

### What we adopt

**L1 · Board corner radius** *(you asked for this explicitly)*
`LudoDimens.boardCornerRadius` is currently **`0`** — the board is a hard square.
The reference clips to `14pt` with a brass hairline over it. Set ours to a scaled value
(≈`0.035 × side`, so it holds at every board size) and mirror it in
`apps/android/.../ludo/LudoDimens`. Three call sites on iOS
(`LudoBoardCanvas.swift:80,192`, `LudoGameView.swift:704,721`, `LudoWalkthroughView.swift:146`)
and two on Android (`LudoBoardDraw.kt:65,185`, `LudoScreen.kt:448`) already read the token,
so this is a **one-value change** on each platform. The perimeter path already takes a radius.

**L2 · Cell corner radius**
`cellCornerRadiusFactor` is also `0`, clamped to 2pt in `LudoCellView.swift:46`. A ~`0.08`
factor softens the grid without losing the printed-board read. Same token on both platforms.

**L3 · Dice bevel and drilled pips**
This is where the reference die genuinely beats ours. `DieFace` layers:
1. a diagonal gradient body (so the face has direction and edges are visible where faces meet),
2. a bevel stroke — bright top-left, dark bottom-right — which is what reads as *moulded* rather than *printed*,
3. pips drawn as a dark disc **with an inner highlight offset down-right**, which sells a hollow rather than a dome,
4. a per-face darkening proportional to `1 - facing`, so turned faces shade correctly.

Ours draws flat faces with flat pips. All four layers are pure `Canvas` work and port cleanly
to both SwiftUI `Canvas` and Compose `DrawScope` — **no 3D transform needed**, because we keep
our own 2.5D projection.

**L4 · Depth slabs at rest**
The reference draws two offset slabs *behind* the die when it settles square, so a resting die
reads as a cube with a visible bottom and right edge instead of a flat square. It culls them
mid-tumble where the real faces do the job. We settle square too (`LudoDieView.swift:205`) and
have exactly this problem. Two rounded rects.

**L5 · Token: highlight, hollow, contact shadow**
Reference `TokenView` = fill + blurred top-left specular + white centre + white rim + drop
shadow. Our `LudoPawnShape` pin has the silhouette but the surfaces are deliberately blank
(`LudoPawnShape.swift:6`). Add the specular and contact shadow; **keep our pin silhouette** —
it is more legible on a 15×15 grid than a flat disc, and it's already parity-locked with Android.

**L6 · Expanding halo on movable tokens**
Reference rings a live token with a circle that scales `0.75 → 1.25` while fading out, on a
1.1 s repeat. Ours uses concentric static strokes (`LudoPawnShape.swift:94`). The expanding
version is more obviously an invitation to tap.

**L7 · Landing spring**
Reference `Theme.land = .spring(response: 0.26, dampingFraction: 0.55)` — a deliberate overshoot
so a token *lands* rather than slides. Plus a `1.06` scale + `-0.32` lift during the hop.
Audit our hop timing against `hop = 150 ms` per square and adopt the overshoot.

**L8 · Move hints — the outlined landing square**
The reference author calls this *"the single biggest usability win over every Ludo
implementation I could find"*: before you commit, an outlined square pulses **where the token
will land**. We highlight the *token* that can move, not the *destination*. Our server already
sends `legalTokenIds`, and `LudoBoardCanvas.legalCellHighlights` already resolves token → cell —
so the data is there; this is a rendering addition.

### What we reject

| Reference feature | Why not |
|---|---|
| Per-face quaternion + `rotation3DEffect` | iOS-only. Compose has no equivalent, and dice parity across platforms is a hard requirement (`LudoDieView.swift:6`). Keep our 2.5D projection, take the *shading*. |
| `Theme` enum / `Color(ludoHex:)` | We have `LudoTheme` + design tokens already. Its own header warns about the name collision. |
| `LudoEngine` / `LudoGame` | Client-side rules. Ours are server-authoritative with bots. Non-starter. |
| Flat disc tokens | Our pin is more legible at cell size and is parity-locked. |
| Its seat palette | Ours is already accessibility-audited (`LudoAccessibility.swift`). |

---

## Work summary

**Snake** — 5 adopted (S1–S5) + 1 flagged (S6). Two are server-side (S1, S5), three are
client render/tuning (S2–S4). Both platforms.

**Ludo** — 8 adopted (L1–L8). L1/L2 are single-token changes. L3/L4 are the dice face rework.
L5–L7 are token polish. L8 is the one new feature. Every item must land on **iOS and Android
together**, and L1–L4 additionally need the `ludo_board_v3.json` fixture and
`LudoGeometryFixtureTest` checked, since geometry tokens are fixture-verified.

**Not doing:** any rendering-architecture swap, any move of rules to the client, and any
iOS-only visual technique.


---

## What actually shipped

Implemented across four commits. Three proposals did not survive contact with the
codebase, and the reasons are worth keeping.

### Landed

| ID | Change | Platforms |
|---|---|---|
| L1 | Board corner radius, as a fraction of the board side rather than an absolute value | iOS + Android |
| L2 | Cell corner radius (0.08 factor, still clamped to 2pt) | iOS + Android |
| L3 | Die face: diagonal gradient, bevel, outline ordering | iOS + Android |
| L4 | Die depth slabs at rest | iOS + Android |
| L5 | Token specular highlight (contact shadow already existed) | iOS + Android |
| L7 | Hop arc + landing overshoot on the final leg | iOS + Android |
| L8 | Move hints — destination marks, heavier ring on a capture | iOS + Android |
| S1 | Eat radius scales with mass | server |
| S3 | Gaze leads the turn on remote snakes | iOS |
| S4 | Tail alpha falloff by arc length | iOS |

### Dropped, with cause

**S1 was not implemented as magnetism.** The plan called for pellets sliding toward the
head. The food protocol sends only *adds and removals* — food was once 59% of a 7 KB
payload — so moving a pellet has no representation on the wire, and giving it one would
undo that optimisation. The real defect turned out to be adjacent and better: `EAT_RADIUS`
was a fixed 28 while `radiusFor` grows a head to 2.2x, so eating got *harder* as you grew.
Scaling the mouth on the same curve buys the same "a near miss still rewards you" feel,
and because a wider mouth clears pellets sooner it *lowered* sustained bandwidth from
30 KB/s to 28 KB/s.

**S5 (corpse pop) was dropped** for the same wire reason. Corpse food already scatters
along the body with jitter, and already returns the *whole* body rather than the
reference's 62%, so the remaining gain was an outward drift that only per-tick pellet
positions could express.

**S2 (camera easing) was audited and deliberately left alone.** Ours eases on an 80 ms
time constant; the reference's `lerp(t: dt * 9)` works out to ~103 ms at 60 fps. Ours is
already the tighter of the two, its value carries a written rationale, and it has
look-ahead the reference has no equivalent for. The audit was the deliverable and its
answer was "already correct".

**L6 (expanding halo) was rejected.** Our marching dashes carry the same "you can tap
this" signal and survive colour-blindness and dark mode, which a ring that reads only as
motion-plus-hue does not.

**S6 (drag-anywhere steering) was not implemented** — it is an added control scheme and a
product decision, not a parity fix.

### Found along the way

- **Android's perimeter path** never inset by half its stroke and never clamped its radius.
  Invisible at radius 0; at a real radius the border straddled the board edge and chewed
  its own corners. iOS already did both.
- **`yardPocketRadiusFactor` is 0.72 on iOS and 0f on Android**, and Android never reads
  it — the yard pockets genuinely differ between platforms. Left as-is: out of scope here,
  but it is a real parity gap.
- **The radius-scaling test was fragile.** It filtered to snakes still alive at 45 s, which
  is a property of the seed rather than of radius scaling — on seed 88 a bot reaches 453
  mass then dies before the end, so it reported "nothing grew" while the thing under test
  worked. Now tracks the fattest snake seen at any point, and still fails, legibly, when
  radius scaling is stubbed out.
