//
//  ReferenceProfilePhoto.swift
//  Voiid
//
//  A local stand-in for the reference app's `ProfilePhoto`.
//
//  ── WHY THIS FILE EXISTS ────────────────────────────────────────────────────────
//  The reference's `ProfilePhoto` resolves a person's NAME to a bundled photo asset
//  ("Profile01"…"Profile15") and falls back to `ChatAvatar` — a gradient circle with initials —
//  when the name has no picture. Voiid ships none of those Profile* assets, so in this app the
//  resolver would return nil for every name and EVERY call would take the fallback path anyway.
//
//  So this is exactly that fallback path, drawn with Voiid's own `AvatarPalette` (the same
//  deterministic name→colour hash and initials the community avatars use). Same signature, same
//  circular shape, same size behaviour as the reference — so `FriendsMapScreen` calls it
//  unchanged and the layout is identical. `allowFallbackPhoto` is accepted and ignored: it only
//  selected between two photo pools, and there are no photos here.
//
//  When Voiid gains real avatar images for map contacts, this is the one file that changes.
//

import SwiftUI

struct ProfilePhoto: View {
    let name: String
    var size: CGFloat = 64
    /// Accepted for signature-compatibility with the reference. No photo pool exists in Voiid,
    /// so both values render the same initials circle.
    var allowFallbackPhoto: Bool = false

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        AvatarPalette.color(for: name),
                        AvatarPalette.color(for: name).opacity(0.72),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Text(AvatarPalette.initials(for: name))
                    // Scales with the circle so it reads at 28pt in a row and 64pt in a card.
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
            .accessibilityHidden(true)
    }
}
