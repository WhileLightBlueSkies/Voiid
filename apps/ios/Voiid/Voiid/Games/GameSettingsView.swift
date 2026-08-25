//
//  GameSettingsView.swift
//  Voiid
//
//  Game settings — the ONE screen, reached from the ONE door: the `slider.horizontal.3`
//  button in the Games tab header, beside Leaderboard and Match History.
//
//  ── WHY IT LIVES IN THE GAMES TAB AND NOT IN SETTINGS ───────────────────────────
//  This screen spent one revision as a "Games" row inside the main Settings tree. That was
//  the wrong call and it has been reversed: `SettingsRoute.games` and its row are gone.
//  These are settings ABOUT THE ARCADE — how a match sounds, which games sit on your shelf
//  — and the arcade is where a player is standing when they want to change them. Sending
//  them out of the tab, up through Settings, past Backup and Payments, and back down into a
//  screen about games is three navigations to reach the thing that was one tap away.
//
//  THERE IS EXACTLY ONE ENTRY POINT AND IT IS THE GAMES HEADER. Do not add a Settings row
//  "for discoverability". A screen with two doors makes the user wonder whether they are the
//  same screen, and the visibility list here would then be a control they had to guess the
//  location of.
//
//  ── WHAT IS HERE, AND WHAT DELIBERATELY IS NOT ──────────────────────────────────
//  Everything on this screen is ARCADE-WIDE:
//
//    * Sound and haptics — what any match does to your senses.
//    * Visible games — which catalog rows appear on the Games home.
//
//  PER-GAME settings are NOT here and that split stays. Snake's steering scheme lives on
//  Snake's own detail screen via `Games/Reference/GameSettingsCard.swift`, because a setting
//  that affects exactly one game, shown under a header reading "Game settings", is how a
//  player ends up hunting for why it did nothing in cricket. That split was right; only the
//  location of THIS half was wrong.
//
//  ── PERSISTENCE IS UNCHANGED, DELIBERATELY ──────────────────────────────────────
//  Both toggles read and write the exact same statics the old sheet did, which means the
//  exact same UserDefaults keys with the exact same inverted-sense semantics:
//
//    Sound   → `GameAudio.isMuted`      → "voiid.gameSoundEnabled_v1_default_on"
//    Haptics → `GameHaptics.isDisabled` → "voiid.gameHapticsEnabled_v1_default_on"
//
//  Both keys store ENABLED and are read inverted (see those files for why, including the
//  bug that reasoning was written to prevent). Nobody's existing choice resets on upgrade
//  because nothing about the storage moved — only the pixels did.
//
//  Visibility is the exception, and on purpose: it is SERVER-side, one key inside the shared
//  `user_game_preferences.preferences` blob, so a shelf curated on a phone is the same shelf
//  on a tablet. It is not in UserDefaults and must not be mirrored there — a local copy that
//  disagreed with the server would hide a game the user had already un-hidden elsewhere.
//
//  ── AND NOTHING ELSE ────────────────────────────────────────────────────────────
//  docs/games/CROSS_CUTTING.md §12 also lists a left/right-handed layout and a
//  graphics-quality tier. Neither is implemented, so neither is here. A third toggle
//  invented to make this screen look fuller would be a control that lies about having an
//  effect, which is the exact failure the Settings rebuild exists to remove.
//

import SwiftUI

struct GameSettingsView: View {

    /// The SAME store the Games home reads.
    ///
    /// Passed in rather than constructed here, and that is load-bearing: flipping a switch
    /// on this screen writes `store.hiddenSlugs`, and because the home is observing that
    /// exact object the shelf behind this push is already correct when the user swipes back.
    /// A private store would have left them looking at the games they just hid.
    let store: GamesStore

    // Seeded from the persisted values on construction rather than bound directly to them:
    // the stores are plain UserDefaults-backed statics, not observable, so a @State mirror
    // is what makes the switches move. Same approach the old sheet took, same reason.
    @State private var soundOn = !GameAudio.isMuted
    @State private var hapticsOn = !GameHaptics.isDisabled

