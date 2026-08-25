//
//  GameDetailScreen.swift
//  Voiid
//
//  Games flow, step 3 — the game, and the settings for a match of it.
//
//  ── ONE SCREEN, TWO JOBS, IN THE RIGHT ORDER ────────────────────────────────────
//  The top half describes the game; the bottom half configures a match. That order matters for
//  a player who arrived from a friend's invite rather than from browsing: they need to know
//  what they are joining BEFORE they are asked how many players it should have.
//
//  ── WHAT WAS WIRED, AND WHAT WAS CUT ────────────────────────────────────────────
//  The screen now describes a REAL catalog row (`Game`) rather than a `LobbyState` holding a
//  sample slide. Title, category, seat count and artwork all come off that row.
//
//  REMOVED — the Choose Mode segmented control (Solo / Duo / Squad) and the settings card
//  under it (Party Size / Difficulty / Crossplay). Voiid has none of those concepts: a game's
//  seat count is fixed by the catalog row (`min_players`/`max_players`), there is no
//  per-match difficulty for a human opponent, and there is no crossplay notion at all — every
//  client is Voiid. Rendering a chooser whose choice nothing reads would be a control that
//  lies about having an effect. What IS configurable per match — hand cricket's over count,
//  Snake's bot count — is asked at creation time in the real setup flow, because the server
//  builds the innings/arena from it and it cannot be changed afterwards.
//
//  REMOVED — the "Friends who play" strip. It was five hardcoded names and a "+12". There is
//  no per-game player roster endpoint, so nothing can populate it.
//
//  The seat-count row that replaces the settings card is the one real fact of the same kind:
//  it changes what you must arrange before you can play.
//

import SwiftUI

struct GameDetailScreen: View {

    // ── THE ONLY ADAPTATIONS IN THIS FILE ───────────────────────────────────────────
    // `game` arrives as a plain `let` instead of `@Environment(LobbyState.self)`: it is one
    // real catalog row, handed down by GamesScreen — the root of the flow — which is the only
    // thing that has fetched the catalog. `session` is an ObservableObject in Voiid, hence
    // @EnvironmentObject.
    let game: Game
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss

    var onCreateLobby: () -> Void = {}
    var onInviteFriends: () -> Void = {}

    var body: some View {
        ZStack {
            VoiidColor.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    identity
                    facts
                    rules
                    perGameSettings
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .contentMargins(.bottom, 132, for: .scrollContent)

            topBar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            footer
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear { session.requestHideTabBar() }
        .onDisappear { session.releaseHideTabBar() }
    }

    // MARK: Hero

    /// The real artwork where it has shipped, and the reference's id-keyed gradient where it
    /// has not — the same call GameArtwork makes for every other card on the tab.
    private var hero: some View {
        GameArtwork(game: game, glyphSize: 84)
        .frame(height: 268)
        .clipped()
        .overlay(alignment: .bottom) {
            // Fades the art into the page, so the title below sits on the ground rather than
            // on a hard horizontal seam.
            LinearGradient(colors: [.clear, VoiidColor.background],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
        }
    }

    private var topBar: some View {
        HStack {
            glassButton("chevron.left", "Back") { dismiss() }
            Spacer(minLength: 0)
            glassButton("square.and.arrow.up", "Share") {}
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, 56)
    }

    private func glassButton(_ icon: String, _ label: String,
                             action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.black.opacity(0.3)))
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    // MARK: Identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(game.title)
                .font(VoiidFont.rounded(26, .bold))
                .foregroundColor(VoiidColor.textPrimary)

            // THE HOOK, NOT THE SEAT COUNT. This line used to read "2 players" — the exact
            // string the facts card's `Players` row carries about 200pt below it. The same
            // fact twice, and the second one is the better of the two because it is LABELLED:
            // "Players — 2 players" cannot be misread, whereas a bare "2 players" under a
            // title has to be inferred. So the facts row keeps the seat count and the subtitle
            // gives up its copy of it.
            //
            // What takes the slot is the one thing this screen was missing under the title:
            // the game's own hook, from the same `GameRules` the card below draws. It is the
            // sibling entry sheet's subtitle too, so a player who arrives by either route
            // reads the same sentence under the same name (§4 Familiarity).
            //
            // NIL RENDERS NOTHING. A slug with no tagline written gets no line at all rather
            // than a fabricated one — the same rule the rules card follows.
            if let tagline = GameRules.tagline(for: game.slug) {
                Text(tagline)
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // NO BLURB. The reference had a paragraph of copy about 3v3 battle royales; the
            // catalog carries no description column, so there is nothing to put here and an
            // invented one would be marketing nobody wrote. `GameRules` is where a game
            // explains itself — and as of now it does so ON THIS SCREEN, in the card below the
            // facts, rather than only from inside the match.

            HStack(spacing: 7) {
                // Facts off the row, not genre labels — and only the ones the facts card does
                // NOT already carry. The category chip was dropped: "Board" as a chip here and
                // "Category — Board" in the card below is one fact rendered twice, and the
                // labelled row wins for the same reason the seat count did. The shape chips
                // survive because nothing else states them: how the seats are arranged
                // (head-to-head vs multiplayer) is derived from min/max, not printed anywhere.
                tag(game.maxPlayers > 2 ? "Multiplayer" : "Head-to-head")
                if game.minPlayers <= 1 { tag("Solo") }
            }
            .padding(.top, VoiidSpacing.sm)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, -18)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(VoiidFont.rounded(11.5, .medium))
            .foregroundColor(VoiidColor.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(VoiidColor.surfaceCard))
            .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
    }

