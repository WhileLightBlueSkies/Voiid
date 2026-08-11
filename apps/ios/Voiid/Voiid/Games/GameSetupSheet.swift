//
//  GameSetupSheet.swift
//  Voiid
//
//  "Who are you playing?" — the one entry point into any game (docs/GAMES.md §3).
//
//  ONE SHEET, TWO PATHS. Previously "play a friend" and "practice" were separate rows on
//  the home grid, which put an implementation detail (one is online, one is local) in front
//  of the user as if it were a choice about two different things. It isn't: it is the same
//  game, against a different opponent. So the game is picked first, then the opponent.
//
//  Difficulty only appears once Bot is chosen, and it EXPANDS in place rather than pushing
//  a new screen — the choice is small enough that a navigation step would cost more than it
//  explains. It stays locked once the match starts.
//
//  Mirrors Android `GameSetupSheet.kt`.
//

import SwiftUI

struct GameSetupSheet: View {
    let gameName: String
    /// The catalog slug, which is how the rules are looked up. Defaulted so a caller that has
    /// no slug still compiles — it simply shows no rules rather than another game's.
    var slug: String = ""
    let onPlayFriend: () -> Void
    let onPlayBot: (BotDifficulty, Double) -> Void
    /// Snake only: open the appearance picker. Nil hides the row, so no other game shows an
    /// option it does not have.
    var onCustomise: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var botExpanded = false
    @State private var level: BotDifficulty = .moderate
    @State private var skill: Double = BotDifficulty.moderate.skill

    var body: some View {
        // SCROLLABLE, because the rules can push this past a small screen. Without it the
        // bottom option is simply unreachable on an SE — a sheet whose primary action cannot be
        // tapped is worse than one with no rules in it.
        ScrollView {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            Text(gameName)
                .font(VoiidFont.rounded(22, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
            if let tagline = GameRules.tagline(for: slug) {
                Text(tagline)
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
            }

            rules

            Text("Who are you playing?")
                .font(VoiidFont.rounded(14, .semibold))
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.top, VoiidSpacing.xs)
                .padding(.bottom, VoiidSpacing.xs)

            if let onCustomise {
                option(icon: "paintpalette", title: "Your snake",
                       subtitle: "Pick a skin or a colour") {
                    dismiss()
                    onCustomise()
                }
            }

            option(icon: "person", title: "A friend",
                   subtitle: "Online — counts on the leaderboard") {
                dismiss()
                onPlayFriend()
            }

            option(icon: "cpu", title: "The bot",
                   subtitle: "Offline practice — doesn't count") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    botExpanded.toggle()
                }
            }

            if botExpanded {
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
                                    .foregroundStyle(selected ? VoiidColor.textOnPrimary : VoiidColor.textPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, VoiidSpacing.sm)
                                    .background(Capsule().fill(selected ? VoiidColor.primary : VoiidColor.fieldFill))
                                    .scaleEffect(selected ? 1.06 : 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.45), value: skill)

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
                    }

                    Button {
                        Haptics.tap()
                        dismiss()
                        onPlayBot(level, skill)
                    } label: {
                        Text("Start match")
                            .font(VoiidFont.rounded(16, .bold))
                            .foregroundStyle(VoiidColor.textOnPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, VoiidSpacing.md)
                            .background(Capsule().fill(VoiidColor.primary))
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.lg)
        .padding(.bottom, VoiidSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(VoiidColor.background.ignoresSafeArea())
        // TALL ENOUGH FOR THE RULES. These were fixed at 300/520 and the rules pushed the sheet
        // well past both: the game's own name scrolled off the top and "The bot" sat below the
        // fold, hiding the thing you tapped AND one of the two choices the sheet exists to
        // offer. The heights scale with the rules actually present, and the ScrollView above
        // means a small screen or large type can still reach the bottom option.
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Roughly how tall the sheet needs to be, in points.
    ///
    /// Estimated from the content rather than measured: a GeometryReader feeding a detent is a
    /// layout loop waiting to happen, and being 20pt out costs nothing here because the content
    /// scrolls. Each rule line is two lines of 13pt text plus spacing, in the worst case.
    private var sheetHeight: CGFloat {
        let base: CGFloat = 300
        let rules = CGFloat(GameRules.lines(for: slug).count) * 46
        let tagline: CGFloat = GameRules.tagline(for: slug) == nil ? 0 : 24
        return min(base + rules + tagline + (botExpanded ? 220 : 0), 720)
    }

    /// The rules, as a short scannable list.
    ///
    /// COLLAPSED BY DEFAULT AFTER THE FIRST LOOK would be the obvious refinement, and is
    /// deliberately not done yet: a player who needs the rules needs them on the sheet, and
    /// remembering "has this person played before" is state that does not exist here. Five short
    /// lines cost less than a wrong first match.
    @ViewBuilder
    private var rules: some View {
        let lines = GameRules.lines(for: slug)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                ForEach(lines) { line in
                    HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                        Image(systemName: line.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(VoiidColor.primary)
                            // Fixed width so the text edges line up into a column; ragged icons
                            // make a list read as clutter rather than as structure.
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
            .background(RoundedRectangle(cornerRadius: VoiidRadius.lg)
                .fill(VoiidColor.fieldFill.opacity(0.5)))
            .padding(.top, VoiidSpacing.xs)
        }
    }

    private func option(icon: String, title: String, subtitle: String,
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
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
            .padding(VoiidSpacing.md)
            .background(RoundedRectangle(cornerRadius: VoiidRadius.lg).fill(VoiidColor.surfaceCard))
        }
        .buttonStyle(.plain)
    }
}
