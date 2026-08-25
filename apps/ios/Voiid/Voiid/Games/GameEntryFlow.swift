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
//  The detent still grows as the choice narrows — see `detent`. The sheet is ONE surface that
//  changes shape and depth, not a stack of windows.
//
//  ── ONE PRESENTATION MEANS ONE DISMISS ──────────────────────────────────────────
//  Because there is now exactly one sheet, there is exactly one dismissal to wait out before a
//  board can be pushed. That wait is preserved verbatim (`dismissWait`) — it was never
//  cosmetic, and the reason is recorded on the constant.
//
//  ── EVERY CAPABILITY OF THE OLD CHAIN IS HERE ───────────────────────────────────
//  friend / bot / lobby, bot difficulty (presets + fine-tune slider), the multi-seat picker
//  with pick-order seating, cricket overs, snake duel bot-count, the Snake skin picker, the
//  Ludo walkthrough gate, and the rules card. Nothing was dropped; the sheets that carried them
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

    private var isMultiSeat: Bool { game.maxPlayers > 2 }

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
        // THE SHEET GROWS AS THE CHOICE NARROWS. Both detents are always offered so the sheet
        // can be dragged either way at any step — a detent set that changes under the user's
        // thumb is a surface that fights the gesture. What changes is which one is SELECTED,
        // and the change is animated by the system's own sheet spring, which is interruptible
        // by construction (§3): grab the sheet mid-resize and it follows the finger.
        .presentationDetents([.height(rootHeight), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // Depth, not just a rectangle (§12). The rounded corner is what makes the sheet read as
        // a card lifted off the page rather than a panel welded to the bottom edge.
        .presentationCornerRadius(28)
        .presentationBackground(VoiidColor.background)
        .onChange(of: path) { _, new in
            // Spring, not a linear resize (§4). Critically damped — nothing here was thrown, so
            // overshoot would be motion the gesture did not earn. Reduced motion gets the same
            // size change with no spring, because the SIZE is information, not decoration.
            let target: PresentationDetent = new.isEmpty ? .height(rootHeight) : .large
            guard detent != target else { return }
            if reduceMotion {
                detent = target
            } else {
                withAnimation(.spring(response: 0.4, dampingFraction: 1.0)) { detent = target }
            }
        }
    }

    @State private var detent: PresentationDetent = .large

    // MARK: Step 1 — who are you playing

    /// The root: what the game is, and the three ways into it.
    ///
    /// ORDER IS THE ARGUMENT (§16.6, simplicity). The common path first — a friend — then the
    /// bot, then the party lobby, which only a multi-seat game can offer. Snake's appearance
    /// row sits above them all because it is not an opponent at all and being mixed in with
    /// them is what made it read as one.
    private var root: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                Text(game.title)
                    .font(VoiidFont.rounded(22, .bold))
                    // Tracking tightens as type grows (§15) — at 22pt the default spacing reads
                    // loose against the 14pt line under it.
                    .tracking(-0.4)
                    .foregroundStyle(VoiidColor.textPrimary)

                if let tagline = GameRules.tagline(for: game.slug) {
                    Text(tagline)
                        .font(VoiidFont.rounded(14, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                }

                rules

                Text("Who are you playing?")
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .padding(.vertical, VoiidSpacing.xs)

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
                        // and a navigation step would cost more than it explains. Spring with a
                        // touch of bounce, because a disclosure that springs open reads as a
                        // thing with weight (§4).
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            botExpanded.toggle()
                        }
                    }
                }

                if botExpanded, hasLocalBot { difficulty }

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

                Spacer(minLength: 0)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.top, VoiidSpacing.lg)
            .padding(.bottom, VoiidSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .scrollBounceBehavior(.basedOnSize)
        .toolbar(.hidden, for: .navigationBar)
    }

    /// The rules, as a short scannable list — carried over from `GameSetupSheet` unchanged.
    @ViewBuilder
    private var rules: some View {
        let lines = GameRules.lines(for: game.slug)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                ForEach(lines) { line in
                    HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                        Image(systemName: line.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(VoiidColor.primary)
                            // Fixed width so the text edges form a column; ragged icons make a
                            // list read as clutter rather than as structure.
                            .frame(width: 18, alignment: .center)
                        Text(line.text)
                            .font(VoiidFont.rounded(13, .regular))
                            .foregroundStyle(VoiidColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(VoiidSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .fill(VoiidColor.fieldFill.opacity(0.5)))
            .padding(.top, VoiidSpacing.xs)
        }
    }

    /// Bot difficulty: three presets and a fine-tune slider. Both preserved from the old sheet.
    private var difficulty: some View {
        VStack(spacing: VoiidSpacing.sm) {
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(BotDifficulty.allCases) { l in
                    let selected = BotDifficulty.matching(skill) == l
                    Button {
                        Haptics.selection()
                        level = l
                        skill = l.skill
                    } label: {
                        Text(l.label)
                            .font(VoiidFont.rounded(14, .semibold))
                            .foregroundStyle(selected ? VoiidColor.textOnPrimary
                                                      : VoiidColor.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, VoiidSpacing.sm)
                            .background(Capsule().fill(selected ? VoiidColor.primary
                                                                : VoiidColor.fieldFill))
                            .scaleEffect(selected ? 1.06 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Under-damped ON PURPOSE, and the one place in this file that bounces: a preset
            // tap is a discrete commit, and the small overshoot is the chip acknowledging it
            // (§4 — bounce where the interaction had a snap to it).
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: skill)

            Slider(value: $skill, in: 0...1)
                .tint(VoiidColor.primary)
                .accessibilityLabel("Bot difficulty")
                .accessibilityValue("\(Int(skill * 100)) percent")

            HStack {
                Text("Fine-tune")
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                Spacer()
                Text("\(Int(skill * 100))%")
                    .font(VoiidFont.rounded(12, .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                    // Monospaced digits so the percentage does not jitter in width as it
                    // counts — a number that shivers while you drag reads as instability.
                    .monospacedDigit()
            }

            primaryButton("Start match") { finish(.bot(level, skill)) }
        }
        // Enters and leaves along the SAME path (§7): down from the row that disclosed it, back
        // up into the same row. Scale is included so it materialises rather than merely
        // sliding — the disclosure is a surface arriving, not a decal.
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))))
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
                            .frame(height: 56)
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
                emptyRoster
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

    /// A settings step: a question, its consequence, and the answers.
    private func settingScaffold<Content: View>(
        title: String, subtitle: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(VoiidFont.rounded(22, .bold))
                .tracking(-0.4)
                .foregroundStyle(VoiidColor.textPrimary)
            Text(subtitle)
                .font(VoiidFont.rounded(14, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.top, 4)
                .padding(.bottom, VoiidSpacing.lg)

            content()

            // Says who it is FOR, now that the opponent is already chosen — the step arrived
            // from a name, and losing that name is what makes a settings screen feel like it
            // belongs to nothing.
            if let chosen {
                Text("Against \(chosen.title)")
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .padding(.top, VoiidSpacing.md)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The honest empty state for a roster with nobody in it. Says WHY, and what to do — a
    /// blank list would read as a failure to load.
    private var emptyRoster: some View {
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
        }
        .padding(VoiidSpacing.lg)
    }

    private func personRow(_ convo: VConversation) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            ProfilePhoto(name: convo.title, size: 40, allowFallbackPhoto: true)
            Text(convo.title)
                .font(VoiidFont.rounded(16, .regular))
                .foregroundStyle(VoiidColor.textPrimary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VoiidColor.textSecondary)
        }
        .padding(.vertical, VoiidSpacing.sm)
        .padding(.horizontal, VoiidSpacing.md)
        .contentShape(Rectangle())
    }

    private func option(icon: String, title: String, subtitle: String,
                        expanded: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: VoiidSpacing.md) {
                ZStack {
                    Circle()
                        .fill(VoiidColor.primary.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(VoiidColor.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(VoiidFont.rounded(16, .semibold))
                        .foregroundStyle(VoiidColor.textPrimary)
                    Text(subtitle)
                        .font(VoiidFont.rounded(12, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                Spacer(minLength: 0)
                // HINTS IN THE DIRECTION OF THE GESTURE (§8): a row that pushes points right, a
                // row that discloses in place points down and rotates to point up once open.
                // The glyph is telling you where the tap is going before you take it.
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .rotationEffect(.degrees(expanded ? -90 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: expanded)
            }
            .padding(VoiidSpacing.md)
            .background(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .fill(VoiidColor.surfaceCard))
        }
        // Feedback lives on the PRESS, not the release (§1). PressableButtonStyle is the app's
        // own press scale; `.plain` gives no feedback at all until the action fires.
        .buttonStyle(PressableButtonStyle())
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

    /// The root step's height, estimated from its content.
    ///
    /// ESTIMATED RATHER THAN MEASURED, for the reason the old sheet recorded: a GeometryReader
    /// feeding a detent is a layout loop waiting to happen. Safe because the content scrolls
    /// AND `.large` is always available as the second detent.
    ///
    /// DELIBERATELY GENEROUS. Too tall costs a little empty space; too short hides an option
    /// this sheet exists to offer, and the failure modes are not symmetric.
    private var rootHeight: CGFloat {
        let chrome: CGFloat = 330
        let perRule: CGFloat = 62
        let lines = GameRules.lines(for: game.slug)
        let rules = CGFloat(lines.count) * perRule
        let rulesPadding: CGFloat = lines.isEmpty ? 0 : 32
        let tagline: CGFloat = GameRules.tagline(for: game.slug) == nil ? 0 : 44
        let bot: CGFloat = botExpanded ? 220 : 0
        // Each extra root row: the lobby row on a multi-seat game, the skin row on Snake.
        let extraRows = CGFloat((isMultiSeat ? 1 : 0) + (game.slug == "snake" ? 1 : 0)) * 76
        return min(chrome + rules + rulesPadding + tagline + bot + extraRows, 860)
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
                }
                .padding(VoiidSpacing.lg)
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
            // Springs, so a seat number arriving has weight. Under-damped because a pick is a
            // snap-into-place — the one kind of motion that has earned an overshoot (§4).
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
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
                    .padding(.vertical, VoiidSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(canConfirm ? VoiidColor.primary
                                             : VoiidColor.textSecondary.opacity(0.18)))
                    .foregroundStyle(canConfirm ? .white : VoiidColor.textSecondary)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!canConfirm)
            .animation(.spring(response: 0.35, dampingFraction: 1.0), value: canConfirm)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
        .background(.ultraThinMaterial)
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
