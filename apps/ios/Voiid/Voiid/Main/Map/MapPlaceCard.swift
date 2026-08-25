//
//  MapPlaceCard.swift
//  Voiid
//
//  Owns: the bottom card for a resolved place — name, address, close, and the two system
//  handoffs — plus the shared skin of its action buttons.
//
//  Deliberately NOT here: where the card sits. The shell places it (and decides that a
//  searched place outranks a contact card), because the tab-bar clearance rule lives with the
//  screen that measures it. Closing tears down the query and the completer, which the shell
//  owns, so the close button reports out rather than resetting anything itself.
//

import SwiftUI

struct MapPlaceCard: View {
    let place: MapSearchModel.SelectedPlace
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(VoiidFont.rounded(16, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .lineLimit(2)
                    if let address = place.address {
                        Text(address)
                            .font(VoiidFont.rounded(12))
                            .foregroundColor(VoiidColor.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    Haptics.tap()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .padding(8).background(VoiidColor.fieldFill).clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            HStack(spacing: VoiidSpacing.sm) {
                // Handoff only — no in-app routing (docs/LOCATION.md §10.10).
                placeAction("Directions", "arrow.triangle.turn.up.right.circle.fill", filled: true) {
                    place.openInMaps(directions: true)
                }
                placeAction("Open in Maps", "map.fill", filled: false) {
                    place.openInMaps(directions: false)
                }
            }
        }
        .padding(14)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private func placeAction(_ title: String, _ icon: String, filled: Bool,
                             _ tap: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); tap() }) {
            Label(title, systemImage: icon)
                .font(VoiidFont.rounded(14, .semibold))
                .foregroundColor(filled ? .white : VoiidColor.textPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(filled ? VoiidColor.primary : VoiidColor.fieldFill)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
