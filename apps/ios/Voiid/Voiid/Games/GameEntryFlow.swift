//
//  GameEntryFlow.swift
//  Voiid
//
//  ONE SHEET, from tapping a game to the board.
//
//  ── WHAT THIS REPLACES, AND WHY ─────────────────────────────────────────────────
//  The old path chained modal presentations: `GameSetupSheet` dismissed itself, then
//  `OpponentPickerSheet` (or `SeatPickerSheet`) rose in its place, then for cricket the
//  `OversSheet` rose over THAT, and for Snake the `DuelSheet` did the same. Four separate
//  presentations for one decision.
//
//  Sheet-over-sheet is the thing Apple's HIG names outright: each layer animates in and out on
//  its own clock, so the player watches one surface leave and a different surface arrive for a
//  choice that never left the same question. There is no back — only cancel, which unwinds the
//  whole thing — and no sense of place, because each sheet is a fresh window with no memory of
//  the one before it. Worse, the dismiss/present handoff is what forced the 350ms sleep before
//  pushing a board (see `dismissWait` below): a push landing inside a sheet transition is
//  silently DROPPED by SwiftUI, and the old flow had four such transitions to dodge.
//
//  ── THE SHAPE CHOSEN: A NavigationStack INSIDE ONE SHEET ────────────────────────
//  Two candidates. A single sheet whose CONTENT swaps with a spring transition, growing its
//  detent as the choice narrows; or a pushed stack inside one sheet. This is the stack, for
//  three reasons the skill's principles decide:
//
//  * INTERRUPTIBILITY (§3) is the single most important principle, and the system's
//    interactive pop is the only back gesture on iOS that is genuinely interruptible and
//    velocity-aware: you can grab a half-pushed step, drag it back, change your mind and let it
//    fly forward again. A hand-rolled `.transition` on swapped content is a scripted animation
//    that cannot be grabbed mid-flight — exactly what §3 says not to build.
//  * SPATIAL CONSISTENCY (§7): a step enters from the trailing edge and leaves to the trailing
//    edge, on the same path, because that is what a push IS. Enter-one-way / exit-another is
//    the disorientation the old chain shipped.
//  * FAMILIARITY (§16.4): the swipe-from-the-left-edge back gesture is a thing every iOS user
//    already knows. A custom back affordance would have to be learned; this one does not.
//
//  The detent rises as the choice narrows — see `wantedDetent` and `syncDetent`. The sheet is
//  ONE surface that changes shape and depth, not a stack of windows.
//
//  ── ONE PRESENTATION MEANS ONE DISMISS ──────────────────────────────────────────
//  Because there is now exactly one sheet, there is exactly one dismissal to wait out before a
//  board can be pushed. That wait is preserved verbatim (`dismissWait`) — it was never
//  cosmetic, and the reason is recorded on the constant.
//
//  ── THE SHEET'S JOB IS NARROW: WHO, AND WHAT THAT IMPLIES ───────────────────────
//  This sheet opens FROM `GameDetailScreen`, which already carries the artwork, the title, the
//  tagline, the fact rows and the FULL rules card. So the sheet does not re-explain the game.
//  It asks one question — who are you playing — and then whatever that choice implies (cricket's
//  overs, Snake's arena). An earlier revision led with a duplicate rules card; it put the same
//  six lines on screen twice inside one flow, the second time ABOVE the buttons the player came
//  here to press. It is gone, and it is not coming back. The one-line tagline stays, because a
//  reminder at the point of choosing is not the same thing as a second explanation.
//
//  ── THE SHEET RISES AS THE CHOICE NARROWS ───────────────────────────────────────
//  The root is a short list — two or three rows and a header. It has no business occupying the
//  whole screen, so it sits at its own MEASURED height, low on the display, with the detail
//  screen still visible behind it. The moment the player picks an opponent and lands in a roster
//  or an options step, the sheet rises to `.large`, because those steps are lists that want the
//  room. The size is the flow telling you where you are: low means "still choosing", tall means
//  "committed, now the detail".
//
//  Both detents are offered at every step, so the rise is a SELECTION change and never a change
//  of what the sheet can be dragged to. See `detent` and `body`.
//
//  ── THE HEIGHT IS MEASURED, NOT ESTIMATED ───────────────────────────────────────
//  The previous revision computed the root's height arithmetically: characters-per-line constants
//  for the rules text, a flat 76pt per option row, a 615pt screen. Its own comments conceded the
//  fragility, and it broke exactly where it could least afford to — at large Dynamic Type sizes,
//  where a 76pt row is really 140pt and the sheet opens clipping the buttons it exists to offer.
//  `rootHeight` is now read off the laid-out content by `MeasuredHeight`. See that type for why
//  the feedback loop the old comment feared cannot occur here.
//
//  ── THE LOBBY IS MADE LEGIBLE BY STATING THE SEAT COUNT ─────────────────────────
//  "Open a lobby" appears only when `maxPlayers > 2` — Ludo and Snake, and nothing else in the
//  live catalog. That is correct, and a DISABLED lobby row on the 1:1 games would be worse than
//  its absence. But an absence teaches nothing, so the intro states the fact the rule derives
//  from: "Two players" on Cricket, RPS, Sea Battle and Tic Tac Toe; "2–4 players" on Ludo. The
//  missing row becomes explained rather than mysterious, and the present one expected rather
//  than surprising — without ever drawing a control that cannot work. See `intro`.
//
//  ── EVERY CAPABILITY OF THE OLD CHAIN IS HERE ───────────────────────────────────
//  friend / bot / lobby, bot difficulty (presets + fine-tune slider), the multi-seat picker
//  with pick-order seating, cricket overs, snake duel bot-count, the Snake skin picker and the
//  Ludo walkthrough gate. Nothing was dropped; the sheets that carried them
//  (`GameSetupSheet`, `OpponentPickerSheet`, `SeatPickerSheet`, `OversSheet`, `DuelSheet`) are
//  left on disk untouched as the design record and are no longer presented.
//

import SwiftUI

// MARK: - What the flow decides

/// The finished decision, handed back to the screen that owns the match plumbing.
///
/// A VALUE, NOT A CALLBACK PER PATH. The flow's job is to answer "who, and with what settings";
/// minting the match, sending the invite and pushing the renderer stay in `GamesScreen`, which
/// is the only thing that owns those. That split is what keeps this file free of `GamesEngine`.
enum GameEntryOutcome {
    /// Offline practice against a local bot (or, for Snake and Ludo, a server bot match).
    case bot(BotDifficulty, Double)
    /// A 1:1 online match. `options` carries cricket's overs / snake's bot count; `skin` is
    /// Snake's chosen appearance and nil everywhere else.
    case friend(VConversation, options: [String: Int], skin: String?)
    /// A multi-seat match, in PICK ORDER — which is seat order, which in Ludo is your colour.
    case seats([VConversation], options: [String: Int])
    /// A multi-seat match that opens a PARTY LOBBY: ready-states, a join code, lobby chat.
    /// Same creation call as `.seats`; the difference is what happens after the row exists.
    case party([VConversation], options: [String: Int])
    /// Snake's appearance picker. Not a match — the flow closes and the picker opens.
    case customise
}

// MARK: - The flow

