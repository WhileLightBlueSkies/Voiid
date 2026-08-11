# Snake — competitive parity against a shipped commercial .io game

> **Reference:** *Snake vs Worms io Game* v7.2.1 (`com.mygamesisland.is.snake`), Unity.
> **Method and its limits:** the game is IL2CPP-compiled, so there is **no readable rules text
> and no gameplay source**. What is readable is the class table extracted from its Unity asset
> bundle — roughly 2,500 type names. That is an inventory of what they *built*, not of how it
> works or how it feels.
>
> Everything below is therefore **"they have a system for X, we do not"** — never "their X works
> like this". Where a mechanic is inferred, it is marked as such. Nothing here is copied: no
> code, no copy, no assets. Their class names told us what to *look for*; every recommendation
> is written against our own engine.

---

## 1. The headline

**Our match is competitive. Our game is not.**

Voiid's Snake beats theirs on the thing that is hardest to build — a server-authoritative,
predicted, interpolated netcode with a free-running render clock. Their game is a Unity client
with bots (`AIProfileData`, `FakeNames`, `SnakeBotDuelMode`); ours holds up in real multiplayer.

But a player does not experience netcode. They experience **the twenty seconds before a match and
the ten seconds after**, and that is almost entirely missing from ours. Their class table shows a
full meta-game around the same core loop we already have.

The gap is not the arena. It is everything that surrounds it.

---

## 2. What they have that we do not

Grouped by what it costs us to be without it. Every row is evidenced by named types in their
build.

### 2.1 Game modes — they have five, we have one

| Their mode | Evidence | We have |
|---|---|---|
| Quick play | `QuickPlayGameMode`, `QuickModeLoadingPopup` | ~ (our default) |
| Battle royale | `BattleRoyaleMode`, `BattleRoyaleModeWinSignal` | ✗ |
| Duel (1v1) | `DuelGameMode`, `DuelModeWinSignal`, `SnakeBotDuelMode` | ✗ |
| Team play | `TeamPlayGameMode` | ✗ |
| Tutorial as a mode | `TutorialGameMode`, `TutorialSnakeBot` | ✗ |
| Mode picker | `SelectGameModePopup`, `SelectGameModeButton` | ✗ |

**Why it matters.** [`SNAKE.md`](./SNAKE.md) §3.3 already flags "one arena, one mode, forever" as
a replayability gap. This confirms the shape of the answer: a mode is not a new game, it is the
same arena with one rule changed. `GameModeBase` implies they built exactly that — one base, five
subclasses.

**Cheapest real win for us:** **Duel**. Our engine already supports a 2-player match, the
`OpponentPickerSheet` already returns one conversation, and "Snake against one friend" is the
mode a messenger is uniquely placed to offer. Battle royale is the bigger draw but needs a
shrinking border, which is engine work.

### 2.2 Progression — they have a full loop, we have none

| System | Evidence |
|---|---|
| Player level + XP | `HudLevelProgress`, `LevelProgressController`, `LevelUpPopup` |
| Challenges with metrics | `ChallengeMetric`, `ChallengeMetricsGroup`, `ChallengeCompleteRewardPopup` |
| Soft currency | `CoinsBox`, `BuyCoinsButton`, `FreeCoinsButton`, `PlayerPickupCoinSignal` |
| Daily/random reward | `LuckyWheel`, `LuckyWheelPopup`, `LuckyWheelItemsData`, `FreeGiftButton`, `GiftPopup` |
| Achievements | `Achievement`, `PlayGamesAchievement` |
| Upgradeable boosters | `BoosterUpgradesData`, `BoosterUpgradeProgressElement`, `BoosterUpgradesTab` |

**Why it matters.** [`CROSS_CUTTING.md`](./CROSS_CUTTING.md) §5 says we have "no progression of
any kind", and this is what the alternative looks like fully built. Note `PlayerPickupCoinSignal`:
coins are collected **in the arena**, so the meta-game reaches into the match rather than sitting
beside it.

