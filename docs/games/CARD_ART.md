# Game card artwork — how to make it and where it goes

> The 4:3 poster on each games-grid card, the lobby, and the invite bubble. Not in-game art:
> every board is drawn procedurally and uses no sprites at all.

---

# 1. What the cards are

One image per game, looked up **by name at runtime** from the catalog row's `icon_key`
([`GamesHomeView.swift`](../../apps/ios/Voiid/Voiid/Games/GamesHomeView.swift)), so adding a game
is a DB row plus a drop-in asset with no client change. A game whose art has not shipped falls
back to a tinted glyph rather than an empty card — which is what Sea Battle and Ludo show today.

The same image is reused in three places, which is why it has to work small:

| Where | Rendered at |
|---|---|
| Games grid | ~180×135 pt card |
| Lobby | ~340×255 pt poster, with a bottom gradient over it |
| Invite bubble in chat | ~72 pt thumbnail |

**The 72 pt thumbnail is the constraint that matters.** Anything that only reads at full size is
wasted, and fine detail turns to mush.

## 1.1 Specification

- **1448 × 1086 px** (4:3), PNG. Matches the four existing cards exactly.
- Under ~1.5 MB each. The shipped four are 1.3–1.5 MB.
- The game's name is set **inside** the artwork on the existing cards. Keep that — the card has
  no separate title label under it.
- Dark background. The grid sits on a light surface, so dark cards separate from it.

---

# 2. Free tools that can produce these

| Tool | Free tier | Why it is on this list |
|---|---|---|
| **Bing Image Creator** (DALL·E 3) | Free with a Microsoft account | Closest match to the existing card style |
| **Ideogram** | Free daily quota | **Best at text inside an image**, which these cards need |
| **Leonardo.ai** | ~150 credits/day | Game-art presets, more control over style |
| **Playground AI** | Free daily quota | Commercial use permitted on the free tier |

**Check the licence before shipping.** Free tiers differ on commercial use, and the four existing
cards' provenance is unrecorded — which is why §4 recommends regenerating all six together.

---

# 3. Prompts

Written to match the existing set: dark navy background, dotted-grid texture, glossy 3D-style
subject, bold display lettering, small neon accents.

## 3.1 Sea Battle

```
Mobile game cover art, 4:3 landscape. Bold 3D display text "SEA BATTLE" in white and
cyan with a slight metallic sheen, upper left. To the right, a stylised grey battleship
seen from a three-quarter aerial view on dark ocean water, with a red target reticle
locked on it and two small white splash markers nearby. Deep navy background with a
subtle dotted grid pattern and soft abstract wave shapes. Glossy vector game-art style,
high contrast, clean edges, no photorealism, no clutter.
```

## 3.2 Ludo

```
Mobile game cover art, 4:3 landscape. Bold 3D display text "LUDO" in white and yellow
with a glossy finish, left side. To the right, a colourful cross-shaped Ludo board seen
at a three-quarter angle with four glossy round tokens in red, blue, green and yellow,
and a single white die mid-tumble showing six pips. Deep navy background with a subtle
dotted grid pattern. Glossy vector game-art style, warm and inviting, high contrast,
clean edges, no photorealism.
```

## 3.3 The other four, if regenerating the set

**Hand Cricket** — `Bold 3D text "HAND CRICKET" in white and blue, left. To the right,
six glossy hand gestures in a circle showing one through six fingers, each ringed in a
different neon colour. Deep navy background, dotted grid, glossy vector game art.`

**Rock Paper Scissors** — `Bold 3D text "ROCK PAPER SCISSORS" stacked in white, blue and
red, left. To the right, three glossy hands — fist, flat palm, two fingers — each on a
coloured disc, arranged in a triangle with curved arrows between them. Deep navy
background, dotted grid, glossy vector game art.`

**Snake** — `Bold 3D text "SNAKE" in white and yellow, left. To the right, two glossy
cartoon snakes, one blue and one red, coiling toward each other with small coloured
pellets scattered around. Deep navy background, dotted grid, glossy vector game art.`

**Tic Tac Toe** — `Bold 3D text "TIC TAC TOE" in white and blue, left. To the right, a
glossy dark 3D grid board with blue X and red O pieces sitting in it at a three-quarter
angle. Deep navy background, dotted grid, glossy vector game art.`

## 3.4 Getting a usable result

- **Generate the whole set in one session, in one tool.** Style consistency across six cards
  matters more than any single card being perfect — the grid shows them together.
- **Expect the text to be wrong.** Most models misspell display lettering. Ideogram is the
  strongest at it; otherwise generate without text and add the name in any editor.
- **Judge them at thumbnail size.** Shrink to 72 pt before deciding. A card that only works
  large will not work in a chat bubble.

---

# 4. Dropping them in

Both platforms look the asset up by the same name, so the filename is the contract.

## 4.1 iOS

Create `apps/ios/Voiid/Voiid/Assets.xcassets/game_<slug>.imageset/` containing the PNG and:

```json
{
  "images" : [ { "filename" : "game_<slug>.png", "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

The project uses file-system synchronized groups, so **no Xcode project edit is needed** — the
folder is picked up on the next build.

## 4.2 Android

Drop the PNG at `apps/android/app/src/main/res/drawable-nodpi/game_<slug>.png`, alongside the
four already there.

**`-nodpi`, not plain `drawable`.** These are single fixed-resolution posters, not icons with
per-density variants; `-nodpi` tells Android to use the bitmap as-is rather than scaling it by
the device's density bucket, which on a high-density phone would otherwise upscale a 1448 px
image to something enormous in memory for no visible gain.

**The filename becomes a Java identifier**, so it must be lowercase with underscores only. This
is the same constraint that forced `catch_shared` rather than `catch` for the shared sound —
`R.raw.catch` does not compile.

## 4.3 Slugs

`game_seabattle`, `game_ludo`, `game_cricket`, `game_rps`, `game_snake`, `game_tictactoe`.

These must match the `icon_key` column seeded in the migrations, which already carries
`game_seabattle` and `game_ludo` — so the moment the files land, the fallback glyph is replaced
with no code change and no deploy.
