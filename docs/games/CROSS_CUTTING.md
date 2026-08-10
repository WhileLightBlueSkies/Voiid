# Cross-cutting gaps — what is missing from *all* the games

The per-game docs cover what each game lacks. This one covers the gaps that are nobody's game in particular, and it is where most of the retention lives.

**The one-line summary:** you can play a match, and then nothing happens. There is no rematch, no record, no progression, and no reason the next match should exist.

---

# 1. No rematch — the highest-value missing button in the product

Snake's Restart mints a fresh **solo** match. Tic Tac Toe, RPS and Hand Cricket have **no online rematch at all** — to play the same friend again you go back to the Games tab, pick the game, pick the friend, and send a whole new invite, then they have to accept it again.

Every casual multiplayer game lives or dies on this button. Two people who just played each other are the two people most likely to play again in the next thirty seconds, and the app makes it a six-tap round trip.

**Shape:** a `POST /games/matches/:id/rematch` that clones the match with the same players and options, auto-accepted for whoever requested it, pending for the other. Show it on the post-match screen with the opponent's name on it.

---

# 2. No post-match screen worth the name

Snake's entire post-match experience is `"You finished with 47"`.

The match is where the story is, and it is discarded at the moment it is most interesting. Missing everywhere: final placement, per-match stats, whether it was a personal best, what changed in the head-to-head record, and the rematch button from §1.

```
┌─────────────────────────────────┐
│         YOU WON                 │
│   Length   142   ↑ personal best│
│   Kills      7                  │
│   Rank     1st of 6             │
│                                 │
│  [  REMATCH  ]   [   Exit   ]   │
│         Share result →          │
└─────────────────────────────────┘
```

**"Share result" matters more than it looks.** This app is a messenger. A match result that can be dropped into the chat it was arranged in is the app's single structural advantage over every standalone game, and it is unbuilt.

---

# 3. Match history: the endpoint exists and nothing calls it

`GET /games/matches` returns id, slug, name, status, players and winner. Neither `GamesAPI.swift` nor `GamesService.kt` has a method for it.

**A player cannot see a single match they have ever played.** This was in the 2026-08-07 audit and is still true.

---

# 4. No per-player stats, no head-to-head

`game_match_results` holds score and placement per player and is written on every match end. It is queried by exactly one thing: the global leaderboard.

Everything below is a query away and none of it exists:

- Wins / losses / streaks per game
- Best Snake length, highest cricket score, longest win streak
- **Head-to-head record against each friend** — "You 4 — Priya 3"

Head-to-head is the important one. A global leaderboard is abstract; a running score against a specific friend is a rivalry, and rivalries are what make people open the tab.

---

# 5. No progression of any kind

No XP, no levels, no unlocks, no daily challenges, no achievements. `snake-play.md` §23 specifies cosmetics with cosmetic-only monetisation; `SnakeSkins` exists but everything in it is available immediately, so it is a preference rather than a reward.

**Cheapest high-value version:** a **daily challenge**. One seeded Snake arena per day, identical for everyone, leaderboard resets at midnight. Reuses the entire existing stack — one seed parameter, one leaderboard query, one push notification — and it is the highest retention-per-line-of-code feature in casual gaming.

---

# 6. No AFK / abandonment handling

Planned in [`GAMES.md`](../GAMES.md) §7, never built.

- A turn-based match with an absent opponent **hangs forever**. There is no move timer and no forfeit.
- An arcade match with a disconnected player **keeps ticking with a ghost**.

Both are worse than losing, because the player cannot even leave cleanly. Needs a per-match move timeout (60 s → forfeit) for turn-based, and a disconnect grace period for Snake.

---

# 7. No reconnect / resync state on any game screen

If the socket drops mid-match the screen simply freezes with no explanation — indistinguishable from the app hanging. Every game needs a "Reconnecting…" state, and Snake needs it most.

---

# 8. Invites are still a 20-second poll

The invite rides the E2EE message pipe (correct — it gets wake and push for free), but the Games tab learns about it on its next 20 s poll. A friend invites you and you find out up to 20 seconds later, which is long enough for them to give up.

`ChatEngine` already receives the invite in real time; have it post into the Games tab on receipt.

---

# 9. The flow still asks questions before the player has committed

Playing a friend is 6+ taps through three stacked modals, and depends on the opponent opening a specific chat thread.

**The principle to design against:**

> A player who opens the Games tab should be in a match within two taps, without making a single decision they don't care about yet.

Difficulty, opponent and overs are all *adjustments*, and adjustments belong **after** the default, not before it. Full proposed flow in [`../GAMES_AUDIT.md`](../GAMES_AUDIT.md) §8 — still accurate, still unbuilt.

The missing piece at the top of the Games tab is a **Continue strip**: live matches, your-turn matches and pending invites in one list. That is where a returning player looks first and it does not exist.

---

# 10. Tournaments are built and unreachable from Games

[`backend/games/src/tournaments.ts`](../../backend/games/src/tournaments.ts) implements bracket advancement and forfeits (344 loc), and the migration exists — but the entire tournament UI lives under **Communities**. There is no path from the Games tab to a tournament and no bracket view.

---

# 11. No how-to-play, anywhere

No game explains itself. Hand Cricket is unplayable without it (see [`CRICKET.md`](./CRICKET.md) §2.1).

---

# 12. No game settings

Sound on/off, haptics on/off, Snake control scheme, left/right-handed layout, graphics quality on low-end Android. None of it exists, and the audio that shipped recently makes the first two genuinely necessary.

---

# 13. No accessibility pass

Snake identifies players **by colour alone** (a problem for ~8% of men), no reduce-motion support despite shipping hitstop and screen shake, no VoiceOver/TalkBack labels on boards, no dynamic type in HUDs.

Reduce-motion is the urgent one: hitstop and shake shipped without it, and for a motion-sensitive player that is a game they cannot play at all.

---

# Priority

| # | Item | Why first |
|---|---|---|
| 1 | **Rematch** (§1) | Highest value per line of code in the entire games surface |
| 2 | **Post-match summary + share to chat** (§2) | Gives the match a story, and share-to-chat is the app's structural advantage |
| 3 | **Head-to-head record** (§4) | Turns four disposable games into ongoing rivalries |
| 4 | **AFK / forfeit handling** (§6) | Matches that hang forever are worse than losses |
| 5 | **Reconnect state** (§7) | Currently indistinguishable from a crash |
| 6 | **Real-time invites** (§8) | Drops a 20 s wall in front of every friend match |
| 7 | **Reduce-motion + colourblind palette** (§13) | Shipped motion without an opt-out |
| 8 | **Match history UI** (§3) | Endpoint already built |
| 9 | **Daily challenge** (§5) | Best retention-per-effort available |
| 10 | **Two-tap flow + Continue strip** (§9) | Larger change; do it once the above give the tab something to show |
