//
//  MapContactCard.swift
//  Voiid
//
//  Owns: the card shown when you tap a friend's face on the Map — the identity row, the Move
//  entry point, the action row, and the shared skin of its action buttons.
//
//  Deliberately minimal: who, how fresh their position is, and a way out. No street address
//  (we never reverse-geocode — docs/LOCATION.md §10) and no coordinate readout.
//
//  Deliberately NOT here: the conversation-exists rule. Whether a Message button may be drawn
//  is a LOOKUP the shell performs against ChatStore; this view is handed the conversation or
//  nil and draws accordingly. It never mints one. Likewise the distance line arrives as
//  already-computed text, because "we hold no fix of our own" is a Ghost Mode fact the shell
//  knows and a card should not have to ask about.
//

import SwiftUI

struct MapContactCard: View {
    let presence: MapPresence
    let displayName: String
    let photoURL: String?
    /// Their journey, when they are actually travelling — nil otherwise. See the Move note below.
    let move: MapMoveInbound?
    /// Already-computed, and nil when the distance cannot be answered honestly.
    let distanceText: String?
    /// The EXISTING 1:1 with this person, or nil. Never created here — see the action-row note.
    let conversation: VConversation?
    let onOpenMove: () -> Void
    let onClose: () -> Void

    var body: some View {
        let stale = MapPresenceState.forFix(at: presence.fixedAt) == .stale
        return VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            identity(stale: stale)
                .padding(.top, 6)   // clears the grab handle above it
            // THE MOVE ENTRY POINT. Only present when this contact is ACTUALLY travelling —
            // i.e. their latest decrypted fix carried a destination. There is no "ask them
            // where they're going" button, because a Move is something a person offers, never
            // something a viewer can request.
            if let move {
                Button {
                    Haptics.tap()
                    onOpenMove()
                } label: {
                    HStack(spacing: VoiidSpacing.sm) {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(move.name.map { "On the way to \($0)" } ?? "On the way")
                                .font(VoiidFont.rounded(13.5, .semibold))
                                .lineLimit(1)
                            Text(move.minutesRemaining().map { $0 == 0 ? "Arriving now" : "About \($0) min away" }
                                 ?? "Working out their ETA")
                                .font(VoiidFont.rounded(11))
                                .opacity(0.85)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .opacity(0.8)
                    }
                    .foregroundColor(VoiidColor.textOnAccent)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                        .fill(VoiidColor.accent))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See \(displayName)'s route and ETA")
            }

            // THE ACTION ROW. The reference card carries Message / Call / Move; only the ones
            // Voiid can honestly perform are drawn.
            //
            //  - Message appears ONLY when a direct conversation with this person already
            //    exists. A Map card is not the place to mint a first contact with someone —
            //    that is a decision with its own screen, and a button that silently created a
            //    chat thread from a map tap would be a surprise.
            //  - Move is not repeated here: it already has its own full-width row above, and
            //    only when the contact is actually travelling. There is no "ask them where
            //    they're going" — a Move is offered, never requested.
            //  - Call is deliberately absent: placing a call is not a map action, and the
            //    call stack wants a conversation context this card does not carry.
            //
            // With Call and Move both absent, the row frequently holds Message alone — so it
            // is drawn full-width rather than as a lonely third of a row that never fills.
            if let conv = conversation {
                HStack(spacing: 8) {
                    NavigationLink {
                        ChatDetailView(conversation: conv)
                    } label: {
                        MapContactCard.actionLabel("bubble.left.fill", "Message", filled: false)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                }
            }
        }
        .padding(VoiidSpacing.md)
        // Extra bottom padding: the card's own corners are square where it meets the screen
        // edge, so its content needs the breathing room the missing radius used to imply.
        .padding(.bottom, VoiidSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0, topTrailingRadius: 22,
                                          style: .continuous))
        .overlay(alignment: .top) {
            // Grab handle — the card reads as a sheet pulled up from the edge, so it wears the
            // affordance a sheet wears. Decorative only; the close button remains the control.
            Capsule()
                .fill(VoiidColor.textSecondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 7)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: -2)
    }

    /// The card's action-button skin. Filled is the accent primary; unfilled is a stroked card
    /// surface. Shared so any future action lands at the same 42pt height and radius.
    static func actionLabel(_ icon: String, _ title: String, filled: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(VoiidFont.rounded(14, .semibold))
        }
        .foregroundColor(filled ? VoiidColor.textOnAccent : VoiidColor.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .fill(filled ? VoiidColor.accent : VoiidColor.surfaceCard))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(filled ? .clear : VoiidColor.divider, lineWidth: 1))
    }

    /// The card's original who/how-fresh row, unchanged — lifted into its own builder so the
    /// Move row could be added below it without touching any of it.
    private func identity(stale: Bool) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            MapAvatarPin(userId: presence.senderUserId,
                         name: displayName,
                         photoURL: photoURL,
                         state: stale ? .stale : .live,
                         size: 48)
                // A live dot ONLY when the fix is actually fresh. A stale contact has, by
                // definition, stopped reporting, so a green dot on them would be a lie — the
                // row already says "May have lost signal".
                .overlay(alignment: .bottomTrailing) {
                    if !stale {
                        Circle()
                            .fill(VoiidColor.success)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().stroke(VoiidColor.surfaceCard, lineWidth: 2.5))
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                // Freshness and — when we have our OWN fix — how far away they are. Both on
                // one line, dot-separated, the way the reference card reads them.
                //
                // Distance is computed ENTIRELY on-device from two coordinates we already
                // hold; nothing is sent anywhere to produce it. It is absent rather than
                // guessed when we have no fix of our own, which is the normal state in Ghost
                // Mode: the provider is stopped, so there is no "me" to measure from, and a
                // made-up number on a privacy surface is worse than a missing one.
                HStack(spacing: 5) {
                    Text(stale ? "May have lost signal" : "Updated \(MapFormatters.relativeAge(presence.fixedAt))")
                    if let d = distanceText {
                        Text("·")
                        Text(d)
                    }
                }
                .font(VoiidFont.rounded(12))
                .foregroundColor(VoiidColor.textSecondary)
                .lineLimit(1)
                // A Map pin is an area, not a doorstep. Presence accuracy is deliberately
                // coarsened to ≥100 m before sending, so this honestly reads "about 100 m".
                Text(LocationAccuracy.note(presence.accuracy))
                    .font(VoiidFont.rounded(10))
                    .foregroundColor(VoiidColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                Haptics.tap()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(8)
                    .background(VoiidColor.fieldFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }
}