    /// The visibility section's own three states. SEPARATE from the catalog's: the games
    /// list can be sitting in memory from the home screen while THIS screen's preferences
    /// call is still in flight or has failed, and one spinner for both would misreport it.
    @State private var visibilityState: VisibilityState = .loading

    /// In-flight write, so a rapid series of toggles cannot land out of order.
    @State private var writeTask: Task<Void, Never>?

    /// A write that did not reach the server. Named on screen, because the switch has
    /// already moved and a silent failure would leave the user believing a lie.
    @State private var writeFailed = false

    private enum VisibilityState {
        case loading
        case loaded
        /// Could not read the hidden set. NOT the same as "nothing is hidden" — see below.
        case failed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                VoiidSettingsHeader("Game settings",
                                    subtitle: "Sound, feedback, and which games you see.")

                // ONE CARD, NOT TWO. Sound and haptics are the same kind of thing — what a
                // match does to your senses — and the footer below answers both at once.
                //
                // The footer is LOAD-BEARING and moved across verbatim: it corrects the
                // assumption the Sound toggle would otherwise create, which is precisely
                // what a Settings footer is for.
                VoiidCardSection(footer: "Games play at your media volume, even on silent. "
                                       + "They never play over a call.") {
                    VoiidSettingsRow(icon: "speaker.wave.2.fill",
                                     title: "Sound",
                                     detail: "Crowd, chalk, and everything else in a match") {
                        Toggle("", isOn: $soundOn)
                            .labelsHidden()
                            .tint(VoiidColor.primary)
                    }
                    .accessibilityHint("Turns match audio on or off for every game")
                    .onChange(of: soundOn) { _, on in
                        GameAudio.isMuted = !on
                        // Silence anything already ringing out — a crowd bed that keeps
                        // playing after the switch flips reads as the setting not working.
                        if !on { GameAudio.shared.stopAll() }
                        // The confirming tap fires only when turning sound ON. Turning it
                        // off and being answered by the device is a small joke at the
                        // player's expense.
                        if on { Haptics.tap() }
                    }

                    VoiidRowDivider()

                    VoiidSettingsRow(icon: "iphone.radiowaves.left.and.right",
                                     title: "Haptics",
                                     detail: "Buzz on eats, kills and wickets") {
                        Toggle("", isOn: $hapticsOn)
                            .labelsHidden()
                            .tint(VoiidColor.primary)
                    }
                    .accessibilityHint("Turns in-match vibration on or off for every game")
                    .onChange(of: hapticsOn) { _, on in
                        GameHaptics.isDisabled = !on
                        // Fired AFTER the write, so switching haptics on demonstrates
                        // itself and switching them off is silent — the setting proving it
                        // took effect.
                        if on { Haptics.tap() }
                    }
                }

                visibleGamesSection