**Our honest position:** we should not copy this wholesale. Most of it is free-to-play monetisation
scaffolding (`SubscriptionManager`, `OneTimeSkinOfferPopup`, `AdMobRewardedAd`) and Voiid is not an
ad-monetised game. But **one** retention hook is worth having, and CROSS_CUTTING already names the
right one: a daily challenge.

### 2.3 In-match HUD — the fairness gap

| Their HUD element | Evidence | We have |
|---|---|---|
| Live leaderboard | `Leaderboard`, `LeaderboardSlot`, `LeaderboardScoreData` | ✓ |
| Kill feed / stats | `KillEventsStatsList`, `KillPopup`, `HudStatsPanel` | ✗ |
| Booster indicator | `HudBooster` | ✗ |
| Countdown | `HudCountdown` | ✗ |
| Speed lines on boost | `HudSpeedLinesEffect` | ✗ |
| Emoji/emote in match | `HudEmojiButton`, `KillEmotePopup`, `EmotesSpritesData` | ✗ |
| Text notifications | `HudTextNotify`, `HudTextPopup` | ✗ |
| Music toggle in HUD | `HudMusicButton` | ✓ (in settings) |

**`HudSpeedLinesEffect` is the cheap one worth stealing the idea of.** Our boost has a real
cost — it drains mass and drops it as food — and the player currently has almost no feedback that
it is happening beyond the sound. Speed lines are a shader-free, few-hour effect that makes a
mechanic legible.

**Still no minimap in either game.** [`SNAKE.md`](./SNAKE.md) §3.1 calls a minimap our single
biggest playability gap; their table shows no `Minimap`/`Radar` type either. Worth noting that a
successful commercial competitor shipped without one — it weakens the "every .io game has this"
argument, though the underlying complaint (you die to things you never saw) still stands.

### 2.4 Onboarding — they teach, we do not

`Tutorial`, `TutorialNew`, `TutorialStepPopup`, `TutorialTouchZone`, `ControlsTutorial`,
`MainMenuTutorial`, `TutorialGameMode`, `TutorialSnakeBot`, `HintWidget`, `Tooltip`,
`TooltipManager`, `DoubleTapTooltip`, `CwGuide`.

That is **thirteen distinct types for teaching the game.** We have one rules list on the setup
sheet, added yesterday.

`TutorialTouchZone` and `TutorialSnakeBot` are the interesting pair: they teach **in a real match
against a scripted bot**, not on a slideshow. `DoubleTapTooltip` implies a specific input they had
to teach explicitly.

**For us:** our rules list is the right first step and probably enough for Tic Tac Toe and RPS.
Snake is the one game where a first match is genuinely confusing, and a first-run coached match is
the proven pattern.

### 2.5 Controls — they let you choose

`ControlsTab`, `ControlsModePreview`, `ControlJoystickPreview`, `ControlArrowPreview`,
`ControlSchemesView`, `SettingsControlModeButton`, `ControlsTutorial`.

They ship **at least two control schemes** (joystick and arrow/directional, per the preview class
names) with a settings tab, a live preview, and a tutorial for each.

We ship one joystick. [`CROSS_CUTTING.md`](./CROSS_CUTTING.md) §12 already lists "Snake control
scheme" as a missing setting; this confirms it is table stakes rather than a nicety. A
swipe-to-steer option in particular suits one-handed play, which is how a messenger game is
actually held.

### 2.6 Identity and social

| Feature | Evidence | We have |
|---|---|---|
| Editable display name | `ChangeNamePopup`, `PlayerProfile`, `PlayerProfileBox` | Uses contact name |
| Skins | `SkinData`, `ISkinDef`, `RuntimeSnakeSkin`, `CustomSkinDef` | ✓ `SnakeSkins` |
| **Custom/user-made skins** | `CustomSkinDef`, `ChooseActionForCustomSkinPopup` | ✗ |
| Native share | `NativeShareDialog` | ✗ |
| Emotes | `EmotesSpritesData`, `KillEmotePopup` | ✗ |

