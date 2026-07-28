//
//  MapSearchModel.swift
//  Voiid
//
//  Place search for the Map tab. All native MapKit — `MKLocalSearchCompleter` for
//  autocomplete as you type, `MKLocalSearch` to resolve the chosen suggestion to a
//  coordinate. No API key, no billing, no backend proxy, and nothing about the query leaves
//  the device except to Apple's own search service.
//
//  DIRECTIONS ARE A HANDOFF, not in-app routing (docs/LOCATION.md §10.10): selecting a place
//  and tapping Directions opens Apple Maps. We deliberately do not draw routes in-app — that
//  would mean owning a routing engine and, on Android, a billed Directions API behind a
//  server-side proxy. A clean handoff is identical on both platforms.
//
//  PRIVACY: the completer is only fed while the user is actively typing, and is torn down
//  when the query empties — so an idle Map tab issues no search traffic at all.
//

import Foundation
import MapKit
import Combine

@MainActor
final class MapSearchModel: NSObject, ObservableObject {
    /// Autocomplete suggestions for the current query. Empty when idle.
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    /// The resolved place the user picked — drives the pin and the bottom card.
    @Published var selected: SelectedPlace?
    @Published private(set) var resolving = false

    struct SelectedPlace: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let address: String?
        let coordinate: CLLocationCoordinate2D

        static func == (l: SelectedPlace, r: SelectedPlace) -> Bool { l.id == r.id }

        /// System handoff to Apple Maps — driving directions, or just the pin.
        func openInMaps(directions: Bool) {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            item.name = name
            item.openInMaps(launchOptions: directions
                ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving] : nil)
        }
    }

    private let completer = MKLocalSearchCompleter()
    private var search: MKLocalSearch?

    override init() {
        super.init()
        completer.delegate = self
        // Addresses and POIs; no queries for things we can't drop a pin on.
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Feed the completer as the user types. An empty query tears the results down so an idle
    /// Map issues no traffic.
    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = trimmed
    }

    /// Bias results toward what the user is currently looking at, the way every native map
    /// search does — "coffee" should mean coffee HERE.
    func setRegion(_ region: MKCoordinateRegion) {
        completer.region = region
    }

    /// Resolve a suggestion to an actual coordinate and select it.
    func choose(_ completion: MKLocalSearchCompletion) {
        search?.cancel()
        resolving = true
        let request = MKLocalSearch.Request(completion: completion)
        let s = MKLocalSearch(request: request)
        search = s
        s.start { [weak self] response, _ in
            Task { @MainActor in
                guard let self else { return }
                self.resolving = false
                guard let item = response?.mapItems.first else { return }
                let placemark = item.placemark
                self.selected = SelectedPlace(
                    name: item.name ?? completion.title,
                    address: placemark.title ?? completion.subtitle,
                    coordinate: placemark.coordinate)
                self.suggestions = []
            }
        }
    }

    /// Clear everything (search dismissed).
    func reset() {
        search?.cancel()
        suggestions = []
        selected = nil
        completer.queryFragment = ""
    }
}

extension MapSearchModel: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.suggestions = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}
