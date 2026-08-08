# Snake — Visual Overhaul

Status: spec, not yet built. Read [`GAMES.md`](./GAMES.md) first — this changes only how Snake
is DRAWN. The simulation, the wire protocol's existing fields, and the server-authoritative
model are untouched except for one added field (§2.1).

---

## 1. Where we are, and where we're going

Today every snake is a single flat stroke in one palette colour, on a plain dark disc. It
reads as a diagram of a snake rather than a creature. The target is the reference look: bodies
made of **repeating colour bands**, **character heads with faces**, a **hex-tiled arena floor**,
and a HUD with a **crowned leaderboard** and a **rocket boost pedal**.

| Element | Now | Target |
|---|---|---|
| Body | one flat stroke, one colour | banded segments along the arc, per-skin palette |
| Head | coloured circle + two eyes | skin face (bunny, corgi, lion…) or patterned cap |
| Floor | flat radial gradient | hexagon tile lattice, theme-tinted |
| Food | flat dot + halo | glowing orb with bloom |
| Leaderboard | plain rows | crown on #1, rank chips, live re-order |
| Joystick | plain ring + knob | ring with inner track, pressed state |
| Boost | text "BOOST" | rocket glyph in a matching ring |

> **On the references.** We are taking the visual *language* — banded bodies, hex floor,
> expressive heads — not the artwork. Snake.io's actual characters are someone else's IP, so
> every skin here is drawn for us. That is a legal constraint, not an aesthetic one, and it
> is also an opportunity: Voiid skins can key off the app's own palette.

---

## 2. Skins

### 2.1 The one wire change

`SnakeState` gains a skin id, alongside the existing `c` (colour index), `hr` (head radius)
and `n` (name):

```ts
// backend/games/src/engine/snake/index.ts
sk: sn.skin,   // string, e.g. "rainbow" | "bunny" | "lava"
```

Sent **only on full frames**, exactly like `n` — a skin never changes mid-match, and the
clients already carry names across delta frames (`carried` in both `parseSnake`
implementations). Reuse that mechanism verbatim; do not add a second one.

Assignment mirrors `BOT_NAMES`: a `BOT_SKINS` pool shuffled by the match seed, so every device
shows the same snake wearing the same skin. Humans send their chosen skin at match creation
via the existing `options` bag (`{ skin: "rainbow" }`), validated and clamped server-side like
every other option.

### 2.2 Catalogue

A skin is data, not code — one entry per skin, shared by both platforms:

| Field | Meaning |
|---|---|
| `id` | wire value |
| `bands` | ordered colours repeated along the body |
| `bandLength` | world units per band (14 = one segment) |
| `outline` | rim colour, or none |
| `face` | head sprite id, or none → draws the default eyes |
| `glow` | additive halo tint |

Launch set — deliberately small, and every one buildable from `bands` alone except the four
faces:

```
rainbow    bands: red orange yellow green blue indigo violet   bandLength 14
candy      bands: white pink white pink                        bandLength 10
lava       bands: #FF3B00 #FF8A2B #FFD93D                      bandLength 12   glow: orange
frost      bands: #8DF7C8 #4DA8FF #FFFFFF                      bandLength 16   glow: cyan
shadow     bands: #2B2B3F #4A4A6A                              bandLength 18
bunny      bands: white #F5F5FF   face: bunny
corgi      bands: #E8A15C #FFF1DC face: corgi
lion       bands: #D9913F #B4762E face: lion
unicorn    bands: pastel rainbow  face: unicorn   glow: magenta
```

The existing 12-colour `PALETTE` stays as the fallback for any snake whose skin is unknown —
an old client meeting a new skin must degrade to a solid colour, never to nothing.

### 2.3 Drawing a banded body

This is the single biggest visual change and it replaces one line on each platform.

Today the body is one stroke over the whole trail. Instead, walk the trail by arc length and
stroke **one span per band**:

```
arc = 0
i = 0
while arc < bodyLength:
    next = min(arc + bandLength, bodyLength)
    strokeSpan(trail, from: arc, to: next, colour: bands[i % bands.count])
    arc = next; i += 1
```

Three things matter for this to look right rather than striped-and-cheap:

- **Overlap each span by ~1 unit** at both ends. Butt-jointed spans leave hairline gaps on
  curves, which is exactly where the eye is drawn.
- **Bands must be anchored to the HEAD, not the tail.** Anchoring at the tail makes the whole
  pattern crawl backwards as the snake eats, which reads as a rendering fault.
- Keep the existing glow pass underneath (`width * 1.7`, alpha 0.22) as a single solid colour
  — a banded glow just muddies.

Existing code to change:
- iOS: `SnakeRenderer.buildSnake` in `SnakeMetalView.swift` — `appendRibbon` already takes a
  colour, so this is a loop around it rather than new geometry.
- Android: `drawSnake` in `SnakeArenaScreen.kt` — the `drawPath` calls become a span loop over
  the same `Path` construction.

### 2.4 Heads

Faces are sprite quads over the head circle, rotated to the heading — iOS already has the
pipeline (`spriteVertex` / `SpriteInstance`, used for name plates); Android draws them as
`ImageBitmap`s in the same `DrawScope`.