**`NativeShareDialog` is the one that should sting.** Voiid is a messenger. Sharing a result into
the chat the match was arranged in is our single structural advantage over every standalone .io
game, it is already named in [`CROSS_CUTTING.md`](./CROSS_CUTTING.md) §2, and a Unity game with no
social graph has shipped it while we have not.

### 2.7 Game feel

`CameraShaker`, `EffectPlayer`, `EffectArea`, `SkinColorParticleItem`, `AudioFadeEffect`,
`HapticFeedback`, `GameOverPopup`, `AskRevivePopup`, `GameOverSnakeWidget`.

We match most of this — we have shake, particles, hitstop, haptics and a real audio engine. Two
exceptions:

- **`AskRevivePopup`** — a revive offer on death. In their game this is monetised (rewarded ad).
  We should not copy the monetisation, but "you died at 47, continue?" is a genuine retention
  mechanic and our respawn already exists.
- **`AudioFadeEffect`** — our `CricketSound` bed does gain ramping, but Snake's audio has no
  equivalent dynamic layer.

---

## 3. What we have that they do not

Worth stating, because the list above is long and it is not a rewrite.

| Ours | Why it matters |
|---|---|
| **Server-authoritative engine** | Their bots are client-side. A modified client cannot cheat ours. |
| **Predicted local snake + interpolation** | The netcode work in `SNAKE.md` §2 has no counterpart in a single-player Unity build. |
| **Free-running render clock** | Measured: 0.26 ms delta sd vs 6.3 ms, never runs backwards. |
| **Real multiplayer with friends** | They have bots with `FakeNames`. We play actual people. |
| **Lives inside a messenger** | No .io game can arrange a match in the conversation it belongs to. |
| **First-party audio, no licences** | Their build carries AppLovin, AdMob, IronSource, Unity Ads. |

---

## 4. What to fix, in order

Ranked by (impact × cheapness), and deliberately **not** a list of everything above. Most of
their meta-game is monetisation scaffolding we do not want.

**Status: all eight are now shipped on both platforms.** Where the implementation departed from
the recommendation, the item below says so and why — in two cases (6 and 7) the recommendation
asked for a whole new mode and the shipped version deliberately is not one.

### P0 — the match has no ending

1. ~~**Post-match summary + share to chat.**~~ **ALREADY SHIPPED — this recommendation was
   wrong.** Both platforms already show final score, personal best, a "New best!" callout and a
   "Challenge a friend" share through the system share sheet (`SnakeArenaView.gameOverPanel`,
   `SnakeArenaScreen`). It was written from [`SNAKE.md`](./SNAKE.md)'s stale claim that our whole
   post-match is `"You finished with 47"` — the code was not checked. Left in, struck through,
   because a doc that quietly deletes its own mistakes teaches nobody: **verify against the code,
   not against another doc.**

2. ✅ **Rematch.** Already P1 in CROSS_CUTTING. Two people who just played are the two most likely
   to play again in the next thirty seconds.

### P1 — the match is not legible

3. ✅ **Boost feedback (speed lines + a mass/boost meter).**
   Their `HudSpeedLinesEffect` + `HudBooster`. Our boost has a real cost the player cannot see.
   [`SNAKE.md`](./SNAKE.md) §3.2 calls an invisible mechanic "an unfair-feeling mechanic purely
   because it is invisible".

4. ✅ **Kill feed.** Their `KillEventsStatsList`. Our `kill` events are already parsed on both
   platforms and render as nothing textual. "You ate Priya" is the shareable moment.

5. ✅ **Second control scheme + a settings tab.** Their `ControlsTab` and two preview classes.
   Ours is one joystick, and CROSS_CUTTING §12 already wants this.

   *Shipped:* swipe-to-steer alongside the joystick, chosen in a Snake section of the game
   settings sheet. One steering handler serves both schemes so they cannot drift, and only one
   control is ever mounted so they cannot fight over a touch. The arena reads the scheme once on
   open — changing it mid-match would move the controls out from under a thumb.

### P2 — the game does not teach itself

