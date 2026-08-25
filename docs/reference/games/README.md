# Ported reference Games screens — NOW WIRED (kept here as the pristine copies)

> **STATUS CHANGED.** These two screens are now compiled and live at
> `apps/ios/Voiid/Voiid/Games/Reference/`, wired to the real party lobby
> (`database/migrations/052_game_lobbies.sql` + the lobby block in
> `backend/api/src/routes/games.ts`). The `.reference` files here remain the **pristine
> originals** and are what a restore should copy from — the shipped copies differ from them
> only by comments, lifecycle modifiers and three action bodies (`diff` them to confirm).
>
> The reasoning below is the record of why they were held back, and it was correct *at the
> time*: there was no ready-state, no join code and no lobby chat to bind them to. That is
> what changed — the backend for all three now exists, so the objection is answered rather
> than overruled. See the header of `Games/Reference/LobbyState.swift` for what is backed by
> a column and what is local-only.

## The original decision (superseded)


These two files are the design reference's **party lobby** flow. They are kept here for the
design record and are deliberately **outside the compiled source tree** — the Xcode project
uses filesystem-synchronized groups, so anything left under `apps/ios/Voiid/Voiid/` compiles.

## Why they were not wired

The reference lobby is a party lobby: solo/duo/squad modes, per-member ready-states, a host
badge, per-member mic toggles, a lobby chat with quick reactions, a copyable team code, a
public/private room switch, and crossplay / voice-chat / fill-empty toggles. The countdown
screen that follows it ticks eight seconds to a match start that a server schedules.

**Voiid's lobby is none of that.** It is an invite that waits for acceptance:
`Games/GameLobbyView.swift` sends the invite through the E2EE message pipe and watches for the
opening `game_state` frame, which the server broadcasts only once every seat is filled. There
is no ready-state to set, no lobby chat channel, no team code, no voice transport, no crossplay
concept, no matchmaking to fill empty seats with strangers, and no scheduled start moment.

Two options were considered:

* **(a) bind the reference lobby to the real match's `player_ids` + invite state.** Rejected:
  it would still ship ready-state checkmarks nothing sets, a chat that sends nowhere, a team
  code that joins nothing, and toggles for transports that do not exist. Stripping all of those
  out leaves the reference layout looking like `GameLobbyView` already does, having replaced a
  working screen with a reimplementation of itself.
* **(b) route the flow through the real `GameLobbyView`.** Chosen. It already handles both the
  2-player case and the multi-seat case (`seatCount`, filling pips), invite expiry, decline on
  cancel, and the "we are live" frame — including the multi-seat Ludo path that just landed.

The wired flow is therefore: `GamesScreen` → `GameDetailScreen` → `GameSetupSheet` →
`OpponentPickerSheet` / `SeatPickerSheet` → **`GameLobbyView`** → the game's own renderer.