The default (no `face`) keeps today's two eyes, which already track the joystick for the
local player and should stay — it is most of what makes the snake feel connected across a
10 Hz link.

Faces are drawn **after** the body and **before** name plates, so a label is never covered by
a nose.

---

## 3. Arena

### 3.1 Hex floor

A hexagon lattice, drawn once into a tile texture and repeated — never per-hex geometry. At
120-unit hex width the arena holds a few hundred hexes; instancing them individually would
cost more than the snakes do.

- iOS: bake the tile into an `MTLTexture` at load, draw as one large `SpriteInstance` with a
  repeat sampler, UVs scaled by `arenaRadius / tileSize`.
- Android: build a `TileMode.Repeated` `ImageShader` once in `remember`, fill the arena circle
  with it.

Keep it dark and low contrast — **the floor is a texture, not a subject**. If the hexes are as
bright as the food, the food stops reading as food.

### 3.2 Boundary

Unchanged in behaviour and this is deliberate: the ring is drawn EXACTLY on the lethal radius,
because a wall whose visible edge disagrees with the killing surface makes every border death
feel unfair. Add only a soft inward gradient so the edge glows rather than sitting flat.

### 3.3 Food

Reference food is a bright core with a wide soft halo. iOS gets this nearly free — the bloom
pass already in `Snake.metal` (`bloomCompositeFragment`) picks up anything bright. Android
approximates with the existing two-circle halo plus a `BlurMaskFilter` core.

Corpse pellets stay visually distinct (larger, warmer) — a player needs to read "someone died
here" at a glance, and that is gameplay information, not decoration.

---

## 4. HUD

Same layout on both platforms; the reference's arrangement is already close to ours.

### 4.1 Leaderboard — top-left

```
👑 Bigbos      1751
   Rich_TEA    1638
 3 Black_955   1602
 4 Boom_Boom   1549
```

- Crown glyph on #1, plain rank number from #3 down (#2 keeps a subtler marker).
- Your own row always visible and weighted heavier, even outside the top 10 — a board that
  can hide you is a board you stop reading.
- Rows animate on rank change (240 ms slide). Rank movement is the entire point of a live
  board; a board that teleports its rows is just a list.

### 4.2 Score — top-centre

Large, tabular-figure numeral for your own length. Counts up rather than snapping — see the
`animate` skill for the curve; a number that jumps is the cheapest possible tell.

### 4.3 Joystick — bottom-left

Keep the current mechanics exactly (fixed ring, knob clamped to the rim, spring-back on
release, 0.15 deadzone). Restyle only:

- outer ring: translucent fill + 2px rim
- inner track: faint circle at rest position, so the centre is visible before the thumb lands
- knob: bright, with a drop shadow

**Do not** re-key the `pointerInput` on anything that changes identity, and **do not** consume
pointer events. Both have already broken steering mid-match once each; the comments in
`VirtualJoystick` explain why and should survive any restyle.

### 4.4 Boost — bottom-right

Rocket glyph in a ring matching the joystick. Press-and-hold, never a toggle. Fills with a
radial "fuel" indicator as mass approaches the boost floor, and dims when below it — today a
player only learns boost is unavailable by pressing it.

---

## 5. Both platforms, one look

iOS renders in Metal and Android in Compose Canvas, so the two will drift unless the shared
values live somewhere neither owns. Put the skin catalogue in **one JSON file per platform,
generated from a single source** in `packages/` — the same discipline `design-tokens` already
uses in this repo.

What must match exactly: band colours, band lengths, hex tile size, HUD geometry, joystick
radius and deadzone. What may differ: how the blur is achieved, how the tile is repeated.

---

## 6. Build order

Each step is shippable and visible on its own:

1. **Banded bodies** (§2.3) with a hardcoded rainbow for everyone. The biggest visual jump for
   the least work, and it proves the span-walking maths before any assets exist.
2. **Skin catalogue + wire field** (§2.1, §2.2). Bots get varied skins; still no faces.
3. **Hex floor** (§3.1) and food glow (§3.3).
4. **HUD restyle** (§4) — crown, score, joystick, boost.
5. **Faces** (§2.4). Last because it is the only step that needs drawn assets, and everything
   above lands without an artist.

---

## 7. What this must not break

The renderer has cost real debugging time and these are the traps to keep clear of:

- **Never mutate render state inside a draw pass.** iOS froze this way; the trail store now
  lives in the Metal coordinator for exactly this reason.
- **Never re-compose the whole screen per frame.** Android's flicker was
  `snakeFrames.collectAsState()` dragging the HUD through recomposition 10x/s. The Canvas reads
  frames in its draw lambda; the HUD samples at ~6 Hz.
- **Never gate steering on "has it changed enough".** Two variants of that idea both killed
  steering permanently mid-match.
- **Body width comes from the server's `hr`**, never a local formula — it is the hitbox, and a
  fat snake dying to something that visually missed it is the worst bug this game can have.
- Bandwidth is at 24 KB/s against a 25 KB/s test ceiling. `sk` is affordable only because it
  rides full frames; anything per-frame needs measuring in `snake.test.ts` first.
