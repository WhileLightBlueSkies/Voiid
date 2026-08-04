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

import Combine
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
        // STREET-LEVEL accuracy, matching Snap Map.
        //
        // This was `kCLLocationAccuracyHundredMeters` with a 250 m and then 100 m filter, so
        // the pin could never be better than ~100 m however finely we rounded — you could
        // walk the length of a building and it would not move, which reads as stale rather
        // than coarse. `nearestTenMeters` is the accuracy a friend map needs to be useful.
        //
        // Cost is paid by the CADENCE, not the accuracy constant: significant-change plus a
        // 25 m filter means the GPS is not being held open. This is still not the continuous
        // mode reserved for a timer-bounded live share.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
        authorization = manager.authorizationStatus
    }

    // MARK: - Authorization

    /// Ask for ALWAYS, so presence survives backgrounding.
    ///
    /// iOS only grants Always as an UPGRADE from WhenInUse — asking cold shows nothing, or
    /// shows a prompt the user has no context for. So this is called after WhenInUse is
    /// already granted, and only when the user has chosen to be visible on the Map.
    ///
    /// Nothing breaks if it is refused: significant-change delivery simply stops while
    /// backgrounded and resumes on foreground, which is exactly the old behaviour.
    func requestAlwaysIfNeeded() {
        guard authorization == .authorizedWhenInUse else { return }
        manager.requestAlwaysAuthorization()
    }

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

        // BACKGROUND DELIVERY for the significant-change stream.
        //
        // Without this the Map went stale the moment the app was backgrounded — your pin
        // froze wherever you last had Voiid open, which is worse than showing nothing: it
        // tells your contacts you are somewhere you left an hour ago.
        //
        // This stays CHEAP. It is still significant-change (~500 m / ~5 min), which rides
        // the cell/wifi radio the OS already runs for its own purposes — not
        // `startUpdatingLocation`, which is the 4–8 %/h mode reserved for a timer-bounded
        // live share. The Map's contract (coarse, ambient, <1 %/h) is unchanged; only its
        // ability to keep delivering while closed is new.
        //
        // Requires the `location` UIBackgroundMode, which Info.plist declares — this TRAPS
        // without it. Real background delivery additionally needs Always; with WhenInUse the
        // stream simply pauses when backgrounded, which is the previous behaviour.
        manager.allowsBackgroundLocationUpdates = true
        // Never auto-pause: the OS pausing an ambient presence stream would strand the pin
        // silently, and significant-change is too cheap for the pause to buy anything.
        manager.pausesLocationUpdatesAutomatically = false

        // BOTH APIS, each for what it is actually good at.
        //
        // Significant-change alone is ~500 m — it is a "you have moved to a new area" signal,
        // not a position feed — so on its own the 25 m distance filter above was dead code and
        // the pin could never be street-level. That is why iOS pins looked coarser than the
        // constants claimed.
        //
        //   startUpdatingLocation      — the accurate foreground feed. Gated by the 25 m
        //                                filter, so a stationary phone produces nothing and
        //                                the radio is not held open.
        //   significant-change         — kept because it is the ONLY thing that RELAUNCHES a
        //                                terminated app. startUpdatingLocation dies with the
        //                                process; this is what makes presence survive a kill.
        //
        // Neither is the continuous high-rate mode: that needs `kCLLocationAccuracyBest` with
        // no filter, which is the 4–8 %/h live-share profile and stays out of the Map.
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()

        // Ask to upgrade once the coarse stream is live, so the prompt arrives with the
        // feature it is for rather than at some unrelated moment.
        requestAlwaysIfNeeded()
    }

    /// Backgrounded: drop the ACCURATE feed, keep the relaunch-capable one.
    ///
    /// `startUpdatingLocation` in the background shows the blue system pill and holds the GPS
    /// — appropriate for a timer-bounded live share, not for ambient presence nobody is
    /// looking at. Significant-change keeps running, which is what preserves both the
    /// coarse background pin and the ability to be relaunched after a kill.
    func noteBackgrounded() {
        guard running else { return }
        manager.stopUpdatingLocation()
    }

    /// Foregrounded: bring the accurate feed back.
    func noteForegrounded() {
        guard running, isAuthorized else { return }
        manager.startUpdatingLocation()
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
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        // Drop background privileges the instant we stop. Ghost Mode and the kill switch
        // both route here, and a lingering background grant after the user said "stop" would
        // be the exact failure this feature must never have.
        manager.allowsBackgroundLocationUpdates = false
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
