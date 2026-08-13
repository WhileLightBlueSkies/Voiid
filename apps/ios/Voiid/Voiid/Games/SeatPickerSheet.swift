//
//  SeatPickerSheet.swift
//  Voiid
//
//  Choose several opponents, for games with more than two seats
//  (docs/games/future/README.md §2.4, LUDO.md §14 phase 0).
//
//  WHY THIS IS A SEPARATE SHEET FROM OpponentPickerSheet. That one hands back a single
//  `VConversation` and its callers are wired for exactly one — Tic Tac Toe, RPS, cricket and a
//  Snake duel are all strictly 1:1, and widening its callback would touch four working screens
//  to serve none of them. This is additive: a game whose catalog row allows more than two seats
//  gets this sheet, every other game keeps the one it has.
//
//  THE SERVER SIDE ALREADY WORKS. `POST /games/matches` takes `opponent_ids` as an array,
//  validates it against the catalog's min/max_players, `player_ids` is a jsonb array, and
//  `handleJoin` gates the start on `joined.length >= players.length` for any seat count. The
//  gap this closes was entirely that no client could express more than one opponent.
//
//  Mirrors Android `SeatPickerSheet.kt`.
//

import SwiftUI

struct SeatPickerSheet: View {
    let conversations: [VConversation]
    /// Seats the match needs BESIDES the creator. A 4-player Ludo game passes 3.
    let maxOpponents: Int
    /// Fewest opponents that make a playable match, besides the creator.
    let minOpponents: Int
    /// The chosen conversations, in pick order — which becomes seat order.
    let onConfirm: ([VConversation]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String] = []

    /// Only direct chats whose peer user id we actually know — without it there is nobody to
    /// name as an opponent.
    ///
    /// GROUPS ARE STILL EXCLUDED HERE, and that is a deliberate half-step. LUDO.md §12.3 calls
    /// "play Ludo with this group" the single highest-value entry point in that doc, and it is:
    /// one tap from a group thread to a filled lobby. But it needs a group-membership read and a
    /// fan-out invite that this sheet has no business inventing, so seats are filled from direct
    /// chats first and the group entry point is left as the next piece of work rather than
    /// half-built here.
    private var candidates: [VConversation] {
        conversations.filter { $0.type == .direct && !($0.peerUserId ?? "").isEmpty }
    }

    private var chosen: [VConversation] {
        // Preserve PICK ORDER rather than list order: seat order is the order the creator chose,
        // and in Ludo the seat decides your colour and your entry square.
        picked.compactMap { id in candidates.first { $0.id == id } }
    }

    private var canConfirm: Bool {
        picked.count >= minOpponents && picked.count <= maxOpponents
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    Text("Start a chat with someone first — games are played with people you already talk to.")
                        .font(VoiidFont.rounded(14, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(VoiidSpacing.lg)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(candidates, id: \.id) { convo in
                                row(convo)
                            }
                        }
                        .padding(.top, VoiidSpacing.sm)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Pick players")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { footer }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(VoiidColor.primary)
                }
            }
        }
    }

    private func row(_ convo: VConversation) -> some View {
        let index = picked.firstIndex(of: convo.id)
        let isPicked = index != nil
        // A full roster greys out the rest rather than silently ignoring taps — a tap that does
        // nothing reads as a broken list.
        let atCapacity = !isPicked && picked.count >= maxOpponents

        return Button {
            if let index {
                picked.remove(at: index)
            } else if picked.count < maxOpponents {
                picked.append(convo.id)
                Haptics.tap()
            }
        } label: {
            HStack(spacing: VoiidSpacing.md) {
                ZStack {
                    Circle()
                        .fill(isPicked ? VoiidColor.primary : VoiidColor.primary.opacity(0.12))
                        .frame(width: 40, height: 40)
                    if isPicked {
                        // The SEAT NUMBER, not a tick: in a 4-player game the order is the
                        // turn order, and showing it here is what makes that legible before
                        // the match rather than after the first roll.
                        Text("\((index ?? 0) + 2)")
                            .font(VoiidFont.rounded(15, .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text(convo.title.prefix(1).uppercased())
                            .font(VoiidFont.rounded(16, .semibold))
                            .foregroundStyle(VoiidColor.primary)
                    }
                }
                Text(convo.title)
                    .font(VoiidFont.rounded(16, .regular))
                    .foregroundStyle(atCapacity ? VoiidColor.textSecondary : VoiidColor.textPrimary)
                Spacer()
                if isPicked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(VoiidColor.primary)
                }
            }
            .padding(.vertical, VoiidSpacing.sm)
            .padding(.horizontal, VoiidSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(atCapacity)
        .opacity(atCapacity ? 0.45 : 1)
        .accessibilityLabel(convo.title)
        .accessibilityValue(isPicked ? "Seat \((index ?? 0) + 2)" : "Not playing")
    }

    private var footer: some View {
        VStack(spacing: VoiidSpacing.xs) {
            // Say what is needed rather than only disabling the button. A dead button with no
            // explanation is the flow mistake CROSS_CUTTING.md §9 names across this whole surface.
            Text(footerHint)
                .font(VoiidFont.rounded(12, .regular))
                .foregroundStyle(VoiidColor.textSecondary)

            Button {
                onConfirm(chosen)
                dismiss()
            } label: {
                Text(picked.isEmpty ? "Start" : "Start with \(picked.count + 1)")
                    .font(VoiidFont.rounded(16, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, VoiidSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(canConfirm ? VoiidColor.primary : VoiidColor.textSecondary.opacity(0.18)))
                    .foregroundStyle(canConfirm ? .white : VoiidColor.textSecondary)
            }
            .disabled(!canConfirm)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
        .background(.ultraThinMaterial)
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
