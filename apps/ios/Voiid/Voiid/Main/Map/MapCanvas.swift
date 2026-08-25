//
//  MapCanvas.swift
//  Voiid
//
//  Owns: the MapKit surface itself — the basemap style, the brand wash, the map controls,
//  the camera binding, the contact pins and the searched-place pin.
//
//  Deliberately NOT here: which contacts exist. `liveContacts` is derived from TWO engines
//  (presence + conversation live shares) and is computed by the shell, which already observes
//  both; the canvas is handed the finished array. Nor does it own the camera — it binds one.
//  Tapping a pin calls back out rather than mutating any selection of its own.
//

import SwiftUI
import MapKit

struct MapCanvas: View {
    @Binding var camera: MapCameraPosition
    let contacts: [MapPresence]
    let selectedPlace: MapSearchModel.SelectedPlace?
    /// Drives the map's brand-tint strength — a wash tuned for light muddies dark tiles.
    let colorScheme: ColorScheme
    let displayName: (String) -> String
    let photoURL: (String) -> String?
    /// A contact's Move, when they are travelling — nil for everyone else.
    let move: (String) -> MapMoveInbound?
    let onRegionChange: (MKCoordinateRegion) -> Void
    let onTapContact: (String) -> Void

    var body: some View {
        Map(position: $camera) {
            ForEach(contacts) { p in
                Annotation(displayName(p.senderUserId), coordinate: p.coordinate) {
                    contactMarker(p)
                }
            }
            // A searched place, if one is selected — a POI pin, visually distinct from the
            // friend avatars so the two never read as the same kind of thing.
            if let place = selectedPlace {
                Annotation(place.name, coordinate: place.coordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(VoiidColor.error)
                        .shadow(radius: 2)
                }
            }
            // Your OWN blue dot — always shown, even in Ghost Mode. This is a purely
            // client-side view of where YOU are; it is unrelated to what you broadcast to
            // others (that is gated by `visibility`). Ghost mode hides you from others, not
            // from yourself.
            UserAnnotation()
        }
        // Snapchat-style skin: a MUTED, de-emphasised base map so the friend avatars are
        // the visual focus, not the streets. `.muted` desaturates roads/labels/terrain
        // (the closest native MapKit lever to Snapchat's custom look — no tile dependency,
        // no API key). POIs are hidden so the map reads as clean canvas. A soft brand tint
        // overlay unifies it with the app instead of stock Apple grey-blue.
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass() }
        // Bias autocomplete to what the user is actually looking at — "coffee" should mean
        // coffee HERE, the way every native map search behaves.
        .onMapCameraChange(frequency: .onEnd) { context in
            onRegionChange(context.region)
        }
        // A soft brand wash unifies MapKit's stock palette with the app. It has to be LIGHTER
        // in dark: the same 6% teal that warms a light basemap only muddies an already-dark
        // one, turning crisp tiles into grey soup. 3% keeps the tint legible as a tint.
        .overlay(
            VoiidColor.primary.opacity(colorScheme == .dark ? 0.03 : 0.06)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        )
    }

    private func contactMarker(_ p: MapPresence) -> some View {
        let stale = MapPresenceState.forFix(at: p.fixedAt) == .stale
        return VStack(spacing: 2) {
            // The shared pin (also used by the live-location detail, and mirrored by Android's
            // AvatarPin.kt), so a face looks the same wherever it appears. It resolves the real
            // photo through AvatarCache and falls back to initials, never a generic dot.
            MapAvatarPin(userId: p.senderUserId,
                         name: displayName(p.senderUserId),
                         photoURL: photoURL(p.senderUserId),
                         state: stale ? .stale : .live,
                         size: 44)
            if stale {
                Text(MapFormatters.relativeAge(p.fixedAt))
                    .font(VoiidFont.rounded(10, .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(VoiidColor.surfaceCard))
                    .foregroundColor(VoiidColor.textSecondary)
            } else if let move = move(p.senderUserId) {
                // A MOVING contact is marked on the map itself, so the journey is discoverable
                // without tapping every face. Shows the live countdown when their device has
                // measured one, and an honest "on the way" when it has not yet.
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text(move.minutesRemaining().map { $0 == 0 ? "Arriving" : "\($0) min" }
                         ?? "On the way")
                        .font(VoiidFont.rounded(10, .semibold))
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(VoiidColor.accent))
                .foregroundColor(VoiidColor.textOnAccent)
            }
        }
        .onTapGesture { Haptics.tap(); onTapContact(p.senderUserId) }
        .accessibilityLabel("\(displayName(p.senderUserId))\(stale ? ", last seen \(MapFormatters.relativeAge(p.fixedAt))" : "")")
    }
}
