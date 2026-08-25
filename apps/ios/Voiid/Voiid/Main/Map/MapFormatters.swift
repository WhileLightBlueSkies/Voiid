//
//  MapFormatters.swift
//  Voiid
//
//  Owns: the two pure string helpers the Map's pieces share — how old a fix is, and how far
//  away a contact is. Both were private methods on MapTabView; they moved here because the
//  marker, the contact card and the away strip all need them and none of them should own it.
//
//  Deliberately NOT here: anything that reads an engine. These are functions of their inputs
//  only, which is what makes the views that call them previewable.
//

import Foundation
import CoreLocation

enum MapFormatters {
    static func relativeAge(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// How far a contact is from ME, or nil when that cannot be answered honestly.
    ///
    /// Nil in two cases, both of which must NOT be papered over:
    ///   - We hold no fix of our own (Ghost Mode stops the provider entirely), so there is no
    ///     origin to measure from.
    ///   - The result is within the noise floor of two coarsened positions. Both ends are
    ///     deliberately imprecise before they are ever sent, so "80 m away" would be a
    ///     precision the wire does not carry. Under ~200 m the honest answer is "nearby".
    static func distanceText(from me: CLLocation?, to coordinate: CLLocationCoordinate2D) -> String? {
        guard let me else { return nil }
        let them = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let metres = me.distance(from: them)
        if metres < 200 { return "Nearby" }
        if metres < 1000 {
            // Rounded to the nearest 100 m — the resolution the coarsened wire actually
            // supports, and the resolution a person reads at a glance anyway.
            return "About \(Int((metres / 100).rounded()) * 100) m away"
        }
        let km = metres / 1000
        return km < 10 ? String(format: "About %.1f km away", km)
                       : "About \(Int(km.rounded())) km away"
    }
}