struct GameEntryFlow: View {
    let game: Game
    /// Direct conversations, which is where opponents come from.
    let conversations: [VConversation]
    /// True when this game can be practised offline. Nil-equivalent: false hides the row, for
    /// the reason `GameSetupSheet` recorded — the bot destination falls through to Tic Tac Toe,
    /// so an unbacked row opens a DIFFERENT GAME rather than merely failing.
    let hasLocalBot: Bool
    let onFinish: (GameEntryOutcome) -> Void

    /// HOW LONG TO WAIT FOR THE SHEET TO FINISH DISMISSING BEFORE PUSHING A BOARD.
    ///
    /// PRESERVED VERBATIM FROM THE OLD FLOW, AND IT IS NOT COSMETIC. SwiftUI silently DROPS a
    /// navigation push that lands while a sheet is still animating away. The REST round-trip
    /// that mints a match usually finishes inside that window, so without this the first tap
    /// did nothing at all — no board, no error, nothing. Half a beat clears the transition.
    ///
    /// It lives here, on the flow, because the flow is now the only sheet in the path: one
    /// presentation, one dismissal, one wait. The old chain had four transitions to dodge.
    static let dismissWait: UInt64 = 350_000_000

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pushed steps. `who` is the root and is never in the path.
    private enum Step: Hashable {
        /// Pick one opponent (2-seat games).
        case opponent
        /// Pick several (multi-seat games). `party` decides what happens after.
        case seats(party: Bool)
        /// Hand cricket's match length, for a chosen opponent.
        case overs
        /// Snake's arena crowding, for a chosen opponent.
        case duel
    }

    @State private var path: [Step] = []
    /// The opponent chosen on `.opponent`, held while a per-game setting is still being asked.
    @State private var chosen: VConversation?
    /// Bot difficulty, expanded in place on the root — a choice too small to be worth a push.
    @State private var botExpanded = false
    @State private var level: BotDifficulty = .moderate
    @State private var skill: Double = BotDifficulty.moderate.skill
    /// Whether the fine-tune slider is disclosed. FALSE, because `skill` above starts on the
    /// `.moderate` preset: the three described levels are the whole control for almost everyone,
    /// and the raw 0...1 dial is the advanced grip on the same value that §16.6 puts one level
    /// deeper. If this sheet ever restores a REMEMBERED skill instead of seeding a preset, this
    /// must become `BotDifficulty.matching(skill) == nil` — a restored off-preset value with the
    /// slider hidden would show "Custom · 70%" with no visible control that could have produced
    /// it, which is the exact unexplainable state the readout exists to prevent.
    @State private var fineTuneOpen = false

    /// The root's height as LAID OUT, not as guessed. Seeded at `Self.provisionalHeight` only
    /// for the single frame before the first measurement lands; see that constant.
    @State private var rootHeight: CGFloat = GameEntryFlow.provisionalHeight

    /// The option rows' icon disc, tied to the body text scale so the disc and the title it
    /// labels grow together (§15). Fixed at 40pt it became a dot beside 30pt text.
    @ScaledMetric(relativeTo: .body) private var discSize: CGFloat = 40

    /// Which of the two offered detents is currently selected. Starts at the root's height —
    /// the sheet opens LOW, on a short list, and rises only when the choice narrows.
    @State private var detent: PresentationDetent = .height(GameEntryFlow.provisionalHeight)

    private var isMultiSeat: Bool { game.maxPlayers > 2 }

    /// The detent the current step wants. The root sits at its measured height; every pushed
    /// step is a roster or an options list and wants the full sheet.
    ///
    /// THIS IS THE RISE. It is derived from `path`, so it responds to the actual choice rather
    /// than to a text-field edge case — picking "a friend" pushes a step, and the sheet grows
    /// into it in the same beat as the push.
    private var wantedDetent: PresentationDetent {
        path.isEmpty ? .height(clampedRootHeight) : .large
    }

