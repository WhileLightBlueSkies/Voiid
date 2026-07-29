//
//  MapAvatarPin.swift
//  Voiid
//
//  A friend's FACE on a map, in place of a generic dot or the stock pin.
//
//  Used by the Map tab (ambient presence) and by the full-screen live-location detail, which
//  is why it lives in its own file rather than inside either screen: both need identical
//  semantics for "this person's signal is fresh / stale / gone", and Android's `AvatarPin.kt`
//  is a direct mirror of this so the two platforms read the same.
//
//  RING COLOUR is the state channel, matching the bubble's `ShareState`:
//    live  → brand primary, full colour
//    stale → grey ring, desaturated and dimmed ("may have lost signal")
//    ended → further faded (the marker is on its way off the map)
//
//  The photo comes from `AvatarCache` (memory → disk → presigned GET), so a face is fetched
//  once per launch and then painted instantly everywhere, including offline. A photo-less peer
//  falls back to initials — never a generic grey blob that makes two friends indistinguishable.
//

import SwiftUI

struct MapAvatarPin: View {
    var userId: String?
    var name: String?
    var photoURL: String?
    var state: ShareState = .live
    var size: CGFloat = 44

    /// Seeded synchronously from the cache so a known face paints on the first frame — map
    /// annotations re-render constantly as the camera moves, so a fetch must never be started
    /// from the view body.
    @State private var image: UIImage?

    private var stale: Bool { state == .stale }
    private var ended: Bool { state == .ended }

    private var ring: Color {
        if ended { return VoiidColor.textSecondary.opacity(0.5) }
        return stale ? VoiidColor.textSecondary : VoiidColor.primary
    }

    private var initials: String {
        let parts = (name ?? "").split(separator: " ").prefix(2)
        return parts.compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(discColor)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if !initials.isEmpty {
                Text(initials)
                    .font(VoiidFont.rounded(size * 0.34, .semibold))
                    .foregroundColor(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.44))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(ring, lineWidth: 2))
        .saturation(stale || ended ? 0.25 : 1)
        .opacity(ended ? 0.6 : (stale ? 0.8 : 1))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .onAppear { if image == nil { image = AvatarCache.cached(photoURL) } }
        .task(id: photoURL) {
            if image == nil { image = AvatarCache.cached(photoURL) }
            if image == nil, let photoURL { image = await AvatarCache.resolve(photoURL) }
        }
        .accessibilityLabel(name ?? "Contact")
    }

    /// A stable colour per user id, so a photo-less friend keeps the same disc colour on every
    /// device and across launches (a random colour would flicker as annotations re-render).
    private var discColor: Color {
        guard let userId, !userId.isEmpty else { return VoiidColor.textSecondary }
        let palette: [Color] = [
            Color(red: 0.36, green: 0.55, blue: 0.94), Color(red: 0.88, green: 0.41, blue: 0.35),
            Color(red: 0.25, green: 0.68, blue: 0.48), Color(red: 0.69, green: 0.42, blue: 0.84),
            Color(red: 0.89, green: 0.64, blue: 0.24), Color(red: 0.29, green: 0.66, blue: 0.79),
        ]
        let hash = userId.unicodeScalars.reduce(into: UInt32(5381)) { acc, s in
            acc = acc &* 33 &+ s.value
        }
        return palette[Int(hash % UInt32(palette.count))]
    }
}