                // WHERE THE PER-GAME SETTINGS WENT. Without this line the split reads as a
                // loss: a player who knew Snake's steering lived beside these two toggles
                // would conclude it was removed. Naming the new home costs one sentence and
                // saves the hunt (§4 Familiarity, §"Wayfinding").
                Text("Settings that apply to a single game \u{2014} like Snake's steering "
                   + "\u{2014} live on that game's own screen.")
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(VoiidSpacing.md)
        }
        .voiidSettingsPage()
        .task { await loadVisibility() }
    }

    // MARK: - Visible games

    // ── A PREFERENCE, NOT MODERATION ────────────────────────────────────────────────
    //
    // Switching a game off here removes it from YOUR Games home — the carousel, the category
    // chips and the grid. It does nothing to anybody else's app, and it does not disable the
    // game for you either: an invite from a friend to a game you hid still arrives as a
    // banner, still joins, and still opens. The server's invite query filters on match status
    // and player membership and never joins this preference (see routes/games.ts). That is
    // the difference between tidying a shelf and blocking a game, and only the first is on
    // offer here — which is why the footer says so rather than leaving the user to guess.

    @ViewBuilder
    private var visibleGamesSection: some View {
        VoiidCardSection(footer: visibilityFooter) {
            switch visibilityState {
            case .loading:
                // A row-height spinner rather than a full-screen one: the two toggles above
                // are already usable and blanking them to wait on an unrelated call would be
                // the slower screen pretending to be the whole screen.
                HStack {
                    Spacer(minLength: 0)
                    ProgressView().tint(VoiidColor.accent)
                    Spacer(minLength: 0)
                }
                .frame(height: 64)

            case .failed:
                // FAILS OPEN AND SAYS SO. `store.hiddenSlugs` is untouched by a failed read,
                // so the home keeps showing every game — the safe direction, because the
                // alternative is a network blip that empties the arcade. The retry is here
                // because this screen is the one place that can act on the error.
                VoiidSettingsRow(icon: "wifi.exclamationmark",
                                 title: "Couldn't load your list",
                                 detail: "Every game is showing until this loads") {
                    Button("Retry") { Task { await loadVisibility() } }
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.accentInk)
                }

            case .loaded:
                if store.games.isEmpty {
                    // NO CATALOG, so nothing true to list. Inventing rows here is the one
                    // thing this screen must never do — every switch has to name a real game.
                    VoiidSettingsRow(icon: "gamecontroller",
                                     title: "No games to show",
                                     detail: "Open the Games tab to load the catalog") {
                        EmptyView()
                    }
                } else {
                    // Catalog order, the server's order — the same order the home grid uses,
                    // so finding a game here means looking where you last saw it.
                    ForEach(Array(store.games.enumerated()), id: \.element.id) { index, game in
                        if index > 0 { VoiidRowDivider() }
                        gameRow(game)
                    }
                }
            }
        }
    }

    private func gameRow(_ game: Game) -> some View {
        // Bound through the store rather than a local mirror, so the switch's position is
        // always the shelf's actual state — including after a failed write reverts it.
        let visible = Binding(
            get: { !store.hiddenSlugs.contains(game.slug) },
            set: { on in setVisible(game.slug, on) }
        )
        return VoiidSettingsRow(icon: game.category.icon,
                                title: game.title,
                                detail: game.category.rawValue) {
            Toggle("", isOn: visible)
                .labelsHidden()
                .tint(VoiidColor.primary)
        }
        .accessibilityHint("Shows or hides \(game.title) on the Games home")
    }

    private var visibilityFooter: String {
        if writeFailed {
            return "Couldn't save that change. Check your connection and try again."
        }
        // The reassurance is the POINT of this footer, not filler: "hide" is a word people
        // reasonably read as "block", and a player who thinks hiding Ludo will break their
        // friend's invite simply will not use the feature.
        return "Hidden games disappear from your Games home. They stay hidden only for you, "
             + "and an invite from a friend still works."
    }

    /// Flip one game and persist the WHOLE hidden set.
    ///
    /// OPTIMISTIC, then corrected. The switch moves immediately — a toggle that waits on a
    /// round-trip before moving feels broken — and reverts only if the write actually fails,
    /// with the footer saying why. Silently reverting would be worse than not moving at all.
    private func setVisible(_ slug: String, _ visible: Bool) {
        let before = store.hiddenSlugs
        if visible { store.hiddenSlugs.remove(slug) } else { store.hiddenSlugs.insert(slug) }
        Haptics.tap()
        writeFailed = false

        // Cancels the previous write first: flipping four switches quickly would otherwise
        // put four PUTs in flight with no ordering guarantee, and the LAST one to land — not
        // the last one sent — would decide the stored list.
        writeTask?.cancel()
        let snapshot = store.hiddenSlugs
        writeTask = Task {
            do {
                try await api.setVisibility(hiddenSlugs: Array(snapshot).sorted())
            } catch is CancellationError {
                // Superseded by a newer toggle; that write owns the outcome now.
            } catch {
                guard !Task.isCancelled else { return }
                // Put the shelf back to what the server still believes, so the switch and
                // the Games home never disagree about what is stored.
                store.hiddenSlugs = before
                writeFailed = true
            }
        }
    }

    private func loadVisibility() async {
        visibilityState = .loading
        do {
            store.hiddenSlugs = Set(try await api.visibility())
            visibilityState = .loaded
        } catch {
            // NOT `.loaded` with an empty set: "we could not ask" and "nothing is hidden"
            // look identical in the data and are completely different facts. The state
            // carries the difference so the section can say which one happened.
            visibilityState = .failed
        }
    }

    private var api: GamesAPI { GamesAPI() }
}
