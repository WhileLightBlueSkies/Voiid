//
//  LocationService.swift
//  Voiid
//
//  The CoreLocation seam for BOTH conversation live sharing (feature A) and — later —
//  Map presence (feature B). A thin wrapper over CLLocationManager that owns the
//  authorization ladder, the cadence profiles, and the background configuration, and
//  hands fixes back through plain closures (no coordinate is ever logged).
//
//  App Review posture (docs/LOCATION.md §5), enforced by construction here:
//   • Nothing starts on launch. `startLive` is only ever called from an explicit user
//     action with an explicit end time (LocationShareEngine).
//   • `showsBackgroundLocationIndicator = true` — we WANT the system blue pill; it is
//     free privacy UX and tells the user, unmissably, that a share is running.
//   • `allowsBackgroundLocationUpdates` requires the `location` UIBackgroundMode in
//     Info.plist; the app TRAPS without it, which is why that key is declared there.
//
//  Not @MainActor: CLLocationManagerDelegate callbacks arrive on the run loop of the
//  thread that created the manager (main, here), so the closures fire on main already.
//  Kept a plain NSObject to avoid delegate/actor-isolation friction under Swift 5 mode.
//

import Foundation
import CoreLocation

final class LocationService: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()

    /// A fresh fix arrived (live stream or one-shot). Coordinates are rounded by the
    /// CALLER before encryption — this passes the raw CLLocation through.
    var onFix: ((CLLocation) -> Void)?
    /// Authorization changed: (status, isReducedAccuracy).
    var onAuthChange: ((CLAuthorizationStatus, Bool) -> Void)?

    /// One-shot completion for a static pin (requestLocation). Cleared after firing.
    private var oneShot: ((CLLocation?) -> Void)?
    private var oneShotTimeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    // MARK: - Authorization ladder (docs/LOCATION.md §5)

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var isReducedAccuracy: Bool { manager.accuracyAuthorization == .reducedAccuracy }

    /// Step 1 — asked at the MOMENT of first share, in-context, never at onboarding.
    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }

    /// Step 2 — escalate to Always ONLY when the user picks a duration > 15 minutes, so
    /// the live share keeps updating in the background. Denial is not fatal: the share
    /// runs foreground-only.
    func requestAlways() { manager.requestAlwaysAuthorization() }

    // MARK: - Live share (foreground + background stream)

    /// Configure and start the live-share cadence: ~10–15 s, 25 m distance filter,
    /// ~10 m accuracy target. Background delivery is enabled (the blue pill shows);
    /// whether it actually continues in the background depends on Always being granted.
    func startLive() {
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
        manager.activityType = .other
        // Never let the OS auto-pause an ACTIVE, timer-bounded share — the user asked for
        // it to run until their timer ends.
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        // Requires the `location` UIBackgroundMode (declared in Info.plist) or this traps.
        // Safe to set with WhenInUse; real background delivery needs Always.
        manager.allowsBackgroundLocationUpdates = true
        isLiveStreaming = true
        manager.startUpdatingLocation()
    }

    func stopUpdating() {
        isLiveStreaming = false
        manager.stopUpdatingLocation()
        // Drop background privileges the moment we stop, so nothing lingers.
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: - Static pin (one fix, ~10 s timeout)

    /// Request a single best-available fix for a pin. Calls back with nil on timeout /
    /// failure so the caller can surface "couldn't get your location" rather than hang.
    func requestOneShot(timeout seconds: TimeInterval = 10, _ completion: @escaping (CLLocation?) -> Void) {
        oneShot = completion
        bestOneShot = nil
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // startUpdatingLocation, NOT requestLocation: `requestLocation` delivers ONE result
        // and stops, so a cached tower estimate arriving first ends the attempt with no
        // chance of a better fix. A short stream lets accuracy converge, and fireOneShot
        // stops it the moment a good fix lands or the timeout expires.
        manager.startUpdatingLocation()
        oneShotTimeout?.cancel()
        oneShotTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.fireOneShot(nil) }
        }
    }

    /// The most accurate fix seen during the current one-shot window, so a timeout can still
    /// return the best available rather than nothing.
    private var bestOneShot: CLLocation?

    /// True while a LIVE SHARE owns the stream.
    ///
    /// A one-shot now uses startUpdatingLocation to let accuracy converge, so it must not
    /// call stopUpdatingLocation if a live share is relying on that same stream — sending a
    /// pin mid-share would otherwise silently kill the share's updates.
    private var isLiveStreaming = false

    private func fireOneShot(_ location: CLLocation?) {
        oneShotTimeout?.cancel(); oneShotTimeout = nil
        if isLiveStreaming {
            // The share owns the stream, so it stays up — but it must get its own profile
            // back. `requestOneShot` raises accuracy to Best for convergence, and leaving it
            // there ran a share that only needs ten metres at full GPS power until something
            // restarted it.
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        } else {
            // Stop the convergence stream. Leaving it running would hold the GPS open for a
            // pin that has already been sent.
            manager.stopUpdatingLocation()
        }
        let cb = oneShot; oneShot = nil
        // Fall back to the best candidate seen, not nil: a 90 m pin beats "couldn't get your
        // location" when the user is indoors and GPS never sharpens.
        let result = location ?? bestOneShot
        bestOneShot = nil
        cb?(result)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        if oneShot != nil {
            // A LIVE SHARE MUST NOT STARVE WHILE A PIN IS CONVERGING.
            //
            // One manager serves both, and this branch used to swallow every fix until the
            // one-shot resolved — so sending a pin mid-share stopped the share's stream for up
            // to the full 10 s timeout, which the recipient reads as the share having frozen.
            // The fix is good enough for the share either way; the extra scrutiny below is
            // only about whether it is good enough to become a PIN.
            if isLiveStreaming { onFix?(loc) }

            // DO NOT ACCEPT THE FIRST FIX BLINDLY.
            //
            // `requestLocation()` delivers whatever CoreLocation already has, which on a cold
            // start is routinely a CACHED CELL-TOWER estimate — hundreds of metres out, and
            // sometimes minutes old. Taking it meant a pin dropped a suburb away from where
            // the user was standing, which is the "location is not accurate" report.
            //
            // Hold out for a fix that is both RECENT and reasonably precise. `bestOneShot`
            // keeps the best candidate so far, so if the timeout fires we still send
            // something rather than failing outright.
            let age = -loc.timestamp.timeIntervalSinceNow
            let accuracy = loc.horizontalAccuracy

            if accuracy > 0, age < 15 {
                if bestOneShot == nil || accuracy < (bestOneShot?.horizontalAccuracy ?? .greatestFiniteMagnitude) {
                    bestOneShot = loc
                }
                // 65 m is the threshold for "this is a real GNSS fix, not a tower estimate".
                // Waiting for better than that indoors would usually mean waiting for the
                // timeout, and a 60 m pin is still the right building.
                if accuracy <= 65 { fireOneShot(loc); return }
            }
            // Not good enough yet — keep the request alive and let the timeout decide.
            return
        }

        onFix?(loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A one-shot must not wait for its full timeout on a hard failure.
        if oneShot != nil { fireOneShot(nil) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthChange?(manager.authorizationStatus, manager.accuracyAuthorization == .reducedAccuracy)
    }
}
