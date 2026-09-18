//
//  GameSetupSheet.swift
//  Voiid
//
//  The one step between tapping a game and playing it.
//

import SwiftUI

struct GameSetupSheet: View {

    let game: Game
    var onStart: (GameMode) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var selected: GameMode?
    /// The thumb's own position, which is continuous — `selected` is the discrete mode it
    /// resolves to. Keeping them apart is what lets the thumb sit between two stops.
    @State private var sliderValue: Double = 0
    @State private var selectedDetent: PresentationDetent = .medium

    private var modes: [GameMode] { GameMode.modes(for: game.id) }

    var body: some View {
        ZStack {
            VoiidColor.background.ignoresSafeArea()

            VStack(spacing: 0) {
                banner

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                            Text("How do you want to play?")
                                .font(VoiidFont.rounded(17, .bold))
                                .foregroundColor(VoiidColor.textPrimary)

                            difficultySlider
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        rulesSection
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.top, VoiidSpacing.md)
                    .padding(.bottom, VoiidSpacing.md)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

                footer
            }
            .frame(maxWidth: .infinity)
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .onAppear {
            if selected == nil { selected = modes.first }
            sliderValue = Double(modes.firstIndex { $0.id == selected?.id } ?? 0)
        }
    }

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [game.tintA, game.tintB.opacity(0.75)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            Image(systemName: game.symbol)
                .font(.system(size: 92, weight: .medium))
                .foregroundColor(.white.opacity(0.16))
                .offset(x: 170, y: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(game.title)
                    .font(VoiidFont.rounded(22, .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 2)

                if let tagline = GameRules.tagline(for: game.id) {
                    Text(tagline)
                        .font(VoiidFont.rounded(12, .medium))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    if let players = game.players { chip("person.2.fill", players) }
                    if let minutes = game.minutes { chip("clock", minutes) }
                }
            }
            .padding(VoiidSpacing.md)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .clipped()
        // Runs to the sheet's own edges and rounds to match its 28pt corners, so the
        // artwork meets the sheet instead of sitting in it as a square inset panel.
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 28, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 28,
                style: .continuous
            )
        )
    }

    @ViewBuilder
    private var rulesSection: some View {
        let rules = GameRules.lines(for: game.id)
        if !rules.isEmpty {
            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                Text("Rules & Objectives")
                    .font(VoiidFont.rounded(16.5, .bold))
                    .foregroundColor(VoiidColor.textPrimary)

                VStack(spacing: 12) {
                    ForEach(rules) { rule in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: rule.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(VoiidColor.accent)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(VoiidColor.accentSoft))

                            Text(rule.text)
                                .font(VoiidFont.rounded(13))
                                .foregroundColor(VoiidColor.textPrimary.opacity(0.92))
                                .lineSpacing(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(VoiidSpacing.md)
                .background(VoiidColor.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                        .stroke(VoiidColor.divider, lineWidth: 1)
                )
            }
        }
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
            Text(text)
                .font(VoiidFont.rounded(11.5, .medium))
        }
        .foregroundColor(.white.opacity(0.92))
    }

    /// Difficulty as one track rather than a stack of radio rows.
    ///
    /// The modes are ordered and mutually exclusive — easy, moderate, hard — which is a
    /// magnitude, not a set of unrelated options. A slider says that in one control and one
    /// line of text, where three cards said it in three boxes competing for the same glance.
    private var difficultySlider: some View {
        let index = modes.firstIndex { $0.id == selected?.id } ?? 0
        let mode = modes[min(index, modes.count - 1)]

        return VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            HStack(spacing: 10) {
                Image(systemName: mode.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(VoiidColor.accent)
                    .frame(width: 22)
                    .contentTransition(.symbolEffect(.replace))

                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.title)
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    Text(mode.detail)
                        .font(VoiidFont.rounded(12.5))
                        .foregroundColor(VoiidColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
            // Reserved so the card does not resize as the two lines change length.
            .frame(height: 40, alignment: .leading)
            .animation(.easeOut(duration: 0.18), value: mode.id)

            // CONTINUOUS WHILE DRAGGING, SETTLING ON RELEASE.
            //
            // `step: 1` made the thumb teleport between the three stops: it cannot rest
            // between them, so the control stopped tracking the thumb and the motion read as
            // broken rather than as snapping. Here the thumb follows the finger exactly, the
            // selection updates as it crosses each stop, and only on release does it glide to
            // the chosen one — which is what makes the travel feel smooth and still land on a
            // real value.
            Slider(
                value: $sliderValue,
                in: 0...Double(max(modes.count - 1, 1)),
                onEditingChanged: { editing in
                    guard !editing else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        sliderValue = Double(index)
                    }
                }
            )
            .tint(VoiidColor.accent)
            .accessibilityLabel("Difficulty")
            .accessibilityValue(mode.title)
            // Crossing a stop mid-drag picks it, so the description and icon above update
            // under the thumb rather than only once the finger lifts.
            .onChange(of: sliderValue) { _, new in
                let step = min(max(Int(new.rounded()), 0), modes.count - 1)
                guard step != index else { return }
                Haptics.selection()
                selected = modes[step]
            }

            HStack {
                ForEach(Array(modes.enumerated()), id: \.element.id) { offset, m in
                    Text(m.shortLabel)
                        .font(VoiidFont.rounded(11.5, offset == index ? .bold : .medium))
                        .foregroundColor(offset == index ? VoiidColor.accent
                                                         : VoiidColor.textSecondary)
                    if offset < modes.count - 1 { Spacer(minLength: 0) }
                }
            }
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }

    private var footer: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Button {
                guard let selected else { return }
                Haptics.success()
                onStart(selected)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Start game")
                        .font(VoiidFont.rounded(16.5, .semibold))
                }
                .foregroundColor(VoiidColor.textOnAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: VoiidRadius.lg,
                                             style: .continuous)
                    .fill(VoiidColor.accent))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(selected == nil)
            .opacity(selected == nil ? 0.45 : 1)

            Button("Not now") { dismiss() }
                .font(VoiidFont.rounded(14.5, .semibold))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
        .padding(.bottom, VoiidSpacing.lg)
        .background(.bar)
    }
}
