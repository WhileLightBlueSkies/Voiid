//
//  OversSheet.swift
//  Voiid
//
//  Match length for hand cricket, 1–5 overs (docs/GAMES_HAND_CRICKET.md §2).
//
//  A SEPARATE STEP RATHER THAN A ROW ON `GameSetupSheet`: that sheet asks one question — who are
//  you playing — and stacking an unrelated second question onto it would make it the place every
//  decision goes. This appears only for the one game that has a length to choose.
//
//  CHOSEN BY THE CREATOR, FIXED FOR BOTH. Match length is a property of the match, not of a player,
//  so there is nothing to negotiate: the invitee joins a 3-over game the same way they join a game
//  already in progress.
//
//  Mirrors Android `OversSheet.kt`.
//

import SwiftUI

struct OversSheet: View {
    let onPick: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("How many overs?")
                .font(VoiidFont.rounded(22, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
            Text("6 balls each. 2 wickets. Locked once the match starts.")
                .font(VoiidFont.rounded(14, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.top, 4)
                .padding(.bottom, VoiidSpacing.lg)

            HStack(spacing: VoiidSpacing.sm) {
                ForEach(1...5, id: \.self) { n in
                    Button {
                        Haptics.tap()
                        onPick(n)
                        dismiss()
                    } label: {
                        Text("\(n)")
                            .font(VoiidFont.rounded(20, .bold))
                            .foregroundStyle(VoiidColor.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Capsule().fill(VoiidColor.fieldFill))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.background)
        .presentationDetents([.height(240)])
    }
}