    // MARK: Facts
    //
    // WHAT REPLACED "Choose Mode" AND THE SETTINGS CARD. See the file note: none of mode,
    // party size, difficulty or crossplay exists in Voiid. These two rows are the same shape
    // as the reference's settings card and carry the facts the catalog row actually holds —
    // read-only, because they are properties of the GAME, not choices about this match.

    private var facts: some View {
        VStack(spacing: 0) {
            factRow("Players", value: seatLine)
            Divider().overlay(VoiidColor.divider).padding(.leading, VoiidSpacing.md)
            factRow("Category", value: game.category.rawValue)
        }
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1)
        )
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.lg)
    }

    /// NO CHEVRON, unlike the reference's `settingRow`. That glyph promised a picker, and
    /// these values are not pickable — a control that looks tappable and is not is worse than
    /// a plain row.
    private func factRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(VoiidFont.rounded(15))
                .foregroundColor(VoiidColor.textPrimary)

            Spacer(minLength: 0)

            Text(value)
                .font(VoiidFont.rounded(14.5, .medium))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .frame(height: 50)
    }

    // MARK: Rules
    //
    // WHAT FILLED THE GAP. Between the facts card and the buttons there was nothing — on a
    // two-row game like Rock Paper Scissors the facts ended around 40% down the screen and the
    // player stared at half a page of ground before the CTAs. The gap was not a spacing bug; it
    // was a missing answer to the only question this screen exists to answer. A player deciding
    // whether to tap Play needs to know what they are agreeing to play, and Hand Cricket in
    // particular is unplayable unguessed (see GameRules' header: "matching numbers is out" is a
    // house rule nobody arrives knowing).
    //
    // ── SHOWN IN FULL, WITH NO DISCLOSURE — AND THAT WAS VERIFIED, NOT ASSUMED ──────
    // The sibling sheet (`GameEntryFlow`) has to fold most rule sets behind a "5 more rules"
    // row, because its play options sit IN the scrolling column: rules long enough to push them
    // down push them off screen, and the rules must give way before a control does.
    //
    // THIS SCREEN HAS NO SUCH CONSTRAINT, and the reason is structural rather than a matter of
    // how much text happens to fit. Look at `body`: the ScrollView and the `footer` are SIBLINGS
    // in a ZStack, and the footer is pinned with `.frame(maxHeight: .infinity, alignment:
    // .bottom)`. The buttons are not in the scrolling column at all, so no amount of content can
    // move them — they are painted over it at a fixed place on the glass. The
    // `.contentMargins(.bottom, 132, for: .scrollContent)` on the ScrollView reserves exactly
    // the footer's height at the end of the scroll, so the last rule line can still be scrolled
    // clear of the buttons rather than trapped beneath them. Longest set in the catalog is
    // Snake's five lines; they simply extend the scroll.
    //
    // Hence `previewCount: nil` — the full set, and the disclosure row is never drawn. Passing a
    // budget here would cost a tap to reveal rules that had nowhere they needed to fit.
    private var rules: some View {
        GameRulesCard(slug: game.slug, previewCount: nil)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.top, VoiidSpacing.lg)
    }

    // MARK: Per-game settings
    //
    // BELOW THE RULES, AND ONLY FOR GAMES THAT HAVE ANY. The screen's order is: what this
    // game is → how it is played → how YOU play it. A control that changes your own
    // experience of the game only makes sense once the game has been described, so it sits
    // after the rules card rather than competing with it.
    //
    // Snake's steering scheme moved here from the Games tab's header sheet, where it sat
    // under sound and haptics — two settings that apply to every game — with only a "Snake"
    // section header to distinguish it. Scope now matches location.
    //
    // `GameSettingsCard` renders `EmptyView` for every other slug, which contributes no
    // height, so the `if` here is about the PADDING rather than the card: an unconditional
    // `.padding(.top, .lg)` on an empty view would leave a 24pt hole above the footer on
    // every game that has no settings. `hasSettings` exists for exactly this.
    @ViewBuilder
    private var perGameSettings: some View {
        if GameSettingsCard.hasSettings(game.slug) {
            GameSettingsCard(slug: game.slug)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.lg)
        }
    }

    /// "2 players" / "2–4 players" / "1–6 players". Straight off the catalog row.
    private var seatLine: String {
        if game.minPlayers >= game.maxPlayers { return "\(game.maxPlayers) players" }
        return "\(game.minPlayers)–\(game.maxPlayers) players"
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Button {
                Haptics.tap()
                onCreateLobby()
            } label: {
                // "Play" — the reference said "Create Lobby", which in Voiid would name a
                // room you cannot sit in alone. This opens the real setup sheet, where an
                // opponent (friend or bot) is chosen; the match is minted after that.
                Text("Play")
                    .font(VoiidFont.rounded(16.5, .semibold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                            .fill(VoiidColor.accent)
                    )
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                Haptics.tap()
                onInviteFriends()
            } label: {
                Text("Invite a Friend")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                            .fill(VoiidColor.surfaceCard)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                            .stroke(VoiidColor.divider, lineWidth: 1)
                    )
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.md)
        .padding(.bottom, VoiidSpacing.lg)
        .background(
            LinearGradient(colors: [VoiidColor.background.opacity(0),
                                    VoiidColor.background.opacity(0.9),
                                    VoiidColor.background],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }
}
