//
//  MapLocationProvider.swift
//  Voiid
//
//  The Map's location source. COARSE, LAST-KNOWN, FOREGROUND-DRIVEN — a continuously
//  broadcasting map is deliberately not shipped (§5). This is the single largest battery
//  and safety difference between (A) live sharing and (B) the Map: (A) is a short, explicit,
//  timer-bounded act; (B) is an ambient standing state, so it must be cheap and imprecise.
//
//  CoreLocation appears nowhere else in the app — this is a from-scratch wrapper, not an
//  integration. It uses ONLY:
//    - `requestWhenInUseAuthorization()` — never Always. The Map never runs in the
//      background, so there is nothing to disclose while the app is closed (§8), and no
//      blue system pill is expected during Map-only use.
//    - `startMonitoringSignificantLocationChanges()` — ~500 m / ~5 min, essentially free;
//      it rides the cell/wifi radio the OS already runs. NEVER `startUpdatingLocation`.
//    - one `requestLocation()` on foreground, so the map is fresh the moment you open it.
//
//  The GHOST GATE is enforced by the caller (MapPresenceEngine): this provider is only ever
//  started while visible, and stopped the instant Ghost Mode is entered. Belt-and-braces,
//  `start()` is a no-op the caller can call idempotently.
//

import Foundation
import CoreLocation

@MainActor
final class MapLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = MapLocationProvider()

    private let manager = CLLocationManager()
    private var running = false

    /// The most recent fix the OS has handed us, coarse. Published so the map can centre on
    /// "you" without emitting anything.
    @Published private(set) var lastFix: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    /// Called on every accepted coarse fix. The engine encrypts + emits from here.
    var onFix: ((CLLocation) -> Void)?
    /// Called when authorization resolves, so the engine can proceed or fall back.
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    private override init() {
        super.init()
        manager.delegate = self
        // Map presence targets ~100–500 m. Never ask for best accuracy — that is the whole
        // point of the coarse mode. 250 m distance filter matches §5's Map profile.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 250
        authorization = manager.authorizationStatus
    }

    // MARK: - Authorization

    /// In-context, at the moment the user chooses to be visible — never at onboarding. The
    /// Map only ever needs When-In-Use.
    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    var isAuthorized: Bool {
        switch authorization {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    // MARK: - Lifecycle

    /// Begin coarse monitoring. Significant-change is the ambient stream; a one-shot
    /// `requestLocation()` gives an immediate fix so the map isn't blank on open.
    func start() {
        guard !running, isAuthorized else { return }
        running = true
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()
    }

    /// One immediate coarse fix — used on foreground to refresh presence without waiting for
    /// the next significant change.
    func refreshOnce() {
        guard isAuthorized else { return }
        manager.requestLocation()
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopMonitoringSignificantLocationChanges()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorization = manager.authorizationStatus
            self.onAuthorizationChange?(manager.authorizationStatus)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.lastFix = loc
            self.onFix?(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failed one-shot is non-fatal — significant-change keeps running and the next
        // fix arrives on its own. Degrade silently; the map shows the last known position.
        NSLog("[VOIID] map location error: \(error.localizedDescription)")
    }
}