    /// The measured height, clamped to what a detent may sensibly be.
    ///
    /// THE CEILING IS NOT A GUESS ABOUT THE SCREEN. A `.height` detent taller than the screen is
    /// simply pinned to the top by the system, so the clamp is not protecting against a broken
    /// layout — it is protecting against a POINTLESS DETENT. Once the root's content is tall
    /// enough to fill the display (four option rows at an accessibility text size will do it),
    /// a custom height and `.large` become the same position, and offering two detents that
    /// resolve to one place gives the drag gesture nothing to snap between. Above that point the
    /// root simply IS `.large`, which is the honest answer at those sizes.
    ///
    /// 640 is the largest root worth showing as a partial sheet: below the `.large` height of
    /// every device the app supports, so the two detents stay meaningfully apart.
    private var clampedRootHeight: CGFloat { min(rootHeight, 640) }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .opponent:            opponentStep
                    case .seats(let party):    seatStep(party: party)
                    case .overs:               oversStep
                    case .duel:                duelStep
                    }
                }
        }
        // THE SHEET RISES AS THE CHOICE NARROWS. Both detents are offered at every step, so the
        // player can always drag the sheet either way — a detent SET that changes under the
        // thumb is a surface that fights the gesture, and dragging back down to reconsider is a
        // thing people do. What changes is which detent is SELECTED.
        //
        // INTERRUPTIBLE BY CONSTRUCTION (§3). Moving the selection hands the resize to the
        // system's own sheet spring, which is the same spring the drag gesture drives: grab the
        // sheet while it is rising and it comes off the spring onto the finger at the velocity
        // it already had, with no seam and no lockout. That is the whole reason the rise is
        // expressed as a selection change rather than as a hand-rolled height animation — a
        // scripted height would be exactly the un-grabbable transition §3 says not to build.
        .presentationDetents([.height(clampedRootHeight), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // Depth, not just a rectangle (§12). The rounded corner is what makes the sheet read as
        // a card lifted off the page rather than a panel welded to the bottom edge.
        .presentationCornerRadius(28)
        .presentationBackground(VoiidColor.background)
        // ONE PLACE DECIDES THE DETENT, fed by every input that can change it: the navigation
        // path (the rise), and the measured height (the root growing as the bot disclosure
        // opens, or as Dynamic Type changes under a running app).
        //
        // Height matters even while a step is pushed: `.height(x)` is a VALUE, so if the offered
        // detent set changes while the selection still holds the OLD height, the selection is
        // pointing at a detent that is no longer offered and the sheet snaps to `.large`
        // unbidden. Re-pointing it every time keeps the two in step.
        .onChange(of: path) { _, _ in syncDetent() }
        .onChange(of: rootHeight) { _, _ in syncDetent() }
    }

    /// Move the selection to whatever the current step wants, under a spring.
    ///
    /// CRITICALLY DAMPED (§4): `response 0.4, dampingFraction 1.0` — Apple's own move/reposition
    /// values. Nothing here was thrown. The sheet rises because a BUTTON was tapped, and a
    /// discrete tap carries no momentum for an overshoot to express; a sheet that bounced past
    /// its height and settled back would be inventing physics the gesture never supplied. The
    /// one interaction in this file that DOES bounce is the difficulty preset (§4, and see
    /// `difficulty`), because a preset snapping into place is a commit with a snap to it.
    ///
    /// RESPECTS THE DRAG. If the player has dragged the sheet to `.large` on the root and the
    /// root's height then changes underneath them, this would yank the sheet back down to a
    /// height they deliberately left. So a root at `.large` is left alone — the only thing that
    /// may move a root off `.large` is the player's own thumb.
    private func syncDetent() {
        let target = wantedDetent
        if path.isEmpty, detent == .large, target != .large { return }
        guard detent != target else { return }
        // Reduced motion gets the same size change with no spring — the SIZE is information
        // about where you are in the flow, not decoration, so it must still happen (§14).
        if reduceMotion {
            detent = target
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 1.0)) { detent = target }
        }
    }

    // MARK: Step 1 — the game, then who you are playing

    /// The root: WHICH GAME this is, briefly, and then the ways into it.
    ///
    /// TWO BLOCKS, AND THE SECOND IS THE POINT. The intro is a confirmation, not an
    /// explanation — art, name, one-line tagline, and the facts that decide how the game is
    /// arranged. The player has just come from `GameDetailScreen` and already read the rules
    /// there; repeating them here would push the actual question below the fold on the surface
    /// whose entire job is to ask it. Everything below the intro is that question.
    ///
    /// ORDER IS THE ARGUMENT (§16.6, simplicity). Within the options: the common path first —
    /// a friend — then the bot, then the party lobby, which only a multi-seat game can offer.
    /// Snake's appearance row sits above them all because it is not an opponent at all and
    /// being mixed in with them is what made it read as one.
    ///
    /// IT STILL SCROLLS, even though it is sized to fit. The measured detent means the content
    /// fits its own sheet at every text size — but the player can drag the sheet DOWN off that
    /// height, and content that cannot scroll in a shortened sheet is content that cannot be
    /// reached. `.basedOnSize` keeps it from bouncing when it already fits.
    private var root: some View {
        ScrollView {
            // SPACING RHYTHM. Rows sit `sm` (8) apart from each other, and the two BLOCKS —
            // the intro, and the list of ways in — are separated by `lg` (24) applied at the
            // seam rather than by a uniform stack spacing. A single spacing value for both
            // would either crowd the seam or scatter the rows; the gap between groups has to
            // be visibly larger than the gap within one for the grouping to read (§16.6).
            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                intro
                    .padding(.bottom, VoiidSpacing.lg)

                // NO RULES CARD HERE, deliberately.
                //
                // This sheet is opened FROM GameDetailScreen, which already shows the full
                // rules in a card of its own — so drawing them again put the same six lines
                // on screen twice within one flow, the second time above the buttons the
                // player came here to press. `intro` still carries the tagline, which is the
                // one-line reminder that belongs at the point of choosing.

                Text("Who are you playing?")
                    // A SECTION HEADER, shaped like one. Uppercase at 12pt with open tracking
                    // reads as a label for the group beneath it rather than as a sentence
                    // competing with the 22pt title above (§15: hierarchy is weight + size +
                    // tracking as a set, not size alone). Small type takes POSITIVE tracking;
                    // the title's is negative, and that difference is what separates them.
                    .font(VoiidFont.rounded(12, .bold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .padding(.bottom, VoiidSpacing.xs)

                if game.slug == "snake" {
                    option(icon: "paintpalette", title: "Your snake",
                           subtitle: "Pick a skin or a colour") {
                        finish(.customise)
                    }
                }

                option(icon: "person", title: "A friend",
                       subtitle: "Online — counts on the leaderboard") {
                    Haptics.tap()
                    path.append(isMultiSeat ? .seats(party: false) : .opponent)
                }

                if hasLocalBot {
                    option(icon: "cpu", title: "The bot",
                           subtitle: "Offline practice — doesn't count",
                           expanded: botExpanded) {
                        Haptics.tap()
                        // Expands IN PLACE rather than pushing: the choice is two taps wide,
                        // and a navigation step would cost more than it explains. Critically
                        // damped, like every other non-thrown motion in this file — the row was
                        // tapped, not flicked, so there is no momentum for a bounce to express.
                        //
                        // REDUCED MOTION DROPS THE SPRING, not the state change (§14): the
                        // panel scales and displaces every row under it, which is exactly the
                        // vestibular motion the setting is asking us not to make. Without an
                        // animation the disclosure simply appears, which is the gentler
                        // equivalent, not a lesser one.
                        withAnimation(reduceMotion ? nil
                                                   : .spring(response: 0.35,
                                                             dampingFraction: 1.0)) {
                            botExpanded.toggle()
                        }
                    }

                    // NESTED UNDER THE ROW IT BELONGS TO. The disclosure is indented to the
                    // row's text column, so it reads as that row's contents rather than as a
                    // fourth sibling option — proximity and alignment are what carry the
                    // relationship, and a control that looks like a peer of the thing that
                    // opened it is the mapping error §16.6 names.
                    if botExpanded { difficulty }
                }

                // THE PARTY LOBBY — first-class, alongside the other two. Multi-seat only,
                // because a lobby with a ready-state and a join code for a strictly 1:1 game is
                // a room for two people who are already talking.
                if isMultiSeat {
                    option(icon: "person.3", title: "Open a lobby",
                           subtitle: "Invite by code, chat, ready up together") {
                        Haptics.tap()
                        path.append(.seats(party: true))
                    }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            // The drag indicator lives in the top ~20pt of the sheet. `lg` clears it without
            // leaving the artwork stranded in whitespace.
            .padding(.top, VoiidSpacing.lg)
            .padding(.bottom, VoiidSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .top)
            // THE MEASUREMENT THE DETENT IS BUILT ON. Reported from the laid-out content, so
            // it is correct at every Dynamic Type size by construction rather than by a
            // constant that happens to hold at the default size.
            .modifier(MeasuredHeight { rootHeight = $0 })
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .scrollBounceBehavior(.basedOnSize)
        .toolbar(.hidden, for: .navigationBar)
    }

    /// The game itself: art, name, hook, and the two facts that decide how it is arranged.
    ///
    /// THE ART IS THE SAME `GameArtwork` THE CARDS DRAW, at tile size. Spatial consistency
    /// (§7): the thing that was tapped is the thing that opens, and it looks the same on both
    /// sides of the tap. A different illustration here — or none — would make the sheet read as
    /// a form about a game rather than as the game arriving.
    private var intro: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(alignment: .center, spacing: VoiidSpacing.md) {
                GameArtwork(game: game, glyphSize: 24)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(game.title)
                        .font(VoiidFont.rounded(22, .bold))
                        // Tracking tightens as type grows (§15) — at 22pt the default spacing
                        // reads loose against the 14pt line under it.
                        .tracking(-0.4)
                        .foregroundStyle(VoiidColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let tagline = GameRules.tagline(for: game.slug) {
                        Text(tagline)
                            .font(VoiidFont.rounded(13, .regular))
                            .foregroundStyle(VoiidColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            // THE SEAT COUNT, STATED. This is the answer to the lobby's invisibility, and it is
            // deliberately a FACT rather than a disabled control.
            //
            // "Open a lobby" appears only when `maxPlayers > 2` — in the live catalog that is
            // Ludo (4) and Snake (6) and nothing else. Cricket, RPS, Sea Battle and Tic Tac Toe
            // are strictly 1:1, so the row is correctly absent: a lobby with ready-states and a
            // join code for two people who are already talking is a room with nothing in it.
            //
            // But an absence explains nothing. A player who taps Cricket has no way to learn
            // lobbies exist, and a player who taps Ludo has no way to know WHY this one has an
            // extra row. Both are answered by the same line: the game says how many seats it
            // takes. "Two players" makes the missing lobby obvious rather than mysterious;
            // "Up to 4 players" makes the present one expected rather than surprising. The
            // capability becomes legible without a dead control ever being drawn — the fix is
            // to state the fact the rule is derived from, not to draw the rule's shadow.
            HStack(spacing: VoiidSpacing.xs) {
                factChip(icon: isMultiSeat ? "person.3.fill" : "person.2.fill", text: seatFact)
                // `rawValue` is already display-cased ("Board", "Arcade") by the model.
                factChip(icon: game.category.icon, text: game.category.rawValue)
                if hasLocalBot {
                    factChip(icon: "cpu", text: "Solo practice")
                }
            }
            .padding(.top, 2)
        }
    }

    /// How many seats this game takes, phrased as the player will need to arrange it.
    private var seatFact: String {
        guard isMultiSeat else { return "Two players" }
        if game.minPlayers >= game.maxPlayers { return "\(game.maxPlayers) players" }
        return "\(game.minPlayers)–\(game.maxPlayers) players"
    }

    /// A small stated fact. Not a button, and shaped so it cannot be mistaken for one — no
    /// chevron, no card fill, no press state (§16.6: if it needs a label to explain that it is
    /// not tappable, the mapping is wrong).
    private func factChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(VoiidFont.rounded(11.5, .semibold))
                // Small type wants slightly POSITIVE tracking (§15); the negative tracking on
                // the 22pt title above would close these up until they smudge.
                .tracking(0.2)
        }
        .foregroundStyle(VoiidColor.textSecondary)
        .padding(.horizontal, VoiidSpacing.sm)
        .padding(.vertical, 5)
        .background(Capsule().fill(VoiidColor.fieldFill.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }

    /// Bot difficulty: three described levels, with the raw skill number disclosed under them.
    ///
    /// ── WHY THE CAPSULES ARE GONE ───────────────────────────────────────────────────
    /// This was three equal capsules reading "Easy / Moderate / Hard" and nothing else, so the
    /// label WAS the entire information content and the player had to already know what
    /// "Moderate" meant in order to pick it. §16 is blunt about this: if you need a label to
    /// explain a control, the mapping is weak — and here the label was not even explaining the
    /// control, it was standing in for it. A word like "Moderate" is not a description of an
    /// opponent, it is a position on a scale whose units were never shown.
    ///
    /// So each level now states what the bot ACTUALLY DOES (`BotDifficulty.blurb`, derived from
    /// the mechanic — see the note there; every local bot implements `skill` as the probability
    /// of playing its best move, so the honest description of a level is how often it blunders).
    /// A sentence does not fit in a capsule beside two others, which decides the layout: three
    /// full-width ROWS, title over description.
    ///
    /// Rows also delete a compromise the old code had to document. Three capsules across a
    /// sheet made "Moderate" wrap to two lines at large Dynamic Type, and the fix was to allow
    /// the wrap and live with it. A row is already full width, so the text has the whole sheet
    /// to grow into and there is no wrap to concede in the first place (§15: scale the layout
    /// WITH the text, do not fight it).
    ///
    /// ── THE SELECTED STATE CARRIES MORE THAN A FILL ─────────────────────────────────
    /// The old selection was one signal: the capsule turned teal. That is a colour-only
    /// distinction doing load-bearing work. Selection now reads three ways at once — a tinted
    /// ground (`accentTint`, a wash rather than a slab, because a full teal fill behind two
    /// lines of text would have to invert both and the description is deliberately secondary),
    /// a 1.5pt accent border, and a filled checkmark. Any one of them alone would carry it;
    /// together they survive both themes, and the checkmark survives a colour-blind viewer
    /// reading no teal at all.
    ///
    /// ── ONE CONTROL, NOT TWO WIDGETS ────────────────────────────────────────────────
    /// PRESERVED FROM THE PREVIOUS PASS, and it is still the central problem here: the presets
    /// and the slider drive the SAME value. Tapping "Hard" is a coarse way to say 0.92 and
    /// dragging is a fine way to say 0.91. Laid out as peers — chips, then a bare track — the
    /// eye reads two controls, and a player who drags the slider watches a chip silently
    /// deselect with no explanation offered for why touching one thing changed another.
    ///
    /// THE FIX IS RANK, NOT REMOVAL. The slider is not a peer of the presets; it is a finer
    /// grip on the same dial, and §16.6 says the common path shows first and the advanced
    /// option sits one level deeper. So it is COLLAPSED behind a disclosure that names what it
    /// is for ("Fine-tune"), and the presets are the whole control until someone asks for more.
    /// Three taps get you a described opponent; the drag is there for the player who wants 0.7
    /// specifically and now has to say so.
    ///
    /// That disclosure also gives the silent-deselect its explanation. While the slider sits
    /// between presets no row is selected, and the readout says so IN WORDS — "Custom · 70%,
    /// close to Hard" — so the deselection has a visible cause and the player is never left
    /// looking at three unlit rows wondering what they are now playing against. The relationship
    /// is stated rather than implied: one value, two grips on it.
    ///
    /// ── NO SECOND PANEL ─────────────────────────────────────────────────────────────
    /// PRESERVED. Grouping is by spacing rhythm — tight inside the group, `md` before the
    /// confirm button — not by drawing another box. A recessed panel inside the recessed
    /// `fieldFill` well would be the stacked-surface mistake (§12).
    private var difficulty: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            // The control group. `xs` internally — tight enough that the parts bind.
            VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
                ForEach(BotDifficulty.allCases) { l in
                    difficultyRow(l)
                }

                // THE ONE PLACE IN THIS FILE THAT BOUNCES, and it is the value landing that
                // earns it: the rows track `skill`, which the player DRAGS, so a row lighting
                // up is the end of a gesture that genuinely carried momentum (§4). A tap on the
                // row itself rides the same spring, which is right — both are the same value
                // arriving. 0.8 is the skill's momentum default: one small overshoot, then done.
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: skill)

                fineTune
            }

            primaryButton("Start match") { finish(.bot(level, skill)) }
        }
        .padding(VoiidSpacing.md)
        // A RECESSED WELL, not another card. The option rows above are `surfaceCard` — raised
        // surfaces you press. This is the CONTENTS of one of them, so it reads as a recess in
        // the sheet rather than as a fourth peer sitting on top of it (§12: material weight is
        // what encodes hierarchy, and a raised panel inside a raised row is the stacked-surface
        // mistake). `fieldFill` is the app's inset-content fill and is already theme-aware.
        .background(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .fill(VoiidColor.fieldFill.opacity(0.6)))
        // ── NO LEADING INDENT ANY MORE ──────────────────────────────────────────────
        // This was `.padding(.leading, 40 + VoiidSpacing.md)` — aligned to the option rows'
        // TEXT column so the panel hung off the row that opened it. That was right when the
        // panel held three one-word capsules: a narrow thing, and the indent said whose it
        // was.
        //
        // The rows now carry a NAME AND A SENTENCE. Giving away 56pt of a sheet's width made
        // every description wrap a word or two early, so the panel read as cramped precisely
        // where it is trying to explain something — and the wrapping got worse at larger text
        // sizes, which is the opposite of what should happen when someone asks for bigger type.
        //
        // Ownership is already carried by the recess, the disclosure animation unfolding from
        // the row's underside, and the panel sitting directly beneath it. The indent was a
        // fourth statement of the same fact, paid for in the one resource the content needed.
        // §16.6: every element earns its place, and this one stopped earning it when the
        // content changed.
        // Enters and leaves along the SAME path (§7): down out of the row that disclosed it,
        // back up into the same row. Anchored at the top so it unfolds from the row's underside
        // rather than growing from its own middle — the origin is the trigger (§7). Scale is
        // included so it materialises rather than merely sliding.
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    /// One difficulty level as a full-width row: name, what it does, and whether it is chosen.
    private func difficultyRow(_ l: BotDifficulty) -> some View {
        let selected = BotDifficulty.matching(skill) == l
        return Button {
            Haptics.selection()
            level = l
            skill = l.skill
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: VoiidSpacing.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.label)
                        // 15pt, PRESERVED from the capsule pass and for the same reason: the
                        // level choice is the primary decision in this panel and must not be
                        // set smaller than the 16pt confirm button that merely acts on it,
                        // while staying well under the step's 22pt title (§15 — hierarchy is
                        // weight and size as a set, so semibold at 15 carries presence without
                        // taking the title's room).
                        .font(VoiidFont.rounded(15, .semibold))
                        // Label-size type wants a touch of positive tracking (§15).
                        .tracking(0.1)
                        .foregroundStyle(VoiidColor.textPrimary)

                    Text(l.blurb)
                        // 12.5pt regular secondary: deliberately quieter than the name, because
                        // you scan the three names first and read the line under one of them
                        // only once you are choosing between two. Same relationship the intro's
                        // title and tagline have, so the sheet reads consistently.
                        .font(VoiidFont.rounded(12.5, .regular))
                        // Small type wants slightly POSITIVE tracking (§15).
                        .tracking(0.15)
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                // WRAPS RATHER THAN TRUNCATES at large Dynamic Type, and unlike the old capsule
                // this costs nothing: a full-width row has the whole sheet to grow down into,
                // so nothing is clipped and nothing is conceded.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                // THE THIRD SIGNAL. Colour and border already say "selected"; this says it
                // again in a form that survives a viewer who sees no teal (§14). The empty
                // circle is drawn rather than omitted so the rows do not reflow horizontally
                // when selection moves between them — a text column that jumps sideways as you
                // tap down the list reads as instability.
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? VoiidColor.accent
                                              : VoiidColor.textSecondary.opacity(0.4))
                    // Symbol metrics differ enough between the two glyphs to shift the
                    // baseline; a fixed box keeps the mark still while only its fill changes.
                    .frame(width: 22, alignment: .center)
                    .accessibilityHidden(true)
            }
            // 44pt MINIMUM TOUCH TARGET, CARRIED BY THE PADDING. Measured at the default text
            // size: 15pt rounded semibold is ~18pt tall, the 12.5pt line is ~15pt, plus the 1pt
            // internal gap and 12pt top and bottom, which lands at ~58pt of drawn row on its
            // own. The `minHeight: 48` floor is therefore SLACK at the default size rather than
            // load-bearing — it exists only for a future one-line variant, and the two agree
            // instead of a frame stretching a short thing. Contrast the capsules this replaced,
            // where the padding produced ~33pt and the frame did all the work.
            .padding(.vertical, 12)
            .padding(.horizontal, VoiidSpacing.sm + 2)
            .frame(minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    // A TINTED WASH, NOT A SLAB. A full `primary` fill behind two lines would
                    // force both onto `textOnPrimary` and flatten the name/description contrast
                    // the row is built on. `accentTint` is the app's theme-aware accent wash and
                    // keeps the ordinary text colours legible on top of it (§12: never stack a
                    // light surface on a light surface — this is a tint of the well, not a new
                    // layer over it).
                    .fill(selected ? VoiidColor.accentTint : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .strokeBorder(selected ? VoiidColor.accent : Color.clear, lineWidth: 1.5)
            )
            // 1.01, down from the capsule's 1.03. A full-width row is several times the area of
            // a capsule, so the same ratio is far more absolute travel — at 1.03 the row's edges
            // visibly crossed into the well's padding. The cue only has to be felt, not measured.
            .scaleEffect(selected ? 1.01 : 1)
            .contentShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        // One VoiceOver stop per level, reading name then behaviour — the same two facts in the
        // same order a sighted player reads them.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(l.label). \(l.blurb)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The slider, one level deeper, with the readout that explains what it did to the rows.
    ///
    /// COLLAPSED BY DEFAULT because it is the advanced grip on a dial the rows already set
    /// (§16.6). It opens automatically when `skill` is off-preset — which happens when a player
    /// returns to a custom value — because hiding the control that produced the current state
    /// would leave the readout unexplainable.
    private var fineTune: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
            Button {
                Haptics.tap()
                // Critically damped (§4): this is a disclosure that was TAPPED, not thrown, so
                // there is no momentum for a bounce to express — and it displaces the confirm
                // button below it, which is not motion to be playful with.
                withAnimation(.spring(response: 0.32, dampingFraction: 1.0)) {
                    fineTuneOpen.toggle()
                }
            } label: {
                HStack(spacing: VoiidSpacing.xs) {
                    Text("Fine-tune")
                        // 13pt, PRESERVED: at 12 this was the smallest type in the panel and
                        // sat below the legibility floor the rest of the sheet holds to.
                        .font(VoiidFont.rounded(13, .regular))
                        // Small type wants slightly POSITIVE tracking (§15).
                        .tracking(0.2)
                        .foregroundStyle(VoiidColor.textSecondary)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VoiidColor.textSecondary)
                        // Rotates rather than swapping glyph: the chevron is the same object
                        // pointing somewhere new, and it tracks the same spring as the panel it
                        // describes so the two read as one movement (§7).
                        .rotationEffect(.degrees(fineTuneOpen ? 0 : -90))

                    Spacer(minLength: VoiidSpacing.xs)

                    Text(skillReadout)
                        // Semibold and PRIMARY-coloured, because this is the live value —
                        // the one number in the group that changes under the finger.
                        .font(VoiidFont.rounded(13, .semibold))
                        .foregroundStyle(VoiidColor.textPrimary)
                        // Monospaced digits so the percentage does not jitter in width as it
                        // counts — a number that shivers while you drag reads as instability.
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.trailing)
                }
                // The whole row is the target, not just the word (§10 — hit area is the row).
                // 15 + 15 + ~16pt of text clears 44pt on padding alone.
                .padding(.vertical, 15)
                .padding(.horizontal, VoiidSpacing.sm + 2)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fine-tune difficulty")
            .accessibilityValue(skillReadout)
            .accessibilityHint(fineTuneOpen ? "Collapses the slider" : "Expands the slider")

            if fineTuneOpen {
                Slider(value: $skill, in: 0...1)
                    .tint(VoiidColor.primary)
                    // ROOM TO DRAG, PRESERVED. A bare SwiftUI slider is ~28pt of intrinsic
                    // height; 48pt makes the extra ~20pt dead space AROUND the track that still
                    // belongs to the slider, so a grab that lands slightly high or low still
                    // grabs it. Fine-tuning is the whole point of this control; it has to be
                    // catchable.
                    .frame(minHeight: 48)
                    // A cramped track is imprecise in the OTHER axis too — the shorter the
                    // usable length, the more skill each pixel is worth. 2pt of inset gives the
                    // thumb somewhere to actually sit at 0% and 100%, clear of the well's
                    // rounded corner.
                    .padding(.horizontal, 2)
                    .accessibilityLabel("Bot difficulty")
                    .accessibilityValue("\(Int(skill * 100)) percent")
                    // Unfolds from the row that disclosed it and folds back into it (§7).
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// What the current `skill` is, in words as well as a number.
    ///
    /// THIS IS THE ANSWER TO THE SILENT DESELECT. Dragging off a preset used to unlight a chip
    /// and say nothing, leaving the player with three dark rows and no statement of what they
    /// were about to play. On a preset this names it ("Hard · 92%") so the row and the number
    /// are visibly the same fact; off one it says "Custom" and names the nearest level, so the
    /// value stays interpretable without pretending a row is selected when it is not.
    private var skillReadout: String {
        let pct = Int((skill * 100).rounded())
        if let exact = BotDifficulty.matching(skill) {
            return "\(exact.label) · \(pct)%"
        }
        return "Custom · \(pct)%, near \(BotDifficulty.nearest(skill).label)"
    }

    // MARK: Step 2a — one opponent

    private var opponentStep: some View {
        pickerScaffold(title: "Play against") {
            ForEach(candidates, id: \.id) { convo in
                Button {
                    Haptics.tap()
                    chosen = convo
                    // Games with a per-match setting take one more step; every other game has
                    // nothing left to ask, so it starts here.
                    switch game.slug {
                    case "cricket": path.append(.overs)
                    case "snake":   path.append(.duel)
                    default:        finish(.friend(convo, options: [:], skin: nil))
                    }
                } label: {
                    personRow(convo)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    // MARK: Step 2b — several opponents

    /// The multi-seat picker. `party` decides whether confirming opens a party lobby or the
    /// ordinary invite-and-wait — the ROSTER is chosen identically either way, which is why
    /// this is one step with a flag rather than two near-identical screens.
    private func seatStep(party: Bool) -> some View {
        SeatStep(
            game: game,
            candidates: candidates,
            party: party,
            onConfirm: { convos in
                finish(party ? .party(convos, options: [:]) : .seats(convos, options: [:]))
            })
    }

    // MARK: Step 3 — the per-game setting

    /// Hand cricket's match length. Chosen by the CREATOR and fixed for both, because it is a
    /// property of the match, not of a player — there is nothing to negotiate afterwards.
    private var oversStep: some View {
        settingScaffold(
            title: "How many overs?",
            subtitle: "6 balls each. 2 wickets. Locked once the match starts."
        ) {
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(1...5, id: \.self) { n in
                    Button {
                        Haptics.tap()
                        guard let convo = chosen else { return }
                        finish(.friend(convo, options: ["overs": n], skin: nil))
                    } label: {
                        Text("\(n)")
                            .font(VoiidFont.rounded(20, .bold))
                            .foregroundStyle(VoiidColor.textPrimary)
                            .frame(maxWidth: .infinity)
                            // A FLOOR, not a fixed height. `height: 56` clipped the digit once
                            // the text scale pushed it past 56pt; `minHeight` keeps the same
                            // generous target at the default size and lets the capsule grow
                            // with the numeral instead of cropping it (§15).
                            .frame(minHeight: 56)
                            .background(Capsule().fill(VoiidColor.fieldFill))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("\(n) \(n == 1 ? "over" : "overs")")
                }
            }
        }
    }

    /// How crowded a Snake arena is. Zero bots is a true duel.
    private var duelStep: some View {
        settingScaffold(
            title: "How busy is the arena?",
            subtitle: "Chosen by you, fixed for both. Locked once the match starts."
        ) {
            VStack(spacing: VoiidSpacing.sm) {
                ForEach(Self.duelOptions, id: \.bots) { opt in
                    Button {
                        Haptics.tap()
                        guard let convo = chosen else { return }
                        finish(.friend(
                            convo,
                            options: ["bots": opt.bots].merging(
                                SnakeChoiceStore.matchOptions) { a, _ in a },
                            skin: SnakeChoiceStore.skinId))
                    } label: {
                        HStack(spacing: VoiidSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(opt.title)
                                    .font(VoiidFont.rounded(16, .semibold))
                                    .foregroundStyle(VoiidColor.textPrimary)
                                Text(opt.subtitle)
                                    .font(VoiidFont.rounded(12, .regular))
                                    .foregroundStyle(VoiidColor.textSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(VoiidColor.textSecondary)
                        }
                        .padding(VoiidSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: VoiidRadius.lg,
                                                     style: .continuous)
                            .fill(VoiidColor.surfaceCard))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
    }

    /// Deliberately three, not a slider. The interesting choice is duel-or-not; the middle
    /// option exists so "some bots" is reachable without pretending the exact number matters.
    private static let duelOptions: [(bots: Int, title: String, subtitle: String)] = [
        (0, "Duel", "Just the two of you. Every snake on screen is theirs."),
        (3, "Duel + bots", "A few bots to farm. More room to grow before you meet."),
        (6, "Open arena", "A full lobby. Your friend is one snake among many."),
    ]

    // MARK: Scaffolds

    /// Only direct chats whose peer user id we actually know — without it there is nobody to
    /// name as the opponent.
    private var candidates: [VConversation] {
        conversations.filter { $0.type == .direct && !($0.peerUserId ?? "").isEmpty }
    }

    /// A list step: title, and either the roster or the honest empty state.
    @ViewBuilder
    private func pickerScaffold<Content: View>(
        title: String, @ViewBuilder rows: () -> Content
    ) -> some View {
        Group {
            if candidates.isEmpty {
                EmptyRoster()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { rows() }
                        .padding(.top, VoiidSpacing.sm)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A settings step: WHO it is for, the question, its consequence, and the answers.
    private func settingScaffold<Content: View>(
        title: String, subtitle: String, @ViewBuilder content: () -> Content
    ) -> some View {
        // SCROLLS. These steps are short at the default text size and do not need to, but at an
        // accessibility size the title, the subtitle and five capsule rows are comfortably
        // taller than the sheet — and a question whose answers are unreachable is worse than
        // one that scrolls. `.basedOnSize` means it does not bounce when it already fits.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // WHO IT IS FOR, STATED FIRST. This was a 12pt footnote UNDER the answers, which
                // put the one piece of context that anchors the step where it would be read
                // last, if at all. The step arrived from a name; leading with that name is what
                // stops a settings screen feeling like it belongs to nothing (§16 wayfinding —
                // "where am I" is answered before the question is asked, not after it).
                if let chosen {
                    HStack(spacing: VoiidSpacing.sm) {
                        ProfilePhoto(name: chosen.title, size: 22, allowFallbackPhoto: true)
                        Text("Against \(chosen.title)")
                            .font(VoiidFont.rounded(13, .semibold))
                            .foregroundStyle(VoiidColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.bottom, VoiidSpacing.sm)
                }

                Text(title)
                    .font(VoiidFont.rounded(22, .bold))
                    // Tracking tightens as type grows (§15); at 22pt the default spacing reads
                    // loose against the 14pt line beneath it.
                    .tracking(-0.4)
                    .foregroundStyle(VoiidColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .padding(.bottom, VoiidSpacing.lg)

                content()

                Spacer(minLength: 0)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.top, VoiidSpacing.lg)
            .padding(.bottom, VoiidSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func personRow(_ convo: VConversation) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            ProfilePhoto(name: convo.title, size: 40, allowFallbackPhoto: true)
            Text(convo.title)
                .font(VoiidFont.rounded(16, .regular))
                .foregroundStyle(VoiidColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VoiidColor.textSecondary)
        }
        .padding(.vertical, VoiidSpacing.sm)
        .padding(.horizontal, VoiidSpacing.md)
        // 44pt FLOOR. `sm` above and below a 40pt photo clears it at the default size, but the
        // row is the primary target of this whole step and the floor should be stated rather
        // than left as a happy consequence of the avatar's size.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func option(icon: String, title: String, subtitle: String,
                        expanded: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // TOP-ALIGNED, not centred. At large Dynamic Type sizes the title and subtitle wrap
            // to three or four lines while the icon disc stays one glyph tall; centring leaves
            // the disc floating in the middle of a tall block, detached from the title it
            // belongs to. Aligned to the top it stays beside the first line, which is the line
            // it is labelling.
            HStack(alignment: .top, spacing: VoiidSpacing.md) {
                ZStack {
                    Circle()
                        .fill(VoiidColor.primary.opacity(0.12))
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(VoiidColor.primary)
                }
                // SCALES WITH THE TEXT (§15). A hard 40pt disc beside 16pt text that has grown
                // to 30pt is an icon that shrinks as the user's setting grows — layout has to
                // scale WITH type, not stay pinned while type moves. `@ScaledMetric` ties the
                // disc to the text scale so the proportion holds at every size.
                .frame(width: discSize, height: discSize)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(VoiidFont.rounded(16, .semibold))
                        .foregroundStyle(VoiidColor.textPrimary)
                    Text(subtitle)
                        .font(VoiidFont.rounded(12, .regular))
                        // Slightly positive tracking at 12pt (§15) — small type needs a little
                        // air to stay legible where the 16pt line above it does not.
                        .tracking(0.1)
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                // Both lines wrap rather than truncating. A subtitle that says "Offline
                // practice — doesn't co…" has lost the half that mattered.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                // HINTS IN THE DIRECTION OF THE GESTURE (§8): a row that pushes points right, a
                // row that discloses in place points down and rotates to point up once open.
                // The glyph is telling you where the tap is going before you take it.
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .rotationEffect(.degrees(expanded ? -90 : 0))
                    // Critically damped. The chevron is turning because a row was TAPPED, and a
                    // tap carries no momentum for an overshoot to express (§4) — it also turns
                    // in lockstep with the disclosure below it, which is on the same damping,
                    // so a bouncier chevron would visibly desync from the panel it describes.
                    .animation(.spring(response: 0.35, dampingFraction: 1.0), value: expanded)
                    // Holds the first line, so it does not drift down a wrapped row.
                    .frame(height: discSize, alignment: .center)
            }
            .padding(VoiidSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .fill(VoiidColor.surfaceCard))
            // The whole card is the target, including the gap the Spacer used to leave.
            .contentShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        }
        // Feedback lives on the PRESS, not the release (§1). PressableButtonStyle is the app's
        // own press scale; `.plain` gives no feedback at all until the action fires.
        .buttonStyle(PressableButtonStyle())
        // One element to VoiceOver, and the chevron's meaning stated rather than drawn — the
        // rotation is invisible to a screen reader.
        .accessibilityElement(children: .combine)
        .accessibilityHint(expanded ? "Collapses the options" : "")
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(VoiidFont.rounded(16, .bold))
                .foregroundStyle(VoiidColor.textOnPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, VoiidSpacing.md)
                .background(Capsule().fill(VoiidColor.primary))
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: Finishing

    /// Close the sheet, then hand the decision up.
    ///
    /// DISMISS FIRST, ANSWER SECOND — and the caller waits `dismissWait` before pushing. See
    /// the constant: a push that lands inside a sheet transition is dropped on the floor.
    private func finish(_ outcome: GameEntryOutcome) {
        dismiss()
        onFinish(outcome)
    }

    /// The height the sheet holds for the ONE FRAME before the first measurement arrives.
    ///
    /// NOT AN ESTIMATE OF THE CONTENT — it is not trying to be. A detent must be a concrete
    /// number at the instant the sheet is presented, and the content has not been laid out yet
    /// at that instant, so some value has to stand in. This one is deliberately near the middle
    /// of the plausible range: too small and the sheet visibly grows on arrival, too large and
    /// it visibly shrinks. It is replaced on the first layout pass, before the presentation
    /// animation has travelled far enough for the difference to read.
    ///
    /// It is never a fallback for a FAILED measurement, because there is no such case: the
    /// content always lays out, so a real height always follows.
    static let provisionalHeight: CGFloat = 420
}

// MARK: - The empty roster

/// The honest empty state for a roster with nobody in it. Says WHY, and what to do — a blank
/// list would read as a failure to load, which is a DIFFERENT state with a different remedy.
///
/// ONE COPY, TWO CALLERS. Both the single-opponent picker and the multi-seat picker reach it
/// from the same cause (no direct chats with a known peer), and it was written out twice
/// verbatim — two copies of the same sentence that would drift the first time either was
/// touched.
private struct EmptyRoster: View {
    var body: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 32))
                .foregroundStyle(VoiidColor.textSecondary)
            Text("Nobody to play yet")
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundStyle(VoiidColor.textPrimary)
            Text("Games are played with people you already talk to. Start a chat, then come back.")
                .font(VoiidFont.rounded(13, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VoiidSpacing.lg)
        // CENTRED IN THE SHEET, not stranded at the top. The step is `.large` by then, and an
        // empty state pinned under the navigation bar leaves the rest of a tall sheet blank.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Measuring the root

/// Reports the laid-out height of the view it is attached to.
///
/// ── WHY MEASURING IS SAFE HERE, WHERE A DETENT LOOP WOULD NOT BE ────────────────────
/// The revision this replaces refused to measure, on the grounds that "a GeometryReader feeding
/// a detent is a layout loop waiting to happen". That is a real hazard, but only when the
/// measured subtree's own size depends on the value being fed — measure a height, set a height,
/// re-measure, oscillate.
///
/// It cannot arise in this direction. The root's content is a `ScrollView`'s contents: its
/// height is a function of the sheet's WIDTH and the user's text size, and of nothing else. The
/// sheet's width does not change with its detent. So the flow is strictly one-way — content
/// height decides the detent, and the detent has no path back to the content height. The value
/// converges after one pass because the second pass computes the identical number.
///
/// ── WHY IT BEATS ARITHMETIC AT EVERY DYNAMIC TYPE SIZE ──────────────────────────────
/// The old height was a sum of constants — 118 for the intro, 34 for the label, 76 per row —
/// each calibrated at the default text size. Every one of them is wrong at `.accessibility3`,
/// and wrong in the same direction, so the errors compound into a sheet that opens with its
/// last option cut off. A measured height cannot drift, because it is not a model of the layout;
/// it IS the layout. No constant to recalibrate, and no failure mode at large sizes (§15).
///
/// A GEOMETRY PROXY IN A BACKGROUND, not a wrapping `GeometryReader`. A `GeometryReader` is
/// greedy — it claims all offered space and would flatten the content it is meant to measure.
/// In `.background` it takes the size of its host and reports it without influencing it.
private struct MeasuredHeight: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    // Published through a preference rather than written during `body`:
                    // mutating state inside a layout pass is the "Modifying state during view
                    // update" runtime warning, and the undefined behaviour behind it.
                    .preference(key: HeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(HeightKey.self) { height in
            // Sub-point jitter is not a size change worth animating a sheet for. Text at some
            // Dynamic Type sizes lays out on fractional boundaries, and forwarding every
            // 0.3pt difference would spring the sheet for a change nobody can see.
            guard height > 1 else { return }
            onChange(height.rounded())
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - The multi-seat step

/// Pick several opponents, in the order that becomes seat order.
///
/// ITS OWN VIEW rather than a `@ViewBuilder` on the flow, because it needs `@State` of its own
/// (the running selection) and a step's state must reset when the step is popped. A `@State`
/// hoisted onto the parent would survive a back-swipe and re-present a half-filled roster the
/// player thought they had abandoned.
private struct SeatStep: View {
    let game: Game
    let candidates: [VConversation]
    /// True when confirming opens a PARTY lobby rather than sending direct invites.
    let party: Bool
    let onConfirm: ([VConversation]) -> Void

    @State private var picked: [String] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var maxOpponents: Int { game.maxPlayers - 1 }
    private var minOpponents: Int { max(1, game.minPlayers - 1) }

    /// PICK ORDER, not list order: seat order is the order the creator chose, and in Ludo the
    /// seat decides your colour and your entry square.
    private var chosen: [VConversation] {
        picked.compactMap { id in candidates.first { $0.id == id } }
    }

    private var canConfirm: Bool {
        picked.count >= minOpponents && picked.count <= maxOpponents
    }

    var body: some View {
        Group {
            if candidates.isEmpty {
                EmptyRoster()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(candidates, id: \.id) { row($0) }
                    }
                    .padding(.top, VoiidSpacing.sm)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle(party ? "Who's in the lobby?" : "Pick players")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func row(_ convo: VConversation) -> some View {
        let index = picked.firstIndex(of: convo.id)
        let isPicked = index != nil
        // A full roster GREYS OUT the rest rather than silently ignoring taps — a tap that does
        // nothing reads as a broken list.
        let atCapacity = !isPicked && picked.count >= maxOpponents

        return Button {
            // Springs, so a seat number arriving has weight. Under-damped because a pick is
            // a snap-into-place — the seat badge lands on the avatar, and the small overshoot
            // is what makes it read as landing rather than as fading in (§4).
            //
            // 0.8, not 0.72. Both bounce, but at 0.72 the 1.06 avatar scale overshot far enough
            // to nudge the row's text on a list where several avatars can animate at once;
            // 0.8 keeps the landing and loses the wobble.
            //
            // REDUCED MOTION (§14) drops the spring and keeps the pick: the seat number is
            // information — it is the turn order — so it must still change, just without the
            // scale springing under it.
            withAnimation(reduceMotion ? nil
                                       : .spring(response: 0.32, dampingFraction: 0.8)) {
                if let index {
                    picked.remove(at: index)
                    Haptics.selection()
                } else if picked.count < maxOpponents {
                    picked.append(convo.id)
                    Haptics.tap()
                }
            }
        } label: {
            HStack(spacing: VoiidSpacing.md) {
                ZStack {
                    Circle()
                        .fill(isPicked ? VoiidColor.primary : VoiidColor.primary.opacity(0.12))
                        .frame(width: 40, height: 40)
                    if isPicked {
                        // The SEAT NUMBER, not a tick: in a 4-player game the order is the turn
                        // order, and showing it here is what makes that legible before the match
                        // rather than after the first roll.
                        Text("\((index ?? 0) + 2)")
                            .font(VoiidFont.rounded(15, .bold))
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Text(convo.title.prefix(1).uppercased())
                            .font(VoiidFont.rounded(16, .semibold))
                            .foregroundStyle(VoiidColor.primary)
                    }
                }
                .scaleEffect(isPicked ? 1.06 : 1)

                Text(convo.title)
                    .font(VoiidFont.rounded(16, .regular))
                    .foregroundStyle(atCapacity ? VoiidColor.textSecondary
                                                : VoiidColor.textPrimary)
                Spacer(minLength: 0)
                if isPicked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(VoiidColor.primary)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, VoiidSpacing.sm)
            .padding(.horizontal, VoiidSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(atCapacity)
        .opacity(atCapacity ? 0.45 : 1)
        .accessibilityLabel(convo.title)
        .accessibilityValue(isPicked ? "Seat \((index ?? 0) + 2)" : "Not playing")
    }

    /// Translucent, with the roster scrolling UNDER it (§12) — an opaque strip would eat a
    /// fixed band of a sheet that is already short.
    private var footer: some View {
        VStack(spacing: VoiidSpacing.xs) {
            // SAYS WHAT IS NEEDED rather than only disabling the button. A dead control with no
            // explanation is the flow mistake this whole surface exists to stop shipping.
            Text(footerHint)
                .font(VoiidFont.rounded(12, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .contentTransition(.opacity)

            Button {
                Haptics.tap()
                onConfirm(chosen)
            } label: {
                Text(confirmTitle)
                    .font(VoiidFont.rounded(16, .semibold))
                    .frame(maxWidth: .infinity)
                    // THE PRIMARY COMMIT OF THIS STEP, and `sm` padding on 16pt text left it
                    // around 36pt — under the 44pt floor, on the one control the whole roster
                    // exists to reach. `md` plus a stated floor puts it comfortably over.
                    .padding(.vertical, VoiidSpacing.md)
                    .frame(minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                            .fill(canConfirm ? VoiidColor.primary
                                             : VoiidColor.textSecondary.opacity(0.18)))
                    .foregroundStyle(canConfirm ? .white : VoiidColor.textSecondary)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!canConfirm)
            .animation(.spring(response: 0.35, dampingFraction: 1.0), value: canConfirm)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
        .padding(.bottom, VoiidSpacing.xs)
        .background(.ultraThinMaterial)
        // A SCROLL EDGE, NOT A DIVIDER (§12). The material alone meets the roster at a hard
        // line. This fades the rows out just ABOVE the bar — drawn outside the material's own
        // bounds, via a negative-offset overlay aligned to the top edge, so it sits between the
        // list and the glass rather than on top of the glass. The footer then reads as floating
        // over a continuous list instead of as a panel butted against one.
        .overlay(alignment: .top) {
            LinearGradient(colors: [VoiidColor.background.opacity(0), VoiidColor.background],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: VoiidSpacing.md)
                .offset(y: -VoiidSpacing.md)
                .allowsHitTesting(false)
        }
    }

    private var confirmTitle: String {
        if party { return picked.isEmpty ? "Open lobby" : "Open lobby for \(picked.count + 1)" }
        return picked.isEmpty ? "Start" : "Start with \(picked.count + 1)"
    }

    private var footerHint: String {
        if picked.count < minOpponents {
            let need = minOpponents - picked.count
            return "Pick \(need) more player\(need == 1 ? "" : "s")"
        }
        if picked.count >= maxOpponents {
            return "That's everyone — \(picked.count + 1) players"
        }
        return "\(picked.count + 1) playing. Add up to \(maxOpponents - picked.count) more."
    }
}
