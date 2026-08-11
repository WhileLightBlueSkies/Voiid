//
//  DuelSheet.swift
//  Voiid
//
//  How crowded the arena is, for a Snake match against a friend
//  (docs/games/SNAKE_COMPETITIVE_PARITY.md §4 P3.7).
//
//  THE COMPETITOR'S `DuelGameMode` IS A MODE. Ours is not, and does not need to be: the engine
//  already takes a bot count and a player list, so a duel is a match with two seats and zero
//  bots. Building a mode around that would be a second code path to keep in step with the
//  first, for a difference that is one integer.
//
//  So this asks the one question a mode would have answered implicitly, and it is worth asking
//  because the two answers play completely differently. An empty arena is a duel — every body
//  on screen is theirs, every kill is against them, and there is nowhere to hide. A populated
//  one is the .io game, where the friend is one snake among several and the win can go to
//  whoever farmed bots best.
//
//  A FRIEND MATCH SILENTLY MEANT ZERO BOTS BEFORE THIS. That is the better default and it is
//  kept, but it was never a choice and never labelled — two people invited each other, got an
//  empty arena, and had no way to ask for anything else.
//
//  Mirrors Android `DuelSheet.kt`.
//

import SwiftUI

struct DuelSheet: View {
    /// Bot count for the match. 0 is a true duel.
    let onPick: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Deliberately three, not a slider. The interesting choice is duel-or-not; the middle
    /// option exists so "some bots" is reachable without pretending the exact number matters.
    private let options: [(bots: Int, title: String, subtitle: String)] = [
        (0, "Duel", "Just the two of you. Every snake on screen is theirs."),
        (3, "Duel + bots", "A few bots to farm. More room to grow before you meet."),
        (6, "Open arena", "A full lobby. Your friend is one snake among many."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("How busy is the arena?")
                .font(VoiidFont.rounded(22, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
            // Says it is fixed for both, for the same reason the overs sheet does: it is a
            // property of the match, not of a player, so there is nothing to negotiate after.
            Text("Chosen by you, fixed for both. Locked once the match starts.")
                .font(VoiidFont.rounded(14, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.top, 4)
                .padding(.bottom, VoiidSpacing.lg)

            VStack(spacing: VoiidSpacing.sm) {
                ForEach(options, id: \.bots) { opt in
                    Button {
                        Haptics.tap()
                        onPick(opt.bots)
                        dismiss()
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
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.background)
        .presentationDetents([.height(360)])
    }
}
