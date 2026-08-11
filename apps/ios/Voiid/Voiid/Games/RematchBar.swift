//
//  RematchBar.swift
//  Voiid
//
//  What to do once an online match is over: play them again, or leave.
//
//  THE HIGHEST-VALUE MISSING BUTTON IN THE PRODUCT (docs/games/CROSS_CUTTING.md §1). Two people
//  who just finished a match are the two most likely to play another in the next thirty seconds,
//  and until now that took going back to the Games tab, picking the game, picking the friend,
//  sending a fresh invite, and waiting for them to accept it. Six taps and a round trip, by which
//  point they have put the phone down.
//
//  ONLINE ONLY. The bot screens already have "Play again", which is a local reset and needs no
//  server. This is for matches with a real opponent, where a rematch is a new row, a new invite
//  and a fresh permission check.
//
//  IT MINTS A NEW MATCH rather than reopening the finished one — the old row holds a result the
//  leaderboard already counted. See the server route for why that matters.
//
//  Mirrors Android `RematchBar.kt`.
//

import SwiftUI

struct RematchBar: View {
    /// The match that just finished. Its id is what the server clones.
    let matchId: String
    /// Opens the new match once the server has minted it.
    let onRematch: (String) -> Void
    let onExit: () -> Void

    @State private var requesting = false
    /// Set when the server refuses. Shown inline rather than as an alert: an alert for "they
    /// left" is a modal to dismiss on top of a match that is already over.
    @State private var failure: String?

    private let api = GamesAPI()

    var body: some View {
        VStack(spacing: VoiidSpacing.sm) {
            if let failure {
                Text(failure)
                    .font(VoiidFont.rounded(13, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            HStack(spacing: VoiidSpacing.sm) {
                Button {
                    Haptics.tap()
                    request()
                } label: {
                    Group {
                        if requesting {
                            ProgressView().tint(VoiidColor.textOnPrimary)
                        } else {
                            Text("Rematch")
                                .font(VoiidFont.rounded(15, .bold))
                        }
                    }
                    .foregroundStyle(VoiidColor.textOnPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, VoiidSpacing.md)
                    .background(Capsule().fill(VoiidColor.primary))
                }
                .buttonStyle(.plain)
                // Disabled WHILE IN FLIGHT, not after failing: a rematch that failed because the
                // opponent was momentarily unreachable should be retryable without leaving.
                .disabled(requesting)

                Button {
                    Haptics.tap()
                    onExit()
                } label: {
                    Text("Exit")
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundStyle(VoiidColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, VoiidSpacing.md)
                        .background(Capsule().fill(VoiidColor.fieldFill))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, VoiidSpacing.lg)
        .animation(.easeInOut(duration: 0.2), value: failure)
    }

    private func request() {
        guard !requesting else { return }
        requesting = true
        failure = nil
        Task {
            do {
                let res = try await api.rematch(matchId: matchId)
                requesting = false
                onRematch(res.match_id)
            } catch {
                requesting = false
                // DELIBERATELY VAGUE, and deliberately not the server's message. The route
                // returns 403 without naming which player failed, so that it cannot be used to
                // probe whether a user id exists or is in your contacts; echoing a raw error
                // here would undo that. "Could not start" covers blocked, deleted and offline
                // alike, which is all the player can act on anyway.
                withAnimation { failure = "Couldn't start a rematch. They may have left." }
            }
        }
    }
}