6. ✅ **A coached first match for Snake.** Their `TutorialGameMode` + `TutorialSnakeBot` +
   `TutorialTouchZone`. Not a slideshow: a real match against a scripted opponent. Our rules list
   covers the other three games; Snake is the one that needs more.

   *Shipped, but NOT as a mode, and not against a scripted opponent — this recommendation was
   half wrong.* A parallel tutorial arena is a second copy of the game to keep in step with the
   first, and the day they drift it teaches something false. A scripted bot is worse: a player
   beats it, meets a real one, and finds the game they were taught is not the game they are
   playing. What shipped is four coaching lines riding on top of an ordinary match. Each clears
   when the player does the thing — steering is proved by distance travelled, so it works for
   both control schemes without knowing either exists. Only the rule that kills people is told
   rather than tested, since nobody can safely be made to demonstrate dying.

### P3 — one reason to come back

7. ✅ **Duel mode (1v1 with a friend).** Their `DuelGameMode`. Cheapest new mode for us: the
   engine supports it, the picker returns one conversation, and it is the most social version of
   Snake we could ship.

   *Shipped as a choice, not a mode.* The engine already takes a player list and a bot count, so
   a duel is two seats and zero bots — a mode around that would be a second code path for a
   difference of one integer. Inviting a friend to Snake now asks how busy the arena should be.
   Zero bots is what a friend match silently already was; it is now labelled, and the lobby names
   the choice back to the creator. The same change fixed a real bug: the friend path plumbed
   `skin` as far as the API and dropped it, so a player's chosen skin never appeared in the only
   mode another human could see it.

8. ✅ **Daily challenge.** Their `LuckyWheel`/`ChallengeMetric` cluster, minus the currency. One
   seeded arena a day, shared leaderboard, resets at midnight — CROSS_CUTTING §5's own
   recommendation, and the highest retention-per-line-of-code option available.

   *Shipped, with one thing the recommendation missed:* the seed cannot come from the client.
   `POST /games/matches` passes its options bag to the engine untouched, and the engine reads
   `options.seed` — harmless for a friendly match, fatal for a ranked one, since a player could
   roll seeds locally until one produced a generous food layout. The daily therefore has its own
   route that derives the seed from the UTC date. One attempt per person per day is enforced by a
   unique index, not by the handler, because two taps in flight both pass a `select`. No new
   scores table: `game_match_results` already holds the number.

### Explicitly NOT recommended

- **Coins, gems, lucky wheels, subscriptions, rewarded-ad revives.** Their
  `SubscriptionManager`, `AdMobRewardedAd`, `BuyCoinsButton` and `OneTimeSkinOfferPopup` exist to
  monetise an ad-funded game. Voiid is a messenger; bolting a free-to-play economy onto a chat app
  would change what the product is.
- **Upgradeable boosters** (`BoosterUpgradesData`). Permanent power upgrades mean a new player
  loses to a paying one for reasons unrelated to skill. Our difficulty is bot count; keep the
  arena fair.
- **Emotes in match.** `HudEmojiButton` is a real feature, but in an app that already has a chat
  thread per match it is a second, worse messaging surface.

---

## 5. Method notes, for whoever reads this next

- **The APK first supplied was the wrong app** (`snake-is.apk` = Aptoide Games, an app store).
  The correct artefact is `Snake_vs_Worms_io_Game-7.2.1.16232.apk`.
- **No rules text was recoverable.** Unity + IL2CPP means user-facing copy lives in compiled
  assemblies and content-hashed asset blobs; the Android `strings.xml` contains only SDK
  boilerplate (AppLovin, AdMob, Firebase). Our own Snake rules were therefore audited against
  **our engine** instead — which found two of them backwards (see commit `c6876c0`).
- **Nothing was copied.** No code, no strings, no assets. The class table was read the way you
  would read a competitor's feature list on their store page.
- **Class names are evidence of existence, not of behaviour.** `BattleRoyaleMode` proves they
  have a battle royale; it says nothing about how its border shrinks. Treat every inference here
  as a prompt to design our own version, not as a spec.
